#!/usr/bin/env bash
# Tests of the Iterator result rules (agents/iterator.md, section 10) and of the
# Iterator -> Reviewer gates, run against the REAL step scripts of the workflows:
#   agent-iterate.yml  iterate/"Validate iteration result"  (result rules + Git contract)
#   agent-iterate.yml  publish/"Render iteration result"    (Delivered / Remaining)
#   review-cycle.yml   summary/"Compute cycle result" and the review_k / iterate_k gates
# Each scenario builds a throwaway Git repository playing the PR head branch, applies the
# "agent" commit, feeds a structured output to the step and checks what it would push.
#
# Requires: bash, git, jq, yq (mikefarah v4). Usage: tests/iterator-partial-delivery.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
iterate_yml="$root/.github/workflows/agent-iterate.yml"
cycle_yml="$root/.github/workflows/review-cycle.yml"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

# Git isolated from the user's configuration (hooks, signing, identity).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

step() { yq -e ".jobs.$2.steps[] | select(.name == \"$3\") | .run" "$1"; }
step "$iterate_yml" iterate "Validate iteration result" > "$work/validate.sh"
step "$iterate_yml" publish "Render iteration result" > "$work/render.sh"
step "$cycle_yml" summary "Compute cycle result" > "$work/cycle.sh"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }
expect() { # name, actual, expected
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
output() { sed -n "s/^$2=//p" "$1/github_output" | tail -n 1; }

# A PR head branch with application code, tests, and protected paths.
new_case() {
  local case_dir="$work/$1"
  mkdir -p "$case_dir/repo/.github/workflows" "$case_dir/runner/flowforge-iterate"
  (
    cd "$case_dir/repo"
    git init -q -b agent/1-feature
    printf 'def app():\n    return 1\n' > app.py
    printf 'def test_app():\n    assert True\n' > test_app.py
    printf 'name: ci\n' > .github/workflows/ci.yml
    printf '# rules\n' > CLAUDE.md
    git add . && git commit -q -m "feat: initial"
  )
  printf '%s\n' "$case_dir"
}

# Work list: one item per severity given, ids 1..n.
worklist() {
  jq -n '$ARGS.positional | to_entries | map({id: (.key + 1), source: "review",
    severity: .value, title: "Finding \(.key + 1)", file: "app.py", line_or_range: "N/A",
    description: "d", reason: "r", expected_fix: "f"})' --args "$@"
}

# Runs the validation step in the case repository with the given structured output.
validate() { # case_dir, worklist_json, structured_output
  local dir="$1/runner/flowforge-iterate" head
  head="$(git -C "$1/repo" rev-list --max-parents=0 HEAD)"  # the reviewed commit
  printf '%s\n' "$2" > "$dir/worklist.json"
  jq -n --arg sha "$head" '{baseRefName: "main", headRefName: "agent/1-feature", headRefOid: $sha}' > "$dir/pr.json"
  echo '{"number": 1}' > "$dir/issue.json"
  : > "$1/github_output"
  (
    cd "$1/repo"
    env RUNNER_TEMP="$1/runner" GITHUB_OUTPUT="$1/github_output" GITHUB_STEP_SUMMARY=/dev/null \
      GITHUB_REPOSITORY=owner/target PR_NUMBER=2 ITERATION=1 MAX_ITERATIONS=3 \
      CLAUDE_OUTCOME=success STRUCTURED_OUTPUT="$3" RUN_URL=https://example.invalid/run \
      ARTIFACT=flowforge-iteration-pr-2-1 \
      bash --noprofile --norc -eo pipefail "$work/validate.sh" > "$1/validate.log" 2>&1
  ) || fail "$1" "validation step crashed: $(tail -n 3 "$1/validate.log")"
}

# Agent-side commit: edits the given files, commits them.
agent_commit() { # case_dir, files...
  local case_dir="$1"; shift
  (cd "$case_dir/repo" && for f in "$@"; do printf '# fix\n' >> "$f"; done \
    && git add -- "$@" && git commit -q -m "fix: address FlowForge review findings" -m "Refs #1")
}

# Structured output: one "STATUS:files" per item, files comma-separated; "NOT_ACTIONABLE:protected"
# marks a finding left alone because it needs a protected path.
agent_output() { # result, blocked_reason, validation_outcome, item...
  local result="$1" reason="$2" outcome="$3"; shift 3
  jq -n --arg result "$result" --arg reason "$reason" --arg outcome "$outcome" '
    {result: $result, summary: "s", blocked_reason: $reason, diff_assessment: "minimal",
     validations: [{command: "uv run pytest", outcome: $outcome, details: "ok"}],
     findings: ($ARGS.positional | to_entries | map(
       (.value | split(":")) as [$status, $files]
       | {id: (.key + 1), status: $status,
          files: (if $status == "FIXED" then ($files | split(",")) else [] end),
          explanation: (if $status == "FIXED" then "fixed"
                        elif $files == "protected" then "Human required: protected file .github/workflows/ci.yml"
                        else "Cannot be fixed reliably: needs a product decision." end)}))}' \
    --args "$@"
}

# --- Scenario A / F: everything fixable -> COMPLETED, pushed --------------------------------
c="$(new_case completed)"
agent_commit "$c" app.py test_app.py
validate "$c" "$(worklist MAJOR MAJOR)" \
  "$(agent_output COMPLETED "" PASS FIXED:app.py FIXED:test_app.py)"
expect "A  FIXED+FIXED -> COMPLETED" "$(output "$c" result)" COMPLETED
expect "A  COMPLETED is pushed" "$(output "$c" push)" true

c="$(new_case completed-already)"
agent_commit "$c" app.py
validate "$c" "$(worklist MAJOR MAJOR MINOR)" \
  "$(agent_output COMPLETED "" PASS FIXED:app.py ALREADY_RESOLVED: NOT_ACTIONABLE:)"
expect "F  FIXED+ALREADY_RESOLVED+MINOR skipped -> COMPLETED" "$(output "$c" result)" COMPLETED

# --- Scenario B: a mandatory NOT_ACTIONABLE no longer blocks the fixes ----------------------
c="$(new_case partial)"
agent_commit "$c" app.py test_app.py
validate "$c" "$(worklist MAJOR MAJOR MAJOR)" \
  "$(agent_output PARTIAL "" PASS FIXED:app.py FIXED:test_app.py NOT_ACTIONABLE:)"
expect "B  FIXED+FIXED+NOT_ACTIONABLE -> PARTIAL" "$(output "$c" result)" PARTIAL
expect "B  PARTIAL is pushed" "$(output "$c" push)" true
json="$c/runner/flowforge-iterate/result/iteration.json"
expect "B  produced by the Iterator" "$(jq -r '.produced_by' "$json")" iterator
expect "B  every finding kept" "$(jq -c '[.findings[].status]' "$json")" '["FIXED","FIXED","NOT_ACTIONABLE"]'
expect "B  remaining finding has a reason" "$(jq -r '.findings[2].explanation | length > 0' "$json")" true

# --- Individual BLOCKED != global BLOCKED (A, B, D fixed, C blocked) ------------------------
c="$(new_case partial-blocked)"
agent_commit "$c" app.py test_app.py
validate "$c" "$(worklist MAJOR MAJOR MAJOR MINOR)" \
  "$(agent_output PARTIAL "" PASS FIXED:app.py FIXED:test_app.py BLOCKED: FIXED:app.py)"
expect "B' FIXED+FIXED+BLOCKED+FIXED -> PARTIAL" "$(output "$c" result)" PARTIAL
expect "B' PARTIAL with an individual BLOCKED is pushed" "$(output "$c" push)" true

# --- Scenario C: nothing deliverable -> BLOCKED, nothing pushed -----------------------------
c="$(new_case blocked)"
validate "$c" "$(worklist MAJOR MAJOR)" \
  "$(agent_output BLOCKED "No finding can be fixed safely." PASS BLOCKED: NOT_ACTIONABLE:)"
expect "C  BLOCKED+NOT_ACTIONABLE -> BLOCKED" "$(output "$c" result)" BLOCKED
expect "C  BLOCKED is not pushed" "$(output "$c" push)" false
expect "C  BLOCKED is an agent result" "$(output "$c" reliable)" true

c="$(new_case partial-nothing-fixed)"
validate "$c" "$(worklist MAJOR MAJOR)" \
  "$(agent_output PARTIAL "" PASS BLOCKED: NOT_ACTIONABLE:)"
expect "C' PARTIAL without any FIXED is rejected" "$(output "$c" result)/$(output "$c" reliable)" BLOCKED/false

c="$(new_case partial-validation-fail)"
agent_commit "$c" app.py
validate "$c" "$(worklist MAJOR MAJOR)" \
  "$(agent_output PARTIAL "" FAIL FIXED:app.py NOT_ACTIONABLE:)"
expect "C' PARTIAL with a failing validation is rejected" "$(output "$c" result)/$(output "$c" push)" BLOCKED/false

c="$(new_case completed-with-blocked)"
agent_commit "$c" app.py
validate "$c" "$(worklist MAJOR MINOR)" \
  "$(agent_output COMPLETED "" PASS FIXED:app.py BLOCKED:)"
expect "C' COMPLETED with a BLOCKED item is rejected" "$(output "$c" result)/$(output "$c" reliable)" BLOCKED/false

c="$(new_case partial-leftover)"
agent_commit "$c" app.py
printf '# abandoned attempt\n' >> "$c/repo/test_app.py"
validate "$c" "$(worklist MAJOR MAJOR)" \
  "$(agent_output PARTIAL "" PASS FIXED:app.py BLOCKED:)"
expect "C' PARTIAL with an abandoned change left behind is rejected" "$(output "$c" result)/$(output "$c" push)" BLOCKED/false

# --- Scenario D: protected file -> NOT_ACTIONABLE, other fixes delivered --------------------
c="$(new_case protected)"
agent_commit "$c" app.py test_app.py
validate "$c" "$(worklist MAJOR BLOCKER MAJOR)" \
  "$(agent_output PARTIAL "" PASS FIXED:app.py NOT_ACTIONABLE:protected FIXED:test_app.py)"
expect "D  normal+protected+normal -> PARTIAL" "$(output "$c" result)" PARTIAL
expect "D  PARTIAL is pushed" "$(output "$c" push)" true
json="$c/runner/flowforge-iterate/result/iteration.json"
expect "D  protected finding kept as BLOCKER NOT_ACTIONABLE" \
  "$(jq -r '.findings[1] | "\(.severity) \(.status)"' "$json")" "BLOCKER NOT_ACTIONABLE"
expect "D  commit does not touch the protected path" \
  "$(git -C "$c/repo" diff --name-only HEAD~1 HEAD | grep -c '^\.github/' || true)" 0

# Render of the published result: Delivered / Remaining with the reason.
mkdir -p "$c/publish/flowforge-iterate"
cp "$json" "$c/publish/flowforge-iterate/iteration.json"
: > "$c/publish_output"
env RUNNER_TEMP="$c/publish" GITHUB_OUTPUT="$c/publish_output" GITHUB_STEP_SUMMARY=/dev/null \
  PUSH=false ARTIFACT=flowforge-iteration-pr-2-1 \
  bash --noprofile --norc -eo pipefail "$work/render.sh" > /dev/null
md="$(cat "$c/publish/flowforge-iterate/iteration.md")"
delivered="$(sed -n '/^### Delivered/,/^### Remaining/p' <<<"$md")"
remaining="$(sed -n '/^### Remaining/,/^### Changes/p' <<<"$md")"
expect "D  render: FIXED items under Delivered" "$(grep -c '^- FIXED' <<<"$delivered")" 2
expect "D  render: protected finding under Remaining" \
  "$(grep -c '^- NOT_ACTIONABLE — BLOCKER' <<<"$remaining")" 1
expect "D  render: reason shown" "$(grep -c 'Reason: Human required: protected file' <<<"$remaining")" 1

c="$(new_case protected-violated)"
agent_commit "$c" app.py .github/workflows/ci.yml
validate "$c" "$(worklist MAJOR BLOCKER)" \
  "$(agent_output COMPLETED "" PASS FIXED:app.py FIXED:.github/workflows/ci.yml)"
expect "D' commit touching a protected path is rejected" "$(output "$c" result)/$(output "$c" push)" BLOCKED/false

c="$(new_case protected-claude-md)"
agent_commit "$c" app.py CLAUDE.md
validate "$c" "$(worklist MAJOR BLOCKER)" \
  "$(agent_output PARTIAL "" PASS FIXED:app.py,CLAUDE.md NOT_ACTIONABLE:)"
expect "D' PARTIAL commit touching CLAUDE.md is rejected" "$(output "$c" result)/$(output "$c" push)" BLOCKED/false

# --- Scenario E: Iterator -> Reviewer gates and cycle result --------------------------------
for k in 2 3 4; do
  expect "E  review_$k runs after PARTIAL" \
    "$(yq ".jobs.review_$k.if" "$cycle_yml")" \
    "contains(fromJSON('[\"COMPLETED\", \"PARTIAL\"]'), needs.iterate_$((k - 1)).outputs.result)"
done
expect "E  exactly 3 Iterator jobs (max_iterations ceiling)" \
  "$(yq '[.jobs | keys | .[] | select(test("^iterate_"))] | length' "$cycle_yml")" 3

cycle() { # needs_json -> result
  local out="$work/cycle-$RANDOM"
  mkdir -p "$out"
  env RUNNER_TEMP="$out" GITHUB_OUTPUT="$out/output" GITHUB_STEP_SUMMARY=/dev/null \
    GITHUB_REPOSITORY=owner/target PR_NUMBER=2 MAX_ITERATIONS=3 RUN_URL=https://example.invalid/run \
    NEEDS="$1" bash --noprofile --norc -eo pipefail "$work/cycle.sh" > /dev/null
  sed -n 's/^result=//p' "$out/output"
}
skipped='{"result": "skipped", "outputs": {}}'
needs() { # review_1, iterate_1, review_2 job JSONs
  jq -n --argjson s "$skipped" --argjson r1 "$1" --argjson i1 "$2" --argjson r2 "$3" \
    '{check: {result: "success", outputs: {}}, review_1: $r1, iterate_1: $i1, review_2: $r2,
      iterate_2: $s, review_3: $s, iterate_3: $s, review_4: $s}'
}
review() { jq -n --arg v "$1" '{result: "success", outputs: {verdict: $v, review_json: ""}}'; }
iterate() { jq -n --arg r "$1" '{result: "success", outputs: {result: $r, commit_sha: "", iteration_json: ""}}'; }

expect "E  PARTIAL -> Reviewer APPROVE -> APPROVED" \
  "$(cycle "$(needs "$(review REQUEST_CHANGES)" "$(iterate PARTIAL)" "$(review APPROVE)")")" APPROVED
expect "E  PARTIAL is never an approval on its own" \
  "$(cycle "$(needs "$(review REQUEST_CHANGES)" "$(iterate PARTIAL)" "$skipped")")" FAILED
expect "E  Iterator BLOCKED stops the cycle" \
  "$(cycle "$(needs "$(review REQUEST_CHANGES)" "$(iterate BLOCKED)" "$skipped")")" BLOCKED

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed."
  exit 1
fi
echo "All checks passed."
