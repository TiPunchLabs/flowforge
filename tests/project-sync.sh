#!/usr/bin/env bash
# Tests of the GitHub Project sync (Phase 6, Prompt 28): .github/scripts/flowforge-project.sh
# and the REAL Project steps of the reusable workflows that source it.
#   A  decision table: events, allowed sources, stale guard, idempotence, unknown values
#   B  GraphQL layer against a `gh` stub that keeps Project items in files: find-or-add,
#      single item, no write on replay, best-effort errors, token separation
#   C  workflow steps: event chosen from each workflow's real outcome, guards
#   D  static invariants: opt-in, token scope, revoke before Claude, continue-on-error,
#      no Project -> workflow trigger, Reviewer untouched
# No network, no token: `gh` is a stub on PATH.
#
# Requires: bash, jq, yq (mikefarah v4). Usage: tests/project-sync.sh
# shellcheck disable=SC2016  # single-quoted jq/yq programs and literal step text
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$root/.github/workflows"
helper="$root/.github/scripts/flowforge-project.sh"
state_helper="$root/.github/scripts/flowforge-state.sh"
config="$root/config/github-project.json"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }
expect() { # name, actual, expected
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

# shellcheck source=/dev/null
source "$helper"

# --- A: decision table ------------------------------------------------------------------------
decide() { flowforge_project_decide "$@" | jq -r '"\(.action) \(.status)/\(.attention)"'; }

while IFS='|' read -r event from to; do
  [[ -n "$event" ]] || continue
  expect "A  $event from ${from:-(none)}" "$(decide "$event" "$from" "")" "update $to"
done <<'EOF'
refine-started||Refining/
refine-started|Backlog|Refining/
refine-started|Ready|Refining/
refine-ready|Refining|Ready/
refine-needs-clarification|Refining|Backlog/Needs clarification
refine-blocked|Refining|Backlog/Blocked
develop-started||Developing/
develop-started|Backlog|Developing/
develop-started|Ready|Developing/
develop-delivered|Developing|Review/
develop-stopped|Developing|Backlog/Blocked
cycle-started|Human validation|Review/
cycle-started|Iteration|Review/
iterate-started|Review|Iteration/
iterate-completed|Iteration|Review/
cycle-approved|Review|Human validation/
cycle-blocked|Review|Human validation/Blocked
cycle-blocked|Iteration|Human validation/Blocked
cycle-max-iterations|Review|Human validation/Max iterations
pr-merged|Human validation|Done/
pr-closed|Review|Backlog/
pr-closed|Iteration|Backlog/
pr-closed|Human validation|Backlog/
issue-added||Backlog/
EOF

expect "A  re-run after Failed: same status, Attention cleared" \
  "$(decide refine-started Refining Failed)" "update Refining/"
expect "A  Refiner re-run on Needs clarification clears it (B3)" \
  "$(decide refine-started Backlog "Needs clarification")" "update Refining/"
for e in refine-failed develop-failed cycle-failed; do
  case "$e" in refine-*) s=Refining ;; develop-*) s=Developing ;; *) s=Review ;; esac
  expect "A  $e keeps $s, Attention Failed" "$(decide "$e" "$s" "")" "update $s/Failed"
done
expect "A  cycle-failed during Iteration stays Iteration" "$(decide cycle-failed Iteration "")" "update Iteration/Failed"
expect "A  failure on a card elsewhere: skipped" "$(decide develop-failed Review "")" "skipped Review/Failed"

# Idempotence: replaying an event on a card that shows it already writes nothing.
for c in "refine-ready|Ready|" "develop-started|Developing|" "cycle-blocked|Human validation|Blocked" \
         "pr-merged|Done|" "develop-failed|Developing|Failed" "iterate-completed|Review|"; do
  IFS='|' read -r e s a <<<"$c"
  expect "A  replay $e: unchanged" "$(decide "$e" "$s" "$a")" "unchanged $s/$a"
done

# Stale guard: the target is behind the card -> refused, whatever the event.
for c in "refine-ready|Review" "refine-ready|Developing" "refine-needs-clarification|Ready" \
         "develop-started|Review" "develop-started|Human validation" "develop-delivered|Human validation" \
         "refine-started|Done" "iterate-started|Human validation" "cycle-started|Done" "pr-closed|Done" \
         "iterate-completed|Done" "issue-added|Ready"; do
  IFS='|' read -r e s <<<"$c"
  expect "A  stale $e on $s: refused" "$(flowforge_project_decide "$e" "$s" "" | jq -r .action)" refused
done
expect "A  stale refusal says why" \
  "$(flowforge_project_decide refine-ready Review "" | jq -r .note)" "stale event: card already in Review, ahead of Ready"
expect "A  same rank, other column (Iteration vs Review): refused" \
  "$(flowforge_project_decide iterate-started Iteration "" | jq -r .action)/$(flowforge_project_decide cycle-approved Iteration "" | jq -r .action)" \
  "unchanged/update"

# Missed event: target ahead of an unexpected source -> applied with a note (execution wins).
for c in "pr-merged|Review|Done" "develop-delivered|Ready|Review" "cycle-approved|Iteration|Human validation" \
         "refine-ready||Ready" "pr-merged||Done"; do
  IFS='|' read -r e s t <<<"$c"
  out="$(flowforge_project_decide "$e" "$s" "")"
  expect "A  missed event $e from ${s:-(none)}: caught up" \
    "$(jq -r '"\(.action) \(.status) \(.note | test("unexpected source"))"' <<<"$out")" "update $t true"
done

expect "A  force bypasses the stale guard" "$(decide refine-ready Review "" 1)" "update Ready/"
expect "A  unknown current Status: refused" \
  "$(flowforge_project_decide develop-started Archived "" | jq -r '"\(.action): \(.note)"')" \
  "refused: current Status Archived is not a FlowForge status"
set +e
flowforge_project_decide develop-finished Ready "" >/dev/null 2>&1
code=$?
set -e
expect "A  unknown event: fails" "$((code != 0))" 1

expect "A  every event target is a configured Status option" \
  "$(jq -n --argjson e "$FLOWFORGE_PROJECT_EVENTS" --slurpfile c "$config" \
      '[$e[] | .status // empty] - ($c[0].fields.Status.options | keys) | length')" 0
expect "A  every event Attention is empty or a configured option" \
  "$(jq -n --argjson e "$FLOWFORGE_PROJECT_EVENTS" --slurpfile c "$config" \
      '[$e[] | .attention | select(. != "")] - ($c[0].fields.Attention.options | keys) | length')" 0
expect "A  every source and rank is a configured Status" \
  "$(jq -n --argjson e "$FLOWFORGE_PROJECT_EVENTS" --argjson r "$FLOWFORGE_PROJECT_RANKS" --slurpfile c "$config" \
      '(([$e[].from[]] + ($r | keys)) | unique | map(select(. != ""))) - ($c[0].fields.Status.options | keys) | length')" 0

# --- B: GraphQL layer with a gh stub ---------------------------------------------------------
# Items live in $FAKE_STATE/items.json, keyed by content node id: {id, status, attention}.
# Every call is logged with the token it used, so token separation can be checked.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
s="$FAKE_STATE"
args=("$@"); jqf=""; declare -A v=()
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --jq) jqf="${args[i+1]}" ;;
    -f | -F) kv="${args[i+1]}"; v["${kv%%=*}"]="${kv#*=}" ;;
  esac
done
out() { if [[ -n "$jqf" ]]; then jq -r "$jqf"; else cat; fi; }
q="${v[query]:-}"
printf '%s token=%s %s\n' "$1 ${2:-}" "${GH_TOKEN:-}" "$(sed -E 's/query=.*//' <<<"${args[*]:2}" | tr '\n' ' ')" \
  | sed -E 's/  +/ /g' >> "$s/gh.log"
[[ -z "${FAKE_FAIL:-}" || "$*" != *"$FAKE_FAIL"* ]] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
case "$*" in
  *"contents/.github/scripts/flowforge-project.sh?ref="*) cat "$FAKE_HELPER" ;;
  *"contents/.github/scripts/flowforge-state.sh?ref="*) cat "$FAKE_STATE_HELPER" ;;
  *"contents/config/github-project.json?ref="*) cat "$FAKE_CONFIG" ;;
  "api --method DELETE installation/token"*) echo revoked >> "$s/revoked" ;;
  "api repos/"*"/issues/"*)
    path="${2#repos/}"; repo="${path%/issues/*}"; n="${path##*/}"
    f="$s/issues/${repo//\//_}-$n.json"
    [[ -f "$f" ]] || { echo "HTTP 404: Not Found" >&2; exit 1; }
    out < "$f" ;;
  "api graphql"*)
    case "$q" in
      *addProjectV2ItemById*)
        [[ "${v[project]}" == "$(jq -r .project_id "$FAKE_CONFIG")" ]] || { echo "wrong project" >&2; exit 1; }
        c="${v[content]}"
        jq --arg c "$c" 'if has($c) then . else .[$c] = {id: "PVTI_\($c)", status: null, attention: null} end' \
          "$s/items.json" > "$s/tmp" && mv "$s/tmp" "$s/items.json"
        jq --arg c "$c" '{data: {addProjectV2ItemById: {item: (.[$c] | {id,
          status: (if .status then {name: .status} else null end),
          attention: (if .attention then {name: .attention} else null end)})}}}' "$s/items.json" | out ;;
      *updateProjectV2ItemFieldValue* | *clearProjectV2ItemFieldValue*)
        field="$(jq -r --arg f "${v[field]}" '.fields | to_entries[] | select(.value.id == $f) | .key' "$FAKE_CONFIG")"
        key="$(tr '[:upper:]' '[:lower:]' <<<"$field")"
        name=""
        if [[ -n "${v[option]:-}" ]]; then
          name="$(jq -r --arg f "$field" --arg o "${v[option]}" \
            '.fields[$f].options | to_entries[] | select(.value == $o) | .key' "$FAKE_CONFIG")"
          [[ -n "$name" ]] || { echo "unknown option" >&2; exit 1; }
        fi
        jq --arg i "${v[item]}" --arg k "$key" --arg n "$name" \
          'with_entries(if .value.id == $i then .value[$k] = (if $n == "" then null else $n end) else . end)' \
          "$s/items.json" > "$s/tmp" && mv "$s/tmp" "$s/items.json"
        [[ " $* " == *' --silent '* ]] || echo '{}' ;;
      *pullRequest*) jq '{data: {repository: {pullRequest: .}}}' "$s/pr.json" | out ;;
      *) echo "gh stub: unexpected GraphQL query" >&2; exit 1 ;;
    esac ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"

# new_case <name> [items JSON]: fresh stub state with Issue owner/target#1 (node I_1),
# PR owner/target#2 and Issue other/repo#1 (node I_other). Prints its dir.
new_case() {
  local dir="$work/$1"
  mkdir -p "$dir/issues"
  printf '%s\n' "${2:-{\}}" > "$dir/items.json"
  echo '{"number": 1, "node_id": "I_1"}' > "$dir/issues/owner_target-1.json"
  echo '{"number": 2, "node_id": "PR_2", "pull_request": {}}' > "$dir/issues/owner_target-2.json"
  echo '{"number": 1, "node_id": "I_other"}' > "$dir/issues/other_repo-1.json"
  touch "$dir/gh.log" "$dir/github_output" "$dir/summary"
  echo "$dir"
}
item() { jq -c --arg c "${2:-I_1}" '.[$c] | if . then {status, attention} else null end' "$1/items.json"; }
writes() { grep -cE 'graphql.*(option=|field=)' "$1/gh.log" || true; }
pr_fixture() {
  jq -cn --arg s "$2" --argjson i "$3" \
    '{number: 2, state: $s, closingIssuesReferences: {nodes: [$i[] | {number: ., repository: {nameWithOwner: "owner/target"}}]}}' \
    > "$1/pr.json"
}
# sync <dir> <issue> <event> [env...]: runs flowforge_project_sync like a workflow step would.
sync() {
  local dir="$1"
  set +e
  env PATH="$work/bin:$PATH" FAKE_STATE="$dir" FAKE_CONFIG="$config" GH_TOKEN=repo-token \
    PROJECT_TOKEN=project-token PROJECT_NUMBER=1 GITHUB_REPOSITORY=owner/target \
    FLOWFORGE_PROJECT_CONFIG="$config" GITHUB_STEP_SUMMARY="$dir/summary" "${@:4}" \
    bash --noprofile --norc -c 'set -euo pipefail; source "$1"; flowforge_project_sync "$2" "$3"' _ \
    "$helper" "$2" "$3" > "$dir/log" 2>&1
  echo $? > "$dir/exit"
  set -e
}
code() { cat "$1/exit"; }

c="$(new_case b-add)"
sync "$c" 1 refine-started
expect "B  absent Issue: added and set Refining" "$(code "$c")/$(item "$c")" '0/{"status":"Refining","attention":null}'
expect "B  log names repository, previous and new status, reason" "$(grep -c 'Project sync owner/target#1 \[Refiner started\]: update — Status (none) → Refining' "$c/log")" 1
expect "B  transition in the step summary" "$(grep -c 'Status (none) → Refining' "$c/summary")" 1
sync "$c" 1 refine-started
expect "B  replay: one item only" "$(jq 'length' "$c/items.json")" 1
expect "B  replay: no second field write" "$(writes "$c")" 1
expect "B  replay: reported unchanged" "$(grep -c ': unchanged —' "$c/log")" 1

c="$(new_case b-flow)"
for e in refine-started refine-ready develop-started develop-delivered iterate-started iterate-completed cycle-approved pr-merged; do
  sync "$c" 1 "$e"
done
expect "B  full flow Backlog → … → Done on one item" "$(jq 'length' "$c/items.json")/$(item "$c")" '1/{"status":"Done","attention":null}'

c="$(new_case b-att '{"I_1": {"id": "PVTI_I_1", "status": "Refining", "attention": null}}')"
sync "$c" 1 refine-needs-clarification
expect "B  NEEDS_CLARIFICATION: Backlog + Attention" "$(item "$c")" '{"status":"Backlog","attention":"Needs clarification"}'
sync "$c" 1 refine-started
expect "B  next event clears Attention" "$(item "$c")" '{"status":"Refining","attention":null}'
sync "$c" 1 refine-failed
expect "B  failure: Attention Failed, card stays" "$(item "$c")" '{"status":"Refining","attention":"Failed"}'

c="$(new_case b-stale '{"I_1": {"id": "PVTI_I_1", "status": "Review", "attention": null}}')"
sync "$c" 1 refine-ready
expect "B  stale event: refused, no write, step still succeeds" "$(code "$c")/$(writes "$c")/$(item "$c")" '0/0/{"status":"Review","attention":null}'
expect "B  stale event: warning" "$(grep -c '^::warning::.*stale event' "$c/log")" 1
sync "$c" 1 refine-ready FLOWFORGE_PROJECT_FORCE=1
expect "B  forced: applied" "$(item "$c")" '{"status":"Ready","attention":null}'

c="$(new_case b-repo '{"I_other": {"id": "PVTI_I_other", "status": "Review", "attention": null}}')"
sync "$c" 1 develop-started
expect "B  same number in another repository: untouched" "$(item "$c" I_other)/$(item "$c")" \
  '{"status":"Review","attention":null}/{"status":"Developing","attention":null}'

c="$(new_case b-tokens)"
sync "$c" 1 develop-started
expect "B  Issue read with the repository token only" "$(grep '^api repos/' "$c/gh.log" | grep -vc 'token=repo-token' || true)" 0
expect "B  Project calls with the Project token only" "$(grep '^api graphql' "$c/gh.log" | grep -vc 'token=project-token' || true)" 0
expect "B  no token value in the log" "$(grep -c 'project-token\|repo-token' "$c/log" || true)" 0

c="$(new_case b-pr)"
sync "$c" 2 develop-started
expect "B  a pull request number is refused (warning, no write)" "$(code "$c")/$(jq length "$c/items.json")/$(grep -c 'is a pull request' "$c/log")" 0/0/1

for case in "notoken|PROJECT_TOKEN=|no Project token" "number|PROJECT_NUMBER=7|does not match the IDs file" \
            "api|FAKE_FAIL=addProjectV2ItemById|could not add or read" "issue|FAKE_FAIL=issues/1|not readable"; do
  IFS='|' read -r name envv msg <<<"$case"
  c="$(new_case "b-err-$name")"
  sync "$c" 1 develop-started "$envv"
  expect "B  error ($name): step succeeds, card unchanged" "$(code "$c")/$(jq length "$c/items.json")" 0/0
  expect "B  error ($name): visible warning + summary" \
    "$(grep -c "^::warning::Project sync owner/target#1 \[develop-started\] failed: .*$msg" "$c/log")/$(grep -c '⚠️' "$c/summary")" 1/1
done
c="$(new_case b-strict)"
sync "$c" 1 develop-started FAKE_FAIL=addProjectV2ItemById FLOWFORGE_PROJECT_STRICT=1
expect "B  strict mode (maintainer CLI): error fails" "$(code "$c")" 1
c="$(new_case b-unknown)"
sync "$c" 1 develop-finished
expect "B  unknown event: warning, nothing written" "$(code "$c")/$(jq length "$c/items.json")/$(grep -c "unknown event" "$c/log")" 0/0/1

# --- C: real workflow steps -------------------------------------------------------------------
step() { yq -e ".jobs.$2.steps[] | select(.name == \"$3\") | .run" "$wf/$1"; }
step agent-develop.yml develop "Project status (Developer started)" > "$work/dev-start.sh"
step agent-develop.yml develop "Project status (Developer result)" > "$work/dev-result.sh"
step agent-refine.yml refine "Project status (Refiner started)" > "$work/ref-start.sh"
step agent-refine.yml refine "Project status (Refiner failed)" > "$work/ref-failed.sh"
step agent-refine.yml publish "Project status (Refiner result)" > "$work/ref-result.sh"
step agent-iterate.yml iterate "Project status (Iterator started)" > "$work/it-start.sh"
step agent-iterate.yml publish "Project status (Iterator result)" > "$work/it-result.sh"
step review-cycle.yml project_start "Set Review" > "$work/cycle-start.sh"
step review-cycle.yml project_status "Apply cycle result" > "$work/cycle-result.sh"
step agent-lifecycle.yml terminal_state "Project status (terminal state)" > "$work/life.sh"

# run <dir> <script> [env...]: like Actions (bash -e -o pipefail), helpers fetched via the stub.
run() {
  local dir="$1" script="$2"
  set +e
  env PATH="$work/bin:$PATH" FAKE_STATE="$dir" FAKE_CONFIG="$config" FAKE_HELPER="$helper" \
    FAKE_STATE_HELPER="$state_helper" GH_TOKEN=repo-token PROJECT_TOKEN=project-token PROJECT_NUMBER=1 \
    GITHUB_REPOSITORY=owner/target GITHUB_OUTPUT="$dir/github_output" GITHUB_STEP_SUMMARY="$dir/summary" \
    FLOWFORGE_REPOSITORY=owner/flowforge FLOWFORGE_SHA=abc123 ISSUE_NUMBER=1 PR_NUMBER=2 RUNNER_TEMP="$dir" \
    "${@:3}" bash --noprofile --norc -eo pipefail "$script" > "$dir/log" 2>&1
  echo $? > "$dir/exit"
  set -e
}
at() { printf '{"I_1": {"id": "PVTI_I_1", "status": "%s", "attention": null}}' "$1"; }

c="$(new_case c-dev-start "$(at Ready)")"
run "$c" "$work/dev-start.sh"
expect "C  Developer started: Ready → Developing" "$(code "$c")/$(item "$c")" '0/{"status":"Developing","attention":null}'
expect "C  helper and IDs fetched at the pinned FlowForge commit" \
  "$(grep -c 'owner/flowforge/contents/.github/scripts/flowforge-project.sh?ref=abc123' "$c/gh.log")/$(grep -c 'contents/config/github-project.json?ref=abc123' "$c/gh.log")" 1/1
step agent-develop.yml develop "Revoke Project token" > "$work/revoke.sh"
c="$(new_case c-revoke)"
run "$c" "$work/revoke.sh" PROJECT_TOKEN=start-token
expect "C  revoke step deletes the installation token it was given" \
  "$(cat "$c/revoked" 2>/dev/null)/$(grep -c '^api --method token=start-token DELETE installation/token' "$c/gh.log")" revoked/1

while IFS='|' read -r outcome state expected; do
  c="$(new_case "c-dev-$outcome-${state#agent:}" "$(at Developing)")"
  run "$c" "$work/dev-result.sh" FINALIZE_OUTCOME="$outcome" FINAL_STATE="$state"
  expect "C  Developer result $outcome/${state:-none} → $expected" "$(code "$c")/$(item "$c")" "0/$expected"
done <<'EOF'
success|agent:review|{"status":"Review","attention":null}
success|agent:blocked|{"status":"Backlog","attention":"Blocked"}
success||{"status":"Developing","attention":"Failed"}
failure|agent:review|{"status":"Developing","attention":"Failed"}
EOF

c="$(new_case c-ref-start)"
run "$c" "$work/ref-start.sh"
expect "C  Refiner started: Issue added, Refining" "$(code "$c")/$(item "$c")" '0/{"status":"Refining","attention":null}'
c="$(new_case c-ref-failed "$(at Refining)")"
run "$c" "$work/ref-failed.sh"
expect "C  Refiner failed: Refining + Failed" "$(item "$c")" '{"status":"Refining","attention":"Failed"}'
while IFS='|' read -r outcome verdict expected; do
  c="$(new_case "c-ref-$outcome-$verdict" "$(at Refining)")"
  run "$c" "$work/ref-result.sh" APPLY_OUTCOME="$outcome" VERDICT="$verdict"
  expect "C  Refiner result $outcome/$verdict → $expected" "$(code "$c")/$(item "$c")" "0/$expected"
done <<'EOF'
success|READY|{"status":"Ready","attention":null}
success|NEEDS_CLARIFICATION|{"status":"Backlog","attention":"Needs clarification"}
success|BLOCKED|{"status":"Backlog","attention":"Blocked"}
failure|READY|{"status":"Refining","attention":"Failed"}
EOF

c="$(new_case c-it-start "$(at Review)")"
run "$c" "$work/it-start.sh"
expect "C  Iterator started: Review → Iteration" "$(item "$c")" '{"status":"Iteration","attention":null}'
c="$(new_case c-it-result "$(at Iteration)")"
mkdir -p "$c/flowforge-iterate"
echo '{"issue": 1, "result": "COMPLETED"}' > "$c/flowforge-iterate/iteration.json"
run "$c" "$work/it-result.sh"
expect "C  Iterator COMPLETED: Iteration → Review (Issue from iteration.json)" "$(code "$c")/$(item "$c")" '0/{"status":"Review","attention":null}'

c="$(new_case c-cycle-start "$(at "Human validation")")"
pr_fixture "$c" OPEN '[1]'
run "$c" "$work/cycle-start.sh"
expect "C  cycle re-dispatched: Human validation → Review (B1)" "$(item "$c")" '{"status":"Review","attention":null}'
while IFS='|' read -r result from expected; do
  c="$(new_case "c-cycle-$result" "$(at "$from")")"
  pr_fixture "$c" OPEN '[1]'
  run "$c" "$work/cycle-result.sh" RESULT="$result"
  expect "C  cycle $result from $from → $expected" "$(code "$c")/$(item "$c")" "0/$expected"
done <<'EOF'
APPROVED|Review|{"status":"Human validation","attention":null}
BLOCKED|Iteration|{"status":"Human validation","attention":"Blocked"}
MAX_ITERATIONS_REACHED|Review|{"status":"Human validation","attention":"Max iterations"}
FAILED|Iteration|{"status":"Iteration","attention":"Failed"}
EOF
for g in "MERGED|[1]|is MERGED" "OPEN|[]|does not close exactly one Issue" "OPEN|[1,3]|does not close exactly one Issue"; do
  IFS='|' read -r st linked msg <<<"$g"
  c="$(new_case "c-guard-$st-$(jq length <<<"$linked")" "$(at Review)")"
  pr_fixture "$c" "$st" "$linked"
  run "$c" "$work/cycle-result.sh" RESULT=APPROVED
  expect "C  cycle guard ($st, $(jq length <<<"$linked") Issue(s)): no Project write" \
    "$(code "$c")/$(writes "$c")/$(grep -c "$msg" "$c/log")" 0/0/1
done

c="$(new_case c-life-merged "$(at "Human validation")")"
run "$c" "$work/life.sh" EVENT=pr-merged
expect "C  PR merged: Human validation → Done" "$(item "$c")" '{"status":"Done","attention":null}'
c="$(new_case c-life-closed "$(at Review)")"
run "$c" "$work/life.sh" EVENT=pr-closed
expect "C  PR closed unmerged: Review → Backlog" "$(item "$c")" '{"status":"Backlog","attention":null}'

# The terminal and final Developer steps publish what the Project steps consume.
step agent-lifecycle.yml terminal_state "Apply terminal state" > "$work/terminal.sh"
expect "C  terminal step: outputs issue + event" \
  "$(grep -c 'echo "event=$(if \[\[ "$state" == MERGED \]\]; then echo pr-merged; else echo pr-closed; fi)"' "$work/terminal.sh")/$(grep -c 'echo "issue=$issue"' "$work/terminal.sh")" 1/1
expect "C  Developer final step: outputs its state label" "$(grep -c 'echo "state=$label"' <(step agent-develop.yml develop "Enforce Draft PR and set final label"))" 1

# --- D: static invariants ---------------------------------------------------------------------
project_workflows=(agent-develop.yml agent-refine.yml agent-iterate.yml review-cycle.yml agent-lifecycle.yml)
for f in "${project_workflows[@]}"; do
  expect "D  $f: project_number input, default 0 (opt-in)" \
    "$(yq '.on.workflow_call.inputs.project_number | "\(.type) \(.default) \(.required)"' "$wf/$f")" "number 0 false"
  expect "D  $f: every Project token = organization projects only" \
    "$(yq '[.jobs[].steps[]? | select(.uses // "" | test("create-github-app-token")) | select(.with["permission-organization-projects"])
            | (.with | del(.["client-id"], .["private-key"], .["skip-token-revoke"]) | to_entries | map("\(.key)=\(.value)") | join(","))] | unique | join(";")' "$wf/$f")" \
    "permission-organization-projects=write"
  expect "D  $f: only start tokens skip the action's revoke (they have their own revoke step)" \
    "$(yq '[.jobs[].steps[]? | select(.with["permission-organization-projects"]) | select((.with["skip-token-revoke"] == true) != (.id == "project_token_start"))] | length' "$wf/$f")" 0
  expect "D  $f: every Project step is best-effort (continue-on-error)" \
    "$(yq '[.jobs[].steps[]? | select((.name // "" | test("^(Project status|Create Project token|Set Review|Apply cycle result)")) and (.continue-on-error != true))] | length' "$wf/$f")" 0
  expect "D  $f: every Project sync gated by project_number (step or job)" \
    "$(yq '[.jobs[] | select(.steps) | . as $j | .steps[] | select(.run // "" | test("flowforge_project_sync"))
            | select(((.if // "") + " " + ($j.if // "")) | test("project_number > 0") | not)] | length' "$wf/$f")" 0
done
expect "D  review-cycle: Project jobs gated by project_number" \
  "$(yq '[.jobs.project_start.if, .jobs.project_status.if] | map(test("inputs.project_number > 0")) | all' "$wf/review-cycle.yml")" true
expect "D  review-cycle: NO_OP writes nothing to the Project" \
  "$(yq '.jobs.project_status.if | test("result != .NO_OP.")' "$wf/review-cycle.yml")" true
expect "D  review-cycle: project_number forwarded to the three Iterators" \
  "$(yq '[.jobs.iterate_1, .jobs.iterate_2, .jobs.iterate_3] | map(.with.project_number == "${{ inputs.project_number }}") | all' "$wf/review-cycle.yml")" true
expect "D  Reviewer workflow untouched (stand-alone review changes no status)" \
  "$(grep -c 'project' "$wf/agent-review.yml" || true)/$(yq '[.jobs.review_1, .jobs.review_2, .jobs.review_3, .jobs.review_4] | map(.secrets | has("app_private_key")) | any' "$wf/review-cycle.yml")" 0/false

# Token dead before Claude: in each job running Claude, start token -> start sync -> revoke step
# (always) -> Claude, and no Project token is minted between the revoke and Claude.
for spec in "agent-develop.yml develop" "agent-refine.yml refine" "agent-iterate.yml iterate"; do
  read -r f job <<<"$spec"
  order="$(yq -o=json ".jobs.$job.steps" "$wf/$f" | jq -r '
    (map(.uses // "" | test("claude-code-action")) | index(true)) as $claude
    | (map(.id == "project_token_start") | index(true)) as $token
    | (map(.run // "" | test("flowforge_project_sync")) | index(true)) as $sync
    | (map(.name == "Revoke Project token") | index(true)) as $revoke
    | ([to_entries[] | select(.key > $revoke and .key < $claude and (.value.uses // "" | test("create-github-app-token")))] | length) as $between
    | (.[$revoke] | "\(.if | test("^always\\(\\) && .*steps.project_token_start.outputs.token != .."))") as $always
    | "\($token < $sync and $sync < $revoke and $revoke < $claude) \($between) \($always)"')"
  expect "D  $f/$job: token -> sync -> revoke (always) -> Claude, nothing minted in between" "$order" "true 0 true"
done

expect "D  no Project event ever triggers a workflow (one-way sync)" \
  "$(grep -rlE '^\s*(projects_v2_item|project_card|project_column|project):' "$wf" "$root/examples" | wc -l)" 0
expect "D  no Project ID hard-coded outside the IDs file" \
  "$(grep -rlE 'PVT_|PVTSSF_|PVTF_' "$wf" "$root/.github/scripts" "$root/examples" | wc -l)" 0
expect "D  callers: project_number from the organization variable, default 0" \
  "$(grep -l "project_number: \${{ fromJSON(vars.FLOWFORGE_PROJECT_NUMBER || '0') }}" "$root"/examples/target-repository/*.yml | wc -l)" 4
expect "D  callers: no secrets: inherit" "$(cat "$root"/examples/target-repository/*.yml | grep -cE '^[[:space:]]+secrets: inherit' || true)" 0

echo
if (( failures > 0 )); then
  echo "$failures test(s) failed."
  exit 1
fi
echo "All Project sync tests passed."
