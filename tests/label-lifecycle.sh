#!/usr/bin/env bash
# Tests of the FlowForge Issue label lifecycle (Issue #19), run against the REAL step scripts:
#   agent-develop.yml    develop/"Mark issue as running"               READY -> RUNNING
#   agent-develop.yml    develop/"Enforce Draft PR and set final label" RUNNING -> REVIEW | BLOCKED
#   review-cycle.yml     issue_state/"Mark linked Issue as blocked"    REVIEW -> BLOCKED
#   agent-lifecycle.yml  terminal_state/"Apply terminal state"         -> DONE | none
# and the shared helper .github/scripts/flowforge-state.sh they fetch and source.
# `gh` is replaced by a stub on PATH that keeps Issue labels in files: no network, no token.
#
# Requires: bash, jq, yq (mikefarah v4). Usage: tests/label-lifecycle.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$root/.github/workflows"
helper="$root/.github/scripts/flowforge-state.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

step() { yq -e ".jobs.$2.steps[] | select(.name == \"$3\") | .run" "$wf/$1"; }
step agent-develop.yml develop "Mark issue as running" > "$work/running.sh"
step agent-develop.yml develop "Enforce Draft PR and set final label" > "$work/finalize.sh"
step review-cycle.yml issue_state "Mark linked Issue as blocked" > "$work/blocked.sh"
step agent-lifecycle.yml terminal_state "Apply terminal state" > "$work/terminal.sh"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }
expect() { # name, actual, expected
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

# Stub of the GitHub CLI. Issue labels live in $FAKE_STATE/issue-<n>.json (array of names),
# repository labels in repo-labels.json, the GraphQL PR answer (already --jq filtered) in
# pr.json. Like gh, `issue edit` fails on a label the repository does not have.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"; printf '%s\n' "${args//$'\n'/ }" >> "$FAKE_STATE/gh.log"
s="$FAKE_STATE"
case "$*" in
  *"contents/.github/scripts/flowforge-state.sh?ref="*) cat "$FAKE_HELPER" ;;
  "api graphql"*)
    [[ -z "${FAKE_PR_FAIL:-}" ]] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    cat "$s/pr.json" ;;
  "api --paginate repos/owner/target/labels?per_page=100") jq '[.[] | {name: .}]' "$s/repo-labels.json" ;;
  "api repos/owner/target/issues/"*)
    [[ -z "${FAKE_ISSUE_FAIL:-}" ]] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    jq '{labels: [.[] | {name: .}]}' "$s/issue-${2##*/}.json" ;;   # api repos/.../issues/<n>
  "issue edit "*)
    n="$3"; shift 5   # issue edit <n> --repo <repo>
    add=""; remove=""
    while (( $# )); do
      case "$1" in
        --add-label) add="$2" ;;
        --remove-label) remove="$2" ;;
        *) echo "gh stub: unexpected flag $1" >&2; exit 1 ;;
      esac
      shift 2
    done
    for l in ${add//,/ } ${remove//,/ }; do
      jq -e --arg l "$l" 'index($l) != null' "$s/repo-labels.json" >/dev/null \
        || { echo "'$l' not found" >&2; exit 1; }
    done
    jq --arg add "$add" --arg rm "$remove" \
      '(. - ($rm | split(","))) + ($add | split(",")) | unique' "$s/issue-$n.json" > "$s/tmp" \
      && mv "$s/tmp" "$s/issue-$n.json" ;;
  "pr list"*) printf '%s\n' "${FAKE_PR_NUMBER:-}" ;;
  "pr view"*) echo true ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"

state_labels='["agent:ready","agent:running","agent:review","agent:blocked","agent:done"]'
user_labels='["bug","enhancement","priority:high"]'

# new_case <name> <issue 1 labels JSON> [repo labels JSON]: fresh stub state, prints its dir.
new_case() {
  local dir="$work/$1"
  mkdir -p "$dir"
  printf '%s\n' "$2" > "$dir/issue-1.json"
  printf '%s\n' "${3:-$(jq -cn --argjson a "$state_labels" --argjson b "$user_labels" '$a + $b + ["flowforge:go"]')}" \
    > "$dir/repo-labels.json"
  touch "$dir/gh.log" "$dir/github_output" "$dir/summary"
  echo "$dir"
}
# pr_fixture <dir> <state> <issue numbers JSON> [repository of the issues]
pr_fixture() {
  jq -cn --arg s "$2" --argjson i "$3" --arg r "${4:-owner/target}" \
    '{number: 2, state: $s, closingIssuesReferences: {nodes: [$i[] | {number: ., repository: {nameWithOwner: $r}}]}}' \
    > "$1/pr.json"
}
# run <dir> <script> [env...]: runs a step script like Actions does; exit code in <dir>/exit.
run() {
  local dir="$1" script="$2"
  set +e
  env PATH="$work/bin:$PATH" FAKE_STATE="$dir" FAKE_HELPER="$helper" GH_TOKEN=x \
    GITHUB_REPOSITORY=owner/target GITHUB_OUTPUT="$dir/github_output" \
    GITHUB_STEP_SUMMARY="$dir/summary" FLOWFORGE_REPOSITORY=owner/flowforge FLOWFORGE_SHA=abc123 \
    ISSUE_NUMBER=1 PR_NUMBER=2 READY_LABEL=agent:ready "${@:3}" \
    bash --noprofile --norc -eo pipefail "$script" > "$dir/log" 2>&1
  echo $? > "$dir/exit"
  set -e
}
labels() { jq -c 'sort' "$1/issue-1.json"; }
states() { jq -c --argjson s "$state_labels" '[.[] | select(IN($s[]))] | sort' "$1/issue-1.json"; }
edits() { grep -c '^issue edit' "$1/gh.log" || true; }
code() { cat "$1/exit"; }

# --- A: READY -> RUNNING ----------------------------------------------------------------------
c="$(new_case a '["agent:ready","bug"]')"
run "$c" "$work/running.sh"
expect "A  ready -> running: step succeeds" "$(code "$c")" 0
expect "A  ready -> running: only agent:running, bug kept" "$(labels "$c")" '["agent:running","bug"]'
expect "A  helper fetched at the pinned FlowForge commit" \
  "$(grep -c 'repos/owner/flowforge/contents/.github/scripts/flowforge-state.sh?ref=abc123' "$c/gh.log")" 1

c="$(new_case a-stale '["agent:ready","agent:review","agent:done","priority:high"]')"
run "$c" "$work/running.sh"
expect "A  stale states from an earlier run removed" "$(labels "$c")" '["agent:running","priority:high"]'

c="$(new_case a-custom '["flowforge:go","enhancement"]')"
run "$c" "$work/running.sh" READY_LABEL=flowforge:go
expect "A  custom ready_label removed too" "$(labels "$c")" '["agent:running","enhancement"]'

# --- B: RUNNING -> REVIEW | BLOCKED (Developer final step) ------------------------------------
c="$(new_case b '["agent:running","bug"]')"
run "$c" "$work/finalize.sh" BRANCH=agent/1-x CLAUDE_OUTCOME=success FAKE_PR_NUMBER=2
expect "B  Draft PR: step succeeds" "$(code "$c")" 0
expect "B  Draft PR: running -> review" "$(labels "$c")" '["agent:review","bug"]'
expect "B  Draft PR: pull_request output kept" "$(sed -n 's/^pull_request=//p' "$c/github_output")" 2

c="$(new_case b-stop '["agent:running","bug"]')"
run "$c" "$work/finalize.sh" BRANCH=agent/1-x CLAUDE_OUTCOME=success FAKE_PR_NUMBER=
expect "B  agent stopped, no Draft PR: running -> blocked (business)" "$(code "$c")/$(labels "$c")" '0/["agent:blocked","bug"]'

# E3: a technical failure is not BLOCKED. No Draft PR -> no FlowForge state, re-run possible.
for outcome in failure cancelled skipped ""; do
  c="$(new_case "b-tech-${outcome:-none}" '["agent:running","bug"]')"
  run "$c" "$work/finalize.sh" BRANCH=agent/1-x CLAUDE_OUTCOME="$outcome" FAKE_PR_NUMBER=
  expect "B  technical failure (${outcome:-not run}), no Draft PR: no state, never blocked" \
    "$(code "$c")/$(labels "$c")" '0/["bug"]'
  expect "B  technical failure (${outcome:-not run}): warning says re-run" \
    "$(grep -c 'Technical failure.*re-add the ready label' "$c/log")" 1
done

c="$(new_case b-fail-pr '["agent:running"]')"
run "$c" "$work/finalize.sh" BRANCH=agent/1-x CLAUDE_OUTCOME=failure FAKE_PR_NUMBER=2
expect "B  Claude failed after opening a Draft PR: review (the Reviewer judges it)" \
  "$(code "$c")/$(labels "$c")" '0/["agent:review"]'

# --- C: REVIEW -> BLOCKED (review cycle BLOCKED / MAX_ITERATIONS_REACHED) ---------------------
c="$(new_case c '["agent:review","bug"]')"
pr_fixture "$c" OPEN '[1]'
run "$c" "$work/blocked.sh"
expect "C  review -> blocked: step succeeds" "$(code "$c")" 0
expect "C  review -> blocked, bug kept" "$(labels "$c")" '["agent:blocked","bug"]'

c="$(new_case c-merged '["agent:review"]')"
pr_fixture "$c" MERGED '[1]'
run "$c" "$work/blocked.sh"
expect "C  PR merged meanwhile: left to the lifecycle" "$(labels "$c")/$(edits "$c")" '["agent:review"]/0'

c="$(new_case c-foreign '["bug"]')"
pr_fixture "$c" OPEN '[1]'
run "$c" "$work/blocked.sh"
expect "C  Issue not in agent:review: untouched" "$(labels "$c")/$(edits "$c")" '["bug"]/0'

for linked in '[]' '[1,3]'; do
  c="$(new_case "c-links-$(jq length <<<"$linked")" '["agent:review"]')"
  pr_fixture "$c" OPEN "$linked"
  run "$c" "$work/blocked.sh"
  expect "C  $(jq length <<<"$linked") linked Issue(s): untouched" "$(code "$c")/$(edits "$c")" 0/0
done

c="$(new_case c-cross '["agent:review"]')"
pr_fixture "$c" OPEN '[1]' other/repo
run "$c" "$work/blocked.sh"
expect "C  Issue of another repository: untouched" "$(code "$c")/$(edits "$c")" 0/0

c="$(new_case c-api '["agent:review"]')"
run "$c" "$work/blocked.sh" FAKE_PR_FAIL=1
expect "C  API failure: step fails, no label changed" "$(code "$c")/$(edits "$c")" 1/0

# --- D / E: terminal state on PR close --------------------------------------------------------
for from in agent:review agent:blocked; do
  c="$(new_case "d-${from#agent:}" "[\"$from\",\"bug\",\"priority:high\"]")"
  pr_fixture "$c" MERGED '[1]'
  run "$c" "$work/terminal.sh"
  expect "D  merged from $from: step succeeds" "$(code "$c")" 0
  expect "D  merged from $from: agent:done, user labels kept" "$(labels "$c")" '["agent:done","bug","priority:high"]'
done

c="$(new_case d-closed '["agent:review","enhancement"]')"
pr_fixture "$c" CLOSED '[1]'
run "$c" "$work/terminal.sh"
expect "D  closed unmerged: no FlowForge state, no false done" "$(labels "$c")" '["enhancement"]'

c="$(new_case d-open '["agent:review"]')"
pr_fixture "$c" OPEN '[1]'
run "$c" "$work/terminal.sh"
expect "D  PR reopened / still open: untouched" "$(labels "$c")/$(edits "$c")" '["agent:review"]/0'

c="$(new_case d-newer-run '["agent:running"]')"
pr_fixture "$c" CLOSED '[1]'
run "$c" "$work/terminal.sh"
expect "D  Issue owned by a newer run: untouched" "$(labels "$c")/$(edits "$c")" '["agent:running"]/0'

c="$(new_case d-no-done '["agent:review","bug"]' '["agent:ready","agent:running","agent:review","agent:blocked","bug"]')"
pr_fixture "$c" MERGED '[1]'
run "$c" "$work/terminal.sh"
expect "D  agent:done not applied yet: step succeeds" "$(code "$c")" 0
expect "D  agent:done not applied yet: review removed, nothing added" "$(labels "$c")" '["bug"]'
expect "D  agent:done not applied yet: warning" "$(grep -c "Label 'agent:done' does not exist" "$c/log")" 1

c="$(new_case e-stale '["agent:ready","agent:running","agent:review","bug"]')"
pr_fixture "$c" MERGED '[1]'
run "$c" "$work/terminal.sh"
expect "E  terminal state clears every stale state" "$(states "$c")" '["agent:done"]'

# --- F: idempotence ---------------------------------------------------------------------------
c="$(new_case f '["agent:review","bug"]')"
pr_fixture "$c" MERGED '[1]'
run "$c" "$work/terminal.sh"
run "$c" "$work/terminal.sh"
expect "F  terminal replayed: same state, one write only" "$(code "$c")/$(labels "$c")/$(edits "$c")" '0/["agent:done","bug"]/1'

c="$(new_case f-running '["agent:ready"]')"
run "$c" "$work/running.sh"
run "$c" "$work/running.sh"
expect "F  ready -> running replayed: same state, one write only" "$(code "$c")/$(labels "$c")/$(edits "$c")" '0/["agent:running"]/1'

c="$(new_case f-helper '["agent:blocked","bug"]')"
cat > "$work/twice.sh" <<'EOF'
source "$FAKE_HELPER"
flowforge_set_state 1 agent:blocked   # already there: no write
flowforge_set_state 1 ""              # removing: one write
flowforge_set_state 1 ""              # already none: no write
EOF
run "$c" "$work/twice.sh"
expect "F  add existing / remove absent: safe, one write" "$(code "$c")/$(labels "$c")/$(edits "$c")" '0/["bug"]/1'

# --- G: one state at most, other labels never touched ----------------------------------------
c="$(new_case g "$(jq -c '. + ["agent:ready","agent:review"]' <<<"$user_labels")")"
cat > "$work/each.sh" <<'EOF'
source "$FAKE_HELPER"
for s in agent:ready agent:running agent:review agent:blocked agent:done; do
  flowforge_set_state 1 "$s"
  jq -c --arg s "$s" '[.[] | select(startswith("agent:"))] == [$s]' "$FAKE_STATE/issue-1.json"
done
EOF
run "$c" "$work/each.sh"
expect "G  every state: exactly one FlowForge state label" "$(grep -c '^true$' "$c/log")" 5
expect "G  user labels intact" "$(jq -c --argjson u "$user_labels" '[.[] | select(IN($u[]))] | sort' "$c/issue-1.json")" \
  "$(jq -c sort <<<"$user_labels")"

c="$(new_case g-guard '["bug"]')"
# shellcheck disable=SC2016  # $FAKE_HELPER expands in the generated script
printf 'source "$FAKE_HELPER"\nflowforge_set_state 1 priority:high\n' > "$work/bad-target.sh"
run "$c" "$work/bad-target.sh"
expect "G  non-FlowForge target refused" "$(code "$c")/$(labels "$c")" '1/["bug"]'
# shellcheck disable=SC2016
printf 'source "$FAKE_HELPER"\nflowforge_set_state "1; x" agent:done\n' > "$work/bad-issue.sh"
run "$c" "$work/bad-issue.sh"
expect "G  invalid Issue number refused" "$(code "$c")/$(edits "$c")" 1/0

# --- Workflow contract: triggers, gates, permissions ------------------------------------------
expect "W  issue_state only on results needing a human" "$(yq '.jobs.issue_state.if' "$wf/review-cycle.yml")" \
  "always() && contains(fromJSON('[\"BLOCKED\", \"MAX_ITERATIONS_REACHED\"]'), needs.summary.outputs.result)"
expect "W  issue_state permissions" "$(yq -o=json -I=0 '.jobs.issue_state.permissions' "$wf/review-cycle.yml")" \
  '{"issues":"write","pull-requests":"read"}'
expect "W  lifecycle permissions (no contents)" "$(yq -o=json -I=0 '.jobs.terminal_state.permissions' "$wf/agent-lifecycle.yml")" \
  '{"issues":"write","pull-requests":"read"}'
expect "W  lifecycle: workflow-level permissions empty" "$(yq -o=json -I=0 '.permissions' "$wf/agent-lifecycle.yml")" '{}'
expect "W  lifecycle caller: pull_request closed only" \
  "$(yq -o=json -I=0 '.on' "$root/examples/target-repository/flowforge-lifecycle.yml")" '{"pull_request":{"types":["closed"]}}'
expect "W  no write-all anywhere" "$(grep -rl 'write-all' "$wf" "$root/examples" | wc -l)" 0
expect "W  no merge, no ready-for-review in the lifecycle" "$(grep -cE 'gh pr (merge|ready)' "$wf/agent-lifecycle.yml" || true)" 0
expect "W  Terraform manages every state label" \
  "$(grep -oE '"agent:[a-z]+" = \{' "$root/terraform/modules/target-repository/variables.tf" | sed -E 's/"([^"]+)".*/\1/' | jq -Rnc '[inputs] | sort')" \
  "$(jq -c sort <<<"$state_labels")"
expect "W  helper and module agree on the state set" \
  "$(bash -c 'source "$1"; printf "%s\n" "${FLOWFORGE_STATE_LABELS[@]}"' _ "$helper" | jq -Rnc '[inputs] | sort')" \
  "$(jq -c sort <<<"$state_labels")"

echo
if (( failures > 0 )); then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All label lifecycle tests passed."
