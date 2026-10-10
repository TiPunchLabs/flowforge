#!/usr/bin/env bash
# Tests of the Iterator NO_OP outcome for a pull request already CLOSED or MERGED (Issue #22),
# run against the REAL step scripts of the workflows:
#   agent-iterate.yml  iterate/"Check preconditions"          (first state read)
#   agent-iterate.yml  iterate/"Record no-op"                 (NO_OP before any checkout)
#   agent-iterate.yml  publish/"Re-check pull request state"  (last state read before the push)
#   agent-iterate.yml  publish/"Record no-op"                 (NO_OP instead of the push)
#   agent-iterate.yml  publish/"Render iteration result"      (no push is not a failure on NO_OP)
#   review-cycle.yml   summary/"Compute cycle result" and the step / job gates
# `gh` is replaced by a stub on PATH: no network, no token.
#
# Requires: bash, jq, yq (mikefarah v4). Usage: tests/iterate-no-op.sh
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
script "$iterate_yml" iterate "Record no-op" "$work/no_op.sh"
script "$iterate_yml" publish "Re-check pull request state" "$work/recheck.sh"
script "$iterate_yml" publish "Record no-op" "$work/late_no_op.sh"
script "$iterate_yml" publish "Render iteration result" "$work/render.sh"
script "$cycle_yml" summary "Compute cycle result" "$work/cycle.sh"
gate() { step "$iterate_yml" "$1" "$2" if; }

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }
expect() { # name, actual, expected
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
output() { sed -n "s/^$2=//p" "$1/github_output" | tail -n 1; }

# Stub of the GitHub CLI. The workflow's `--jq` filters are not applied: the fixtures are
# already the filtered values. A fixture "FAIL:<message>" makes the call fail like gh does.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"; printf '%s\n' "${args//$'\n'/ }" >> "$FAKE_GH_LOG"  # one line per call
answer() { if [[ "$1" == FAIL:* ]]; then echo "${1#FAIL:}" >&2; exit 1; fi; printf '%s\n' "$1"; }
case "$*" in
  *closingIssuesReferences*) answer "$FAKE_CONTEXT" ;;
  "api graphql"*) answer "$FAKE_STATE" ;;
  "issue view"*) answer '{"number": 1, "title": "t", "body": "b", "url": "u", "state": "OPEN"}' ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"

head_sha=0123456789abcdef
pr() { # state [cross_repository] [head_sha] -> preconditions fixture
  jq -cn --arg s "$1" --argjson fork "${2:-false}" --arg sha "${3:-$head_sha}" \
    '{number: 2, title: "t", body: "b", url: "u", state: $s, isCrossRepository: $fork,
      baseRefName: "main", headRefName: "agent/1-feature", headRefOid: $sha,
      closingIssuesReferences: {nodes: [{number: 1}]}, defaultBranch: "main"}'
}
pr_state() { jq -cn --arg s "$1" '{number: 2, state: $s}'; }
review_json() { # [verdict]
  jq -cn --arg v "${1:-REQUEST_CHANGES}" --arg sha "$head_sha" \
    '{schema_version: 1, produced_by: "reviewer", repository: "owner/target", pull_request: 2,
      issue: 1, base_branch: "main", head_branch: "agent/1-feature", head_sha: $sha, verdict: $v,
      acceptance_criteria: [],
      findings: [{severity: "MAJOR", title: "t", file: "app.py", line_or_range: "1",
                  description: "d", reason: "r", expected_fix: "f"}]}'
}

# Runs one step script; its exit code is stored in <case>/exit.
run_step() { # case_dir, script, context_fixture, state_fixture, extra env...
  local dir="$1" script="$2"
  mkdir -p "$dir/runner/flowforge-iterate"
  touch "$dir/github_output" "$dir/summary" "$dir/gh.log"
  set +e
  env PATH="$work/bin:$PATH" FAKE_GH_LOG="$dir/gh.log" FAKE_CONTEXT="$3" FAKE_STATE="$4" \
    RUNNER_TEMP="$dir/runner" GITHUB_OUTPUT="$dir/github_output" \
    GITHUB_STEP_SUMMARY="$dir/summary" GITHUB_REPOSITORY=owner/target PR_NUMBER=2 \
    ITERATION=1 MAX_ITERATIONS=3 RUN_URL=https://example.invalid/run \
    "${@:5}" bash --noprofile --norc -eo pipefail "$script" > "$dir/log" 2>&1
  echo $? > "$dir/exit"
  set -e
}
code() { cat "$1/exit"; }
preflight() { # case_dir, context_fixture, [review_json]
  run_step "$1" "$work/preflight.sh" "$2" "" REVIEW_JSON="${3:-$(review_json)}"
}

# --- Gates: nothing after the preconditions runs unless the PR is OPEN -------------------------
for s in "Check out pull request head branch" "Check workspace and pin agent configuration" \
         "Build Iterator prompt" "Run Claude Code Iterator"; do
  expect "G  iterate/'$s' requires an OPEN PR" "$(gate iterate "$s")" "steps.preflight.outputs.state == 'OPEN'"
done
expect "G  iterate/Set up uv requires an OPEN PR" "$(gate iterate "Set up uv")" \
  "steps.preflight.outputs.state == 'OPEN' && inputs.setup_uv"
expect "G  iterate/no-op step on CLOSED or MERGED" "$(gate iterate "Record no-op")" \
  "contains(fromJSON('[\"CLOSED\", \"MERGED\"]'), steps.preflight.outputs.state)"
expect "G  iterate/no BLOCKED result on NO_OP (still one on any other failure)" \
  "$(gate iterate "Validate iteration result")" \
  "always() && !contains(fromJSON('[\"CLOSED\", \"MERGED\"]'), steps.preflight.outputs.state)"
expect "G  publish/re-check only when there is something to push" \
  "$(gate publish "Re-check pull request state")" "env.PUSH == 'true'"
for s in "Check out pull request head branch" "Push Iterator commit to the PR head branch"; do
  expect "G  publish/'$s' requires the last state read OPEN" "$(gate publish "$s")" \
    "env.PUSH == 'true' && steps.recheck.outputs.state == 'OPEN'"
done
expect "G  publish/no-op step on CLOSED or MERGED" "$(gate publish "Record no-op")" \
  "contains(fromJSON('[\"CLOSED\", \"MERGED\"]'), steps.recheck.outputs.state)"
expect "G  publish reads the PR state" "$(yq '.jobs.publish.permissions."pull-requests"' "$iterate_yml")" read
expect "G  publish still writes contents only" "$(yq '.jobs.publish.permissions.contents' "$iterate_yml")" write
expect "G  no_op_json output: from either job" "$(yq '.on.workflow_call.outputs.no_op_json.value' "$iterate_yml")" \
  '${{ jobs.iterate.outputs.no_op_json || jobs.publish.outputs.no_op_json }}'
for j in iterate publish; do
  expect "G  $j job exposes no_op_json" "$(yq ".jobs.$j.outputs.no_op_json" "$iterate_yml")" \
    '${{ steps.no_op.outputs.no_op_json }}'
done

# --- Case A: OPEN -> normal Iterator path -------------------------------------------------------
c="$work/open"
preflight "$c" "$(pr OPEN)"
expect "A  OPEN: preconditions succeed" "$(code "$c")" 0
expect "A  OPEN: state output" "$(output "$c" state)" OPEN
expect "A  OPEN: head branch resolved (checkout target)" "$(output "$c" head_branch)" agent/1-feature
expect "A  OPEN: linked Issue read" "$(grep -c '^issue view' "$c/gh.log")" 1
run_step "$c" "$work/recheck.sh" "" "$(pr_state OPEN)"
expect "A  OPEN before the push: re-check keeps OPEN (push runs)" "$(code "$c")/$(output "$c" state)" 0/OPEN

# --- Cases B / C: CLOSED or MERGED at the preconditions -> NO_OP --------------------------------
for state in CLOSED MERGED; do
  c="$work/$state"
  preflight "$c" "$(pr "$state")"
  expect "${state:0:1}  $state: preconditions succeed" "$(code "$c")" 0
  expect "${state:0:1}  $state: state output" "$(output "$c" state)" "$state"
  expect "${state:0:1}  $state: no checkout target" "$(output "$c" head_branch)" ""
  expect "${state:0:1}  $state: only the PR was read" "$(wc -l < "$c/gh.log")" 1
  expect "${state:0:1}  $state: no blocked reason" "$(test -e "$c/runner/flowforge-iterate/blocked_reason.txt" && echo yes || echo no)" no
  expect "${state:0:1}  $state: log says skipping" \
    "$(grep -c "^PR #2 state: $state$" "$c/log")/$(grep -c '^Skipping FlowForge iteration\.$' "$c/log")" 1/1

  run_step "$c" "$work/no_op.sh" "" "" STATE="$state"
  expect "${state:0:1}  $state: no-op step succeeds" "$(code "$c")" 0
  json="$(output "$c" no_op_json)"
  expect "${state:0:1}  $state: no_op_json" \
    "$(jq -c '[.schema_version, .result, .reason, .pull_request, .state, .stage, .iteration_number]' <<<"$json")" \
    "[1,\"NO_OP\",\"PR_ALREADY_$state\",2,\"$state\",\"preconditions\",1]"
  expect "${state:0:1}  $state: summary says NO_OP, Iterator not executed, nothing pushed" \
    "$(grep -c -e '^Result: \*\*NO_OP\*\*' -e '^- Iterator: NOT EXECUTED$' -e '^- Push: NONE$' "$c/summary")" 3
done

# --- Case R: OPEN at the preconditions, closed or merged before the push ------------------------
for state in CLOSED MERGED; do
  c="$work/race-$state"
  run_step "$c" "$work/recheck.sh" "" "$(pr_state "$state")"
  expect "R  $state before the push: re-check succeeds" "$(code "$c")" 0
  expect "R  $state before the push: state output (checkout and push skipped)" "$(output "$c" state)" "$state"
  run_step "$c" "$work/late_no_op.sh" "" "" STATE="$state"
  json="$(output "$c" no_op_json)"
  expect "R  $state before the push: no_op_json" "$(jq -c '[.result, .reason, .stage]' <<<"$json")" \
    "[\"NO_OP\",\"PR_ALREADY_$state\",\"before_push\"]"
done

# Render after a late NO_OP: the commit was not pushed, and that is not a failure.
c="$work/render-no-op"
mkdir -p "$c/runner/flowforge-iterate"
jq -n --arg sha "$head_sha" '{schema_version: 1, produced_by: "iterator", repository: "owner/target",
  pull_request: 2, issue: 1, base_branch: "main", head_branch: "agent/1-feature", reviewed_sha: $sha,
  run_url: "u", iteration_number: 1, max_iterations: 3, result: "COMPLETED", summary: "s",
  blocked_reason: "", findings: [], validations: [{command: "pytest", outcome: "PASS", details: ""}],
  diff: {files: [], files_changed: 0, lines_added: 0, lines_removed: 0, assessment: ""},
  commit: {sha: "fedcba9876543210", pushed: false},
  counts: {FIXED: 1, ALREADY_RESOLVED: 0, NOT_ACTIONABLE: 0, BLOCKED: 0}}' \
  > "$c/runner/flowforge-iterate/iteration.json"
late="$(jq -cn '{schema_version: 1, result: "NO_OP", reason: "PR_ALREADY_MERGED", stage: "before_push"}')"
run_step "$c" "$work/render.sh" "" "" PUSH=true NO_OP_JSON="$late" ARTIFACT=flowforge-iteration-pr-2-1
expect "R  render after a late NO_OP succeeds" "$(code "$c")" 0
expect "R  late NO_OP: no Iterator result (no further Reviewer)" "$(output "$c" result)" ""
expect "R  late NO_OP: nothing pushed" "$(output "$c" commit_sha)" ""
expect "R  late NO_OP: not a push failure" "$(output "$c" reliable)" true
expect "R  late NO_OP: iteration.json kept, commit not pushed" \
  "$(output "$c" iteration_json | jq -c '[.result, .produced_by, .commit.pushed]')" '["COMPLETED","iterator",false]'
expect "R  late NO_OP: iteration.md says so" \
  "$(grep -c 'NO_OP' "$c/runner/flowforge-iterate/iteration.md")" 1

# Without NO_OP, a commit that was not pushed is still a workflow BLOCKED (non-regression).
c="$work/render-push-failed"
mkdir -p "$c/runner/flowforge-iterate"
cp "$work/render-no-op/runner/flowforge-iterate/iteration.json" "$c/runner/flowforge-iterate/"
run_step "$c" "$work/render.sh" "" "" PUSH=true NO_OP_JSON="" ARTIFACT=flowforge-iteration-pr-2-1
expect "R  push failure without NO_OP: BLOCKED, unreliable" \
  "$(output "$c" result)/$(output "$c" reliable)" BLOCKED/false

# --- Case D: technical failures stay failures, never NO_OP --------------------------------------
c="$work/api-down"
preflight "$c" "FAIL:HTTP 502: Bad Gateway (https://api.github.com/graphql)"
expect "D  API failure: preconditions fail, no state" "$(code "$c")/$(output "$c" state)" 1/

c="$work/forbidden"
preflight "$c" "FAIL:GraphQL: Resource not accessible by integration (HTTP 403)"
expect "D  permission failure: preconditions fail, no state" "$(code "$c")/$(output "$c" state)" 1/

c="$work/not-found"
preflight "$c" "null"
expect "D  PR not found: preconditions fail, no state" "$(code "$c")/$(output "$c" state)" 1/

c="$work/unknown"
preflight "$c" "$(pr DRAFT)"
expect "D  unknown state: preconditions fail, no state" "$(code "$c")/$(output "$c" state)" 1/

c="$work/fork"
preflight "$c" "$(pr OPEN true)"
expect "D  fork: preconditions fail" "$(code "$c")" 1

c="$work/moved"
preflight "$c" "$(pr OPEN false fedcba9876543210)"
expect "D  head moved since the review: preconditions fail" "$(code "$c")" 1

c="$work/invalid-review"
preflight "$c" "$(pr MERGED)" '{"schema_version": 1}'
expect "D  invalid review_json on a merged PR: fails, never NO_OP" "$(code "$c")/$(output "$c" state)" 1/

c="$work/recheck-down"
run_step "$c" "$work/recheck.sh" "" "FAIL:HTTP 502: Bad Gateway (https://api.github.com/graphql)"
expect "D  API failure on re-check: step fails, no state" "$(code "$c")/$(output "$c" state)" 1/

c="$work/no-op-guard"
run_step "$c" "$work/no_op.sh" "" "" STATE=OPEN
expect "D  no-op step refuses an OPEN state" "$(code "$c")/$(output "$c" no_op_json)" 1/

# --- Case E: review cycle -----------------------------------------------------------------------
for k in 1 2 3; do
  expect "E  review_$((k + 1)) needs COMPLETED or PARTIAL (NO_OP has no result)" \
    "$(yq ".jobs.review_$((k + 1)).if" "$cycle_yml")" \
    "contains(fromJSON('[\"COMPLETED\", \"PARTIAL\"]'), needs.iterate_$k.outputs.result)"
done

cycle() { # needs_json -> cycle.json
  local out="$work/cycle-$RANDOM"
  mkdir -p "$out"
  env RUNNER_TEMP="$out" GITHUB_OUTPUT="$out/output" GITHUB_STEP_SUMMARY="$out/summary" \
    GITHUB_REPOSITORY=owner/target PR_NUMBER=2 MAX_ITERATIONS=3 RUN_URL=https://example.invalid/run \
    NEEDS="$1" bash --noprofile --norc -eo pipefail "$work/cycle.sh" > /dev/null
  cat "$out/flowforge-review-cycle/cycle.json"
  cp "$out/summary" "$work/last-cycle-summary"
}
skipped='{"result": "skipped", "outputs": {}}'
needs() { # review_1, iterate_1, review_2 job JSONs
  jq -n --argjson s "$skipped" --argjson r1 "$1" --argjson i1 "$2" --argjson r2 "$3" \
    '{check: {result: "success", outputs: {}}, review_1: $r1, iterate_1: $i1, review_2: $r2,
      iterate_2: $s, review_3: $s, iterate_3: $s, review_4: $s}'
}
review() { jq -n --arg v "$1" '{result: "success", outputs: {verdict: $v, review_json: "", no_op_json: ""}}'; }
iterate() { jq -n --arg r "$1" '{result: "success", outputs: {result: $r, commit_sha: "", iteration_json: "", no_op_json: ""}}'; }
iterate_no_op() { # reason, stage
  jq -n --arg r "$1" --arg st "$2" '{result: "success", outputs: {result: "", commit_sha: "", iteration_json: "",
    no_op_json: ({schema_version: 1, result: "NO_OP", reason: $r, stage: $st, pull_request: 2} | tojson)}}'
}

json="$(cycle "$(needs "$(review REQUEST_CHANGES)" "$(iterate_no_op PR_ALREADY_MERGED preconditions)" "$skipped")")"
expect "E  Iterator #1 NO_OP -> cycle NO_OP (not FAILED)" "$(jq -r .result <<<"$json")" NO_OP
expect "E  Iterator NO_OP: no later Reviewer" "$(jq -c '[.timeline[].job]' <<<"$json")" '["review_1","iterate_1"]'
expect "E  Iterator NO_OP: reason recorded" "$(jq -r '.timeline[1].no_op_reason' <<<"$json")" PR_ALREADY_MERGED
expect "E  Iterator NO_OP: final verdict kept" "$(jq -r .final_reviewer_verdict <<<"$json")" REQUEST_CHANGES
expect "E  Iterator NO_OP: summary" \
  "$(grep -c -e '^Result: \*\*NO_OP\*\*' -e 'Iterator #1 → \*\*NO_OP\*\* (PR_ALREADY_MERGED) · no commit pushed' \
  "$work/last-cycle-summary")" 2

json="$(cycle "$(needs "$(review REQUEST_CHANGES)" "$(iterate_no_op PR_ALREADY_CLOSED before_push)" "$skipped")")"
expect "E  closed before the Iterator push -> cycle NO_OP" "$(jq -r .result <<<"$json")" NO_OP

# Non-regression of the other Iterator outcomes.
expect "E  Iterator BLOCKED -> BLOCKED" \
  "$(cycle "$(needs "$(review REQUEST_CHANGES)" "$(iterate BLOCKED)" "$skipped")" | jq -r .result)" BLOCKED
expect "E  failed Iterator -> FAILED, never NO_OP" \
  "$(cycle "$(needs "$(review REQUEST_CHANGES)" '{"result": "failure", "outputs": {}}' "$skipped")" | jq -r .result)" FAILED
expect "E  Iterator PARTIAL then Reviewer APPROVE -> APPROVED" \
  "$(cycle "$(needs "$(review REQUEST_CHANGES)" "$(iterate PARTIAL)" "$(review APPROVE)")" | jq -r .result)" APPROVED

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed."
  exit 1
fi
echo "All checks passed."
