#!/usr/bin/env bash
# Tests of the NO_OP outcome for a pull request already CLOSED or MERGED (Issue #18), run
# against the REAL step scripts of the workflows:
#   agent-review.yml  review/"Resolve pull request context"  (first state read)
#   agent-review.yml  review/"Re-check pull request state"   (last state read before Claude)
#   agent-review.yml  review/"Record no-op"                  (no_op_json + step summary)
#   review-cycle.yml  summary/"Compute cycle result" and the step / job gates
# `gh` is replaced by a stub on PATH: no network, no token.
#
# Requires: bash, jq, yq (mikefarah v4). Usage: tests/review-no-op.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
review_yml="$root/.github/workflows/agent-review.yml"
cycle_yml="$root/.github/workflows/review-cycle.yml"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

step() { yq -e ".jobs.$2.steps[] | select(.name == \"$3\") | .$4" "$1"; }
step "$review_yml" review "Resolve pull request context" run > "$work/context.sh"
step "$review_yml" review "Re-check pull request state" run > "$work/recheck.sh"
step "$review_yml" review "Record no-op" run > "$work/no_op.sh"
step "$cycle_yml" summary "Compute cycle result" run > "$work/cycle.sh"
gate() { step "$review_yml" review "$1" if; }

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
  *check-runs*) answer '[]' ;;
  *"/status"*) answer '{"state": "success", "statuses": []}' ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"

pr() { # state -> context fixture
  jq -cn --arg s "$1" '{number: 2, title: "t", body: "b", url: "u", state: $s,
    isCrossRepository: false, baseRefName: "main", headRefName: "agent/1-feature",
    headRefOid: "0123456789abcdef", closingIssuesReferences: {nodes: [{number: 1}]}}'
}
pr_state() { jq -cn --arg s "$1" '{number: 2, state: $s}'; }

# Runs one review step script; its exit code is stored in <case>/exit.
run_step() { # case_dir, script, context_fixture, state_fixture, extra env...
  local dir="$1" script="$2"
  mkdir -p "$dir/runner/flowforge-review"
  touch "$dir/github_output" "$dir/github_env" "$dir/summary" "$dir/gh.log"
  set +e
  env PATH="$work/bin:$PATH" FAKE_GH_LOG="$dir/gh.log" FAKE_CONTEXT="$3" FAKE_STATE="$4" \
    RUNNER_TEMP="$dir/runner" CONTEXT_DIR="$dir/runner/flowforge-review" \
    GITHUB_OUTPUT="$dir/github_output" GITHUB_ENV="$dir/github_env" \
    GITHUB_STEP_SUMMARY="$dir/summary" GITHUB_REPOSITORY=owner/target PR_NUMBER=2 \
    "${@:5}" bash --noprofile --norc -eo pipefail "$script" > "$dir/log" 2>&1
  echo $? > "$dir/exit"
  set -e
}
code() { cat "$1/exit"; }

# --- Step gates: nothing after the context runs unless the PR is OPEN -----------------------
for s in "Check out pull request head" "Pin agent configuration to the base branch" "Build Reviewer prompt"; do
  expect "G  '$s' requires an OPEN PR" "$(gate "$s")" "steps.context.outputs.state == 'OPEN'"
done
expect "G  Set up uv requires an OPEN PR" "$(gate "Set up uv")" \
  "steps.context.outputs.state == 'OPEN' && inputs.setup_uv"
expect "G  Claude runs only on the last state read OPEN" \
  "$(gate "Run Claude Code Reviewer")" "steps.recheck.outputs.state == 'OPEN'"
expect "G  the result step needs the last state read OPEN" \
  "$(gate "Validate and render review result")" "always() && steps.recheck.outputs.state == 'OPEN'"
expect "G  no-op step reads the latest known state" "$(gate "Record no-op")" \
  "contains(fromJSON('[\"CLOSED\", \"MERGED\"]'), steps.recheck.outputs.state || steps.context.outputs.state)"
expect "G  publish needs a verdict (none on NO_OP)" \
  "$(yq '.jobs.publish.if' "$review_yml")" "always() && needs.review.outputs.verdict != ''"

# --- Case A: OPEN -> normal review path -------------------------------------------------------
c="$work/open"
run_step "$c" "$work/context.sh" "$(pr OPEN)" ""
expect "A  OPEN: context step succeeds" "$(code "$c")" 0
expect "A  OPEN: state output" "$(output "$c" state)" OPEN
expect "A  OPEN: review context resolved (head commit)" "$(output "$c" head_sha)" 0123456789abcdef
expect "A  OPEN: linked Issue read" "$(grep -c '^issue view' "$c/gh.log")" 1
run_step "$c" "$work/recheck.sh" "" "$(pr_state OPEN)"
expect "A  OPEN: re-check keeps OPEN (Claude runs)" "$(output "$c" state)" OPEN

# --- Cases B / C: CLOSED or MERGED -> NO_OP, nothing else read --------------------------------
for state in CLOSED MERGED; do
  c="$work/$state"
  run_step "$c" "$work/context.sh" "$(pr "$state")" ""
  expect "${state:0:1}  $state: context step succeeds" "$(code "$c")" 0
  expect "${state:0:1}  $state: state output" "$(output "$c" state)" "$state"
  expect "${state:0:1}  $state: no review context (no checkout target)" "$(output "$c" head_sha)" ""
  expect "${state:0:1}  $state: only the PR was read" "$(wc -l < "$c/gh.log")" 1
  expect "${state:0:1}  $state: log says skipping" \
    "$(grep -c "^PR #2 state: $state$" "$c/log")/$(grep -c '^Skipping FlowForge review\.$' "$c/log")" 1/1

  run_step "$c" "$work/no_op.sh" "" "" STATE="$state" RUN_URL=https://example.invalid/run
  expect "${state:0:1}  $state: no-op step succeeds" "$(code "$c")" 0
  json="$(output "$c" no_op_json)"
  expect "${state:0:1}  $state: no_op_json" "$(jq -c '[.schema_version, .result, .reason, .pull_request, .state]' <<<"$json")" \
    "[1,\"NO_OP\",\"PR_ALREADY_$state\",2,\"$state\"]"
  expect "${state:0:1}  $state: summary says NO_OP, Reviewer not executed" \
    "$(grep -c -e '^Result: \*\*NO_OP\*\*' -e '^- Reviewer: NOT EXECUTED$' "$c/summary")" 2
done

# --- Race: OPEN at first read, merged before Claude -------------------------------------------
c="$work/race"
run_step "$c" "$work/context.sh" "$(pr OPEN)" ""
run_step "$c" "$work/recheck.sh" "" "$(pr_state MERGED)"
expect "R  merged after the context: re-check succeeds" "$(code "$c")" 0
expect "R  merged after the context: re-check reports MERGED (Claude skipped)" "$(output "$c" state)" MERGED

# --- Case D: technical failures stay failures, never NO_OP ------------------------------------
c="$work/api-down"
run_step "$c" "$work/context.sh" "FAIL:HTTP 502: Bad Gateway (https://api.github.com/graphql)" ""
expect "D  API failure: context step fails" "$(code "$c")" 1
expect "D  API failure: no state, so no NO_OP" "$(output "$c" state)" ""

c="$work/forbidden"
run_step "$c" "$work/context.sh" "FAIL:GraphQL: Resource not accessible by integration (HTTP 403)" ""
expect "D  permission failure: context step fails" "$(code "$c")" 1
expect "D  permission failure: no state, so no NO_OP" "$(output "$c" state)" ""

c="$work/not-found"
run_step "$c" "$work/context.sh" "null" ""
expect "D  PR not found: context step fails" "$(code "$c")/$(output "$c" state)" 1/

c="$work/unknown"
run_step "$c" "$work/context.sh" "$(pr DRAFT)" ""
expect "D  unknown state: context step fails" "$(code "$c")/$(output "$c" state)" 1/

c="$work/recheck-down"
run_step "$c" "$work/recheck.sh" "" "FAIL:HTTP 502: Bad Gateway (https://api.github.com/graphql)"
expect "D  API failure on re-check: step fails, no state" "$(code "$c")/$(output "$c" state)" 1/

c="$work/no-op-guard"
run_step "$c" "$work/no_op.sh" "" "" STATE=OPEN RUN_URL=https://example.invalid/run
expect "D  no-op step refuses an OPEN state" "$(code "$c")/$(output "$c" no_op_json)" 1/

# --- Case E: review cycle -------------------------------------------------------------------
for k in 1 2 3; do
  expect "E  iterate_$k needs a REQUEST_CHANGES verdict (NO_OP has none)" \
    "$(yq ".jobs.iterate_$k.if" "$cycle_yml")" \
    "needs.review_$k.outputs.verdict == 'REQUEST_CHANGES' && inputs.max_iterations >= $k"
done
expect "E  NO_OP does not fail the cycle run" \
  "$(yq '.jobs.summary.steps[] | select(.name == "Fail on technical failure") | .if' "$cycle_yml")" \
  "always() && !contains(fromJSON('[\"APPROVED\", \"BLOCKED\", \"MAX_ITERATIONS_REACHED\", \"NO_OP\"]'), steps.result.outputs.result)"

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
no_op() {
  jq -n --arg r "$1" '{result: "success", outputs: {verdict: "", review_json: "",
    no_op_json: ({schema_version: 1, result: "NO_OP", reason: $r, pull_request: 2} | tojson)}}'
}
iterate() { jq -n --arg r "$1" '{result: "success", outputs: {result: $r, commit_sha: "", iteration_json: ""}}'; }

json="$(cycle "$(needs "$(no_op PR_ALREADY_MERGED)" "$skipped" "$skipped")")"
expect "E  Reviewer #1 NO_OP -> cycle NO_OP" "$(jq -r .result <<<"$json")" NO_OP
expect "E  NO_OP: no Iterator, no other Reviewer" "$(jq -c '[.timeline[].job]' <<<"$json")" '["review_1"]'
expect "E  NO_OP: reason recorded" "$(jq -r '.timeline[0].no_op_reason' <<<"$json")" PR_ALREADY_MERGED
expect "E  NO_OP: no final verdict, no iteration" \
  "$(jq -r '"\(.final_reviewer_verdict)/\(.iterations_used)"' <<<"$json")" /0
expect "E  NO_OP: summary" "$(grep -c -e '^Result: \*\*NO_OP\*\*' -e 'NO_OP\*\* (PR_ALREADY_MERGED), not executed' \
  "$work/last-cycle-summary")" 2

json="$(cycle "$(needs "$(review REQUEST_CHANGES)" "$(iterate PARTIAL)" "$(no_op PR_ALREADY_CLOSED)")")"
expect "E  closed before Reviewer #2 -> NO_OP, not MAX_ITERATIONS_REACHED" \
  "$(jq -r '"\(.result)/\(.iterations_used)/\(.final_reviewer_verdict)"' <<<"$json")" NO_OP/1/REQUEST_CHANGES

# Non-regression of the existing results next to NO_OP.
expect "E  Reviewer #1 APPROVE -> APPROVED" \
  "$(cycle "$(needs "$(review APPROVE)" "$skipped" "$skipped")" | jq -r .result)" APPROVED
expect "E  Reviewer #1 BLOCKED -> BLOCKED" \
  "$(cycle "$(needs "$(review BLOCKED)" "$skipped" "$skipped")" | jq -r .result)" BLOCKED
expect "E  failed Reviewer -> FAILED, never NO_OP" \
  "$(cycle "$(needs '{"result": "failure", "outputs": {}}' "$skipped" "$skipped")" | jq -r .result)" FAILED

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed."
  exit 1
fi
echo "All checks passed."
