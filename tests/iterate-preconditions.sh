#!/usr/bin/env bash
# Tests of the Iterator entry contract and of the Reviewer <-> Iterator loop bound, run against
# the REAL step scripts and the REAL Project helper:
#   agent-iterate.yml  iterate/"Check preconditions"  (iteration bound, review_json contract,
#                                                      work list, PR / branch / Issue guards)
#   review-cycle.yml   check/"Validate inputs"        (max_iterations ceiling)
#   review-cycle.yml   iterate_k / review_k gates and summary/"Compute cycle result"
#   .github/scripts/flowforge-project.sh             (Review <-> Iteration on the card)
# A contract test, not an end-to-end run: no Reviewer, no Claude Code, no push. `gh` is a stub
# on PATH: no network, no token. What only GitHub Actions can show is in the Phase 6 milestone.
#
# Requires: bash, jq, yq (mikefarah v4). Usage: tests/iterate-preconditions.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
iterate_yml="$root/.github/workflows/agent-iterate.yml"
cycle_yml="$root/.github/workflows/review-cycle.yml"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

step() { yq -e ".jobs.$2.steps[] | select(.name == \"$3\") | .$4" "$1"; }
script() { # file, job, step, destination; a missing step becomes a script that fails
  step "$1" "$2" "$3" run > "$4" 2>/dev/null || echo "echo 'missing step: $2/$3' >&2; exit 99" > "$4"
}
script "$iterate_yml" iterate "Check preconditions" "$work/preflight.sh"
script "$cycle_yml" check "Validate inputs" "$work/check.sh"
script "$cycle_yml" summary "Compute cycle result" "$work/cycle.sh"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }
expect() { # name, actual, expected
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

# Stub of the GitHub CLI: the PR context query and the Issue read. Fixtures are already the
# values the workflow's `--jq` filters would produce.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"; printf '%s\n' "${args//$'\n'/ }" >> "$FAKE_GH_LOG"
case "$*" in
  *closingIssuesReferences*) printf '%s\n' "$FAKE_CONTEXT" ;;
  "issue view"*) echo '{"number": 1, "title": "t", "body": "b", "url": "u", "state": "OPEN"}' ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"

head_sha=0123456789abcdef
pr() { # [head_branch] [issues_json] -> OPEN pull request fixture
  jq -cn --arg head "${1:-agent/1-feature}" --argjson issues "${2:-[1]}" --arg sha "$head_sha" \
    '{number: 2, title: "t", body: "b", url: "u", state: "OPEN", isCrossRepository: false,
      baseRefName: "main", headRefName: $head, headRefOid: $sha,
      closingIssuesReferences: {nodes: [$issues[] | {number: .}]}, defaultBranch: "main"}'
}
# A valid REQUEST_CHANGES review.json; a jq expression edits it for each case.
review_json() { # [jq_edit]
  jq -cn --arg sha "$head_sha" \
    '{schema_version: 1, produced_by: "reviewer", repository: "owner/target", pull_request: 2,
      issue: 1, base_branch: "main", head_branch: "agent/1-feature", head_sha: $sha,
      verdict: "REQUEST_CHANGES",
      acceptance_criteria: [
        {criterion: "GET /x returns 200", status: "PASS", evidence: "test_x"},
        {criterion: "boundary value excluded", status: "FAIL", evidence: "uses <= instead of <"}],
      findings: [{severity: "MAJOR", title: "Off-by-one at the boundary", file: "app.py",
                  line_or_range: "10", description: "d", reason: "r", expected_fix: "use <"}]}
     | '"${1:-.}"
}

preflight() { # case_dir, context_fixture, review_json, [ITERATION] [MAX_ITERATIONS]
  local dir="$1"
  mkdir -p "$dir/runner"
  touch "$dir/github_output" "$dir/summary" "$dir/gh.log"
  set +e
  env PATH="$work/bin:$PATH" FAKE_GH_LOG="$dir/gh.log" FAKE_CONTEXT="$2" REVIEW_JSON="$3" \
    RUNNER_TEMP="$dir/runner" GITHUB_OUTPUT="$dir/github_output" \
    GITHUB_STEP_SUMMARY="$dir/summary" GITHUB_REPOSITORY=owner/target PR_NUMBER=2 \
    ITERATION="${4:-1}" MAX_ITERATIONS="${5:-3}" \
    bash --noprofile --norc -eo pipefail "$work/preflight.sh" > "$dir/log" 2>&1
  echo $? > "$dir/exit"
  set -e
}
code() { cat "$1/exit"; }
reason() { cat "$1/runner/flowforge-iterate/blocked_reason.txt" 2>/dev/null || true; }
calls() { wc -l < "$1/gh.log" | tr -d ' '; }
case_dir() { mktemp -d "$work/case-XXXX"; }

# --- A: a valid REQUEST_CHANGES starts the Iterator ----------------------------------------------
c="$(case_dir)"
preflight "$c" "$(pr)" "$(review_json)"
worklist="$c/runner/flowforge-iterate/worklist.json"
expect "A  valid REQUEST_CHANGES: preconditions pass" "$(code "$c")" 0
expect "A  PR head branch is the checkout target" "$(sed -n 's/^head_branch=//p' "$c/github_output")" agent/1-feature
expect "A  linked Issue resolved" "$(sed -n 's/^issue_number=//p' "$c/github_output")" 1
expect "A  work list = the finding + one MAJOR per FAIL criterion" \
  "$(jq -c '[.[] | [.id, .source, .severity]]' "$worklist")" \
  '[[1,"review","MAJOR"],[2,"acceptance_criterion","MAJOR"]]'
expect "A  PASS criteria are not work items" \
  "$(jq '[.[] | select(.title | contains("returns 200"))] | length' "$worklist")" 0
expect "A  step summary shows the bound and the work list" \
  "$(grep -c -e 'iteration 1/3' -e 'work list: 2 item(s)' "$c/summary")" 2
expect "A  last allowed iteration (3/3) passes" \
  "$(c="$(case_dir)"; preflight "$c" "$(pr)" "$(review_json)" 3 3; code "$c")" 0

# --- B: iteration bound, checked before any API call --------------------------------------------
while IFS='|' read -r label iteration max message; do
  [[ -n "$label" ]] || continue
  c="$(case_dir)"
  preflight "$c" "$(pr)" "$(review_json)" "$iteration" "$max"
  expect "B  $label: refused" "$(code "$c")" 1
  expect "B  $label: reason" "$(reason "$c" | grep -c -- "$message")" 1
  expect "B  $label: no GitHub call" "$(calls "$c")" 0
done <<'EOF'
4th iteration (4/3)|4|3|exceeds max_iterations (3): the loop is exhausted
2nd iteration with max 1 (2/1)|2|1|exceeds max_iterations (1)
max_iterations above the ceiling (1/4)|1|4|must be between 1 and 3
max_iterations 0|1|0|must be between 1 and 3
iteration 0|0|3|must start at 1
non-integer iteration|x|3|must be integers
EOF

# --- C: review_json contract: only a Reviewer REQUEST_CHANGES for this PR -------------------------
while IFS='|' read -r label edit message; do
  [[ -n "$label" ]] || continue
  c="$(case_dir)"
  preflight "$c" "$(pr)" "$(review_json "$edit")"
  expect "C  $label: refused" "$(code "$c")" 1
  expect "C  $label: reason" "$(reason "$c" | grep -c -- "$message")" 1
done <<'EOF'
verdict APPROVE|.verdict = "APPROVE"|only runs on REQUEST_CHANGES
verdict BLOCKED|.verdict = "BLOCKED"|only runs on REQUEST_CHANGES
produced by the Iterator|.produced_by = "iterator"|not a Reviewer result
no producer|del(.produced_by)|not a Reviewer result
other schema version|.schema_version = 2|not a Reviewer result
other repository|.repository = "owner/other"|another repository or pull request
other pull request|.pull_request = 3|another repository or pull request
unknown severity|.findings[0].severity = "CRITICAL"|do not follow the Reviewer model
unknown criterion status|.acceptance_criteria[0].status = "OK"|do not follow the Reviewer model
nothing to fix|. + {findings: [], acceptance_criteria: []}|nothing to iterate on
other head branch|.head_branch = "agent/9-other"|branches do not match
review of an older head|.head_sha = "fedcba9876543210"|head moved since the review
other Issue|.issue = 7|another Issue than #1
EOF

c="$(case_dir)"
preflight "$c" "$(pr)" 'not json'
expect "C  non-JSON review_json: refused" "$(code "$c")/$(reason "$c" | grep -c 'not a JSON object')" 1/1

# --- D: the Iterator only ever touches the PR head branch ----------------------------------------
c="$(case_dir)"
preflight "$c" "$(pr main)" "$(review_json '.head_branch = "main"')"
expect "D  head branch main: refused" "$(code "$c")/$(reason "$c" | grep -c 'is a protected branch')" 1/1
c="$(case_dir)"
preflight "$c" "$(pr agent/1-feature '[]')" "$(review_json)"
expect "D  no linked Issue: refused" "$(code "$c")/$(reason "$c" | grep -c 'exactly one Issue')" 1/1
c="$(case_dir)"
preflight "$c" "$(pr agent/1-feature '[1, 2]')" "$(review_json)"
expect "D  two linked Issues: refused" "$(code "$c")/$(reason "$c" | grep -c 'exactly one Issue')" 1/1

# --- E: cycle bound: the caller cannot raise the ceiling ----------------------------------------
for max in 1 2 3 0 4 10 x; do
  set +e
  env PR_NUMBER=2 MAX_ITERATIONS="$max" GITHUB_STEP_SUMMARY=/dev/null \
    bash --noprofile --norc -eo pipefail "$work/check.sh" > /dev/null 2>&1
  rc=$?
  set -e
  expect "E  cycle max_iterations=$max" "$rc" "$([[ "$max" =~ ^[1-3]$ ]] && echo 0 || echo 1)"
done
for k in 1 2 3; do
  expect "E  iterate_$k runs only on REQUEST_CHANGES within the bound" "$(yq ".jobs.iterate_$k.if" "$cycle_yml")" \
    "needs.review_$k.outputs.verdict == 'REQUEST_CHANGES' && inputs.max_iterations >= $k"
  expect "E  iterate_$k passes its own rank and the bound" \
    "$(yq -o=json -I=0 ".jobs.iterate_$k.with | [.iteration_number, .max_iterations, .review_json]" "$cycle_yml")" \
    "[$k,\"\${{ inputs.max_iterations }}\",\"\${{ needs.review_$k.outputs.review_json }}\"]"
done
expect "E  no 4th Iterator job" "$(yq '.jobs | has("iterate_4")' "$cycle_yml")" false
expect "E  no Reviewer after the final one" "$(yq '.jobs | has("review_5")' "$cycle_yml")" false

cycle() { # max_iterations, needs_json -> cycle.json
  local out="$work/cycle-$RANDOM$RANDOM"
  mkdir -p "$out"
  env RUNNER_TEMP="$out" GITHUB_OUTPUT="$out/output" GITHUB_STEP_SUMMARY="$out/summary" \
    GITHUB_REPOSITORY=owner/target PR_NUMBER=2 MAX_ITERATIONS="$1" RUN_URL=https://example.invalid/run \
    NEEDS="$2" bash --noprofile --norc -eo pipefail "$work/cycle.sh" > /dev/null
  cat "$out/flowforge-review-cycle/cycle.json"
}
skipped='{"result": "skipped", "outputs": {}}'
review() { jq -cn --arg v "$1" '{result: "success", outputs: {verdict: $v, review_json: "", no_op_json: ""}}'; }
iterate() { jq -cn --arg r "$1" '{result: "success", outputs: {result: $r, commit_sha: "", iteration_json: "", no_op_json: ""}}'; }
needs() { # job JSONs in chain order review_1, iterate_1, ..., review_4; missing ones are skipped
  local names=(review_1 iterate_1 review_2 iterate_2 review_3 iterate_3 review_4) i v
  local json='{"check": {"result": "success", "outputs": {}}}'
  for i in "${!names[@]}"; do
    v="${*:i+1:1}"
    json="$(jq -c --arg k "${names[$i]}" --argjson v "${v:-$skipped}" '. + {($k): $v}' <<<"$json")"
  done
  echo "$json"
}
rc="$(review REQUEST_CHANGES)"
done_="$(iterate COMPLETED)"

json="$(cycle 3 "$(needs "$rc" "$done_" "$rc" "$done_" "$rc" "$done_" "$rc")")"
expect "E  3 iterations, still REQUEST_CHANGES -> MAX_ITERATIONS_REACHED" "$(jq -r .result <<<"$json")" MAX_ITERATIONS_REACHED
expect "E  3 iterations used" "$(jq -r .iterations_used <<<"$json")" 3
json="$(cycle 1 "$(needs "$rc" "$done_" "$rc")")"
expect "E  max_iterations=1: stops after 1 iteration" "$(jq -c '[.result, .iterations_used]' <<<"$json")" '["MAX_ITERATIONS_REACHED",1]'
json="$(cycle 3 "$(needs "$rc" "$done_" "$(review APPROVE)")")"
expect "E  REQUEST_CHANGES -> Iterator -> APPROVE" "$(jq -c '[.result, .iterations_used, .final_reviewer_verdict]' <<<"$json")" \
  '["APPROVED",1,"APPROVE"]'
json="$(cycle 3 "$(needs "$rc" '{"result": "failure", "outputs": {}}')")"
expect "E  Iterator technical failure -> FAILED, no further Reviewer" "$(jq -r .result <<<"$json")" FAILED

# --- F: the card follows the loop; replays and stale events write nothing -------------------------
# shellcheck source=/dev/null
source "$root/.github/scripts/flowforge-project.sh"
card=Review last=""
move() { # event: decides on the simulated card, moves it on update; result in $last
  local d
  d="$(flowforge_project_decide "$1" "$card" "")"
  last="$(jq -r '"\(.action) \(.status)/\(.attention)"' <<<"$d")"
  [[ "$(jq -r .action <<<"$d")" != update ]] || card="$(jq -r .status <<<"$d")"
}
move iterate-started
expect "F  REQUEST_CHANGES, Iterator #1 started: Review -> Iteration" "$last|$card" "update Iteration/|Iteration"
move iterate-started
expect "F  duplicate iterate-started: unchanged" "$last|$card" "unchanged Iteration/|Iteration"
move develop-delivered
expect "F  late develop-delivered during Iteration: refused" "$last|$card" "refused Review/|Iteration"
move iterate-completed
expect "F  Iterator #1 pushed: Iteration -> Review" "$last|$card" "update Review/|Review"
move iterate-completed
expect "F  duplicate iterate-completed: unchanged" "$last|$card" "unchanged Review/|Review"
move refine-ready
expect "F  stale refine-ready during the loop: refused" "$last|$card" "refused Ready/|Review"
for k in 2 3; do
  move iterate-started
  first="$last"
  move iterate-completed
  expect "F  Iterator #$k: Review -> Iteration -> Review" "$first|$last|$card" \
    "update Iteration/|update Review/|Review"
done
move cycle-max-iterations
expect "F  4th REQUEST_CHANGES: Human validation + Max iterations, no 4th Iteration" "$last|$card" \
  "update Human validation/Max iterations|Human validation"
move iterate-started
expect "F  late iterate-started after the cycle ended: refused" "$last|$card" "refused Iteration/|Human validation"
move iterate-completed
expect "F  late iterate-completed after the cycle ended: refused" "$last|$card" "refused Review/|Human validation"

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed."
  exit 1
fi
echo "All checks passed."
