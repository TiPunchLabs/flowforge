#!/usr/bin/env bash
# Tests of the Developer delivery gate (Issue #34), run against the REAL step script:
#   agent-develop.yml  develop/"Verify delivery request"
# Claude Code only commits and writes .flowforge-pr/{title.txt,body.md}; this step decides
# whether the workflow may push the agent branch and open the Draft PR. Each case runs in a
# throwaway local Git repository; `gh` is a stub on PATH: no network, no token.
#
# Requires: bash, git, jq, yq (mikefarah v4). Usage: tests/developer-delivery.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$root/.github/workflows/agent-develop.yml"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

yq -e '.jobs.develop.steps[] | select(.name == "Verify delivery request") | .run' "$wf" > "$work/verify.sh"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }
expect() { # name, actual, expected
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "api repos/owner/target --jq .default_branch") echo main ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"

# new_case <name> [branch]: a repo on main with one commit, then the agent branch created as
# the workflow does (git-ignored request directory). Prints the repo dir; BASE_SHA is in base_sha.
new_case() {
  local dir="$work/$1" branch="${2:-agent/1-x}"
  mkdir -p "$dir/repo" "$dir/tmp"
  (
    cd "$dir/repo"
    git init -q -b main
    git config user.name test && git config user.email test@example.invalid
    echo base > README.md && git add README.md && git commit -qm base
    git rev-parse HEAD > "$dir/base_sha"
    [[ "$branch" == main ]] || git switch -qc "$branch"
    echo "/.flowforge-pr/" >> .git/info/exclude
  )
  echo "$dir"
}
commit() { (cd "$1/repo" && echo "$2" >> app.txt && git add app.txt && git commit -qm "feat: $2"); }
request() { # dir, title, [body]
  mkdir -p "$1/repo/.flowforge-pr"
  printf '%s\n' "$2" > "$1/repo/.flowforge-pr/title.txt"
  [[ $# -lt 3 ]] || printf '%s\n' "$3" > "$1/repo/.flowforge-pr/body.md"
}
run() { # dir, [branch]
  local dir="$1"
  : > "$dir/github_output"
  set +e
  (cd "$dir/repo" && env PATH="$work/bin:$PATH" GH_TOKEN=x GITHUB_REPOSITORY=owner/target \
    GITHUB_OUTPUT="$dir/github_output" GITHUB_STEP_SUMMARY="$dir/summary" RUNNER_TEMP="$dir/tmp" \
    BRANCH="${2:-agent/1-x}" BASE_BRANCH=main BASE_SHA="$(cat "$dir/base_sha")" \
    bash --noprofile --norc -eo pipefail "$work/verify.sh") > "$dir/log" 2>&1
  echo $? > "$dir/exit"
  set -e
}
result() { printf '%s/%s' "$(cat "$1/exit")" "$(sed -n 's/^deliver=//p' "$1/github_output")"; }
refused() { # name, dir, expected error text: the step fails for that reason, nothing delivered
  expect "$1" "$(result "$2")/$(grep -F '::error::' "$2/log" | grep -cF "$3" || true)" "1//1"
}

# --- Delivery requested and valid -------------------------------------------------------------
c="$(new_case ok)"; commit "$c" one; commit "$c" two; request "$c" "feat: add thing" "Closes #1"
run "$c"
expect "valid request: deliver" "$(result "$c")" "0/true"
expect "valid request: title handed to the push step" "$(cat "$c/tmp/flowforge-pr-title.txt")" "feat: add thing"
expect "valid request: body handed to the push step" "$(cat "$c/tmp/flowforge-pr-body.md")" "Closes #1"
expect "valid request: commit count in summary" "$(grep -c 'Commits to deliver: 2' "$c/summary")" 1

c="$(new_case no-body)"; commit "$c" one; request "$c" "fix: x"
run "$c"
expect "missing body: deliver with an empty body" "$(result "$c")/$(wc -c < "$c/tmp/flowforge-pr-body.md")" "0/true/0"

c="$(new_case moved-base)"; commit "$c" one; request "$c" "fix: x"
(cd "$c/repo" && git switch -q main && echo later >> README.md && git commit -qam later && git switch -q agent/1-x)
run "$c"
expect "base branch moved during the run: still deliver" "$(result "$c")" "0/true"

# --- No request: the agent stopped (rules §8) -------------------------------------------------
c="$(new_case stop)"; commit "$c" one
run "$c"
expect "no request file: nothing to deliver, step succeeds" "$(result "$c")" "0/false"

# --- Refused requests: nothing is pushed ------------------------------------------------------
c="$(new_case no-commit)"; request "$c" "feat: nothing"
run "$c"
refused "request without commit: refused" "$c" "PR requested but no commit"

c="$(new_case on-main main)"; commit "$c" one; request "$c" "feat: x"
run "$c" main
refused "agent branch is the default branch: refused" "$c" "Refusing to deliver to 'main'"

c="$(new_case switched)"; commit "$c" one; request "$c" "feat: x"
(cd "$c/repo" && git switch -qc other)
run "$c"
refused "HEAD left the agent branch: refused" "$c" "HEAD is not on the agent branch"

c="$(new_case rewritten)"; commit "$c" one; request "$c" "feat: x"
(cd "$c/repo" && git checkout -q --orphan fresh && git commit -qm orphan && git branch -qf agent/1-x fresh && git switch -q agent/1-x)
run "$c"
refused "history no longer contains the base commit: refused" "$c" "no longer contains the base commit"

c="$(new_case committed-request)"; request "$c" "feat: x"
(cd "$c/repo" && git add -f .flowforge-pr && git commit -qm "chore: oops")
run "$c"
refused "request files committed: refused" "$c" "The PR request files were committed"

c="$(new_case empty-title)"; commit "$c" one; request "$c" "   "
run "$c"
refused "blank title: refused" "$c" "PR title must be"

c="$(new_case long-title)"; commit "$c" one; request "$c" "$(printf 'x%.0s' {1..257})"
run "$c"
refused "title over 256 characters: refused" "$c" "PR title must be"

c="$(new_case big-body)"; commit "$c" one; request "$c" "feat: x" "$(head -c 60001 /dev/zero | tr '\0' a)"
run "$c"
refused "body over 60000 bytes: refused" "$c" "PR body exceeds"

# --- Workflow invariants ----------------------------------------------------------------------
expect "Claude may not push nor open a PR" \
  "$(yq '.jobs.develop.steps[] | select(.name == "Run Claude Code") | .with.claude_args' "$wf" \
    | grep -cE 'git push|gh pr create' || true)" 0
expect "App token minted after Claude Code" \
  "$(yq '[.jobs.develop.steps[].name] | (to_entries[] | select(.value == "Create App delivery token") | .key) > (to_entries[] | select(.value == "Run Claude Code") | .key)' "$wf")" true
expect "App token has no issues permission (anti-loop rule 1)" \
  "$(yq '.jobs.develop.steps[] | select(.name == "Create App delivery token") | .with | keys | map(select(test("^permission-"))) | sort | join(",")' "$wf")" \
  "permission-contents,permission-pull-requests"
expect "App token only used by the push step" \
  "$(grep -c 'steps.app_token.outputs.token' "$wf")" 1

# --- Delivery reference for an automatic review (Phase 9, Prompt 45): "Record delivery" ------
yq -e '.jobs.develop.steps[] | select(.name == "Record delivery") | .run' "$wf" > "$work/record.sh"
mkdir -p "$work/rbin"
cat > "$work/rbin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "pr view 5 --repo owner/target --json state,isDraft,headRefOid")
    [[ "$FAKE_PR" != FAIL ]] || { echo "HTTP 502" >&2; exit 1; }
    printf '%s\n' "$FAKE_PR" ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/rbin/gh"
record() { # case, PR fixture (or FAIL), pushed sha -> prints "<exit>/<head_sha output>"
  local dir="$work/record-$1"
  mkdir -p "$dir"; : > "$dir/out"; : > "$dir/summary"
  set +e
  env PATH="$work/rbin:$PATH" GITHUB_REPOSITORY=owner/target GITHUB_OUTPUT="$dir/out" \
    GITHUB_STEP_SUMMARY="$dir/summary" FAKE_PR="$2" PR_NUMBER=5 PUSHED_SHA="$3" \
    bash --noprofile --norc -eo pipefail "$work/record.sh" > "$dir/log" 2>&1
  printf '%s/%s' "$?" "$(sed -n 's/^head_sha=//p' "$dir/out")"
  set -e
}
prj() { jq -cn --arg s "$1" --argjson d "$2" --arg h "$3" '{state: $s, isDraft: $d, headRefOid: $h}'; }
expect "R  open Draft PR at the pushed commit: delivery reference set" "$(record ok "$(prj OPEN true abc123)" abc123)" "0/abc123"
expect "R  PR head is not the pushed commit: no reference" "$(record moved "$(prj OPEN true def456)" abc123)" "0/"
expect "R  PR no longer draft: no reference" "$(record ready "$(prj OPEN false abc123)" abc123)" "0/"
expect "R  PR closed meanwhile: no reference" "$(record closed "$(prj CLOSED true abc123)" abc123)" "0/"
expect "R  no pushed commit recorded: no reference" "$(record nosha "$(prj OPEN true abc123)" "")" "0/"
expect "R  PR unreadable: step fails, no reference (best-effort step)" "$(record down FAIL abc123)" "1/"
expect "R  Record delivery is best-effort (never fails a delivery)" \
  "$(yq '.jobs.develop.steps[] | select(.name == "Record delivery") | .continue-on-error' "$wf")" true
expect "R  only after this run pushed and opened the PR" \
  "$(yq '.jobs.develop.steps[] | select(.name == "Record delivery") | .if' "$wf")" \
  "always() && steps.running.outcome == 'success' && steps.deliver.outcome == 'success' && steps.finalize.outputs.pull_request != ''"
push_run="$(yq '.jobs.develop.steps[] | select(.name == "Push branch and open Draft PR") | .run' "$wf")"
line() { grep -nF -- "$1" <<<"$push_run" | head -n 1 | cut -d: -f1; }
expect "R  pushed commit recorded right after the push, before the PR is opened" \
  "$(( $(line 'HEAD:refs/heads/$BRANCH') < $(line 'echo "head_sha=$(git rev-parse HEAD)"') \
       && $(line 'echo "head_sha=$(git rev-parse HEAD)"') < $(line 'gh pr create') ))" 1
expect "R  workflow output head_sha comes from Record delivery only" \
  "$(yq '.jobs.develop.outputs.head_sha' "$wf")/$(yq '.on.workflow_call.outputs.head_sha.value' "$wf")" \
  '${{ steps.delivery_ref.outputs.head_sha }}/${{ jobs.develop.outputs.head_sha }}'

echo
if (( failures > 0 )); then
  echo "$failures developer delivery test(s) failed."
  exit 1
fi
echo "All developer delivery tests passed."
