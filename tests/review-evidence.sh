#!/usr/bin/env bash
# Tests of the Reviewer evidence rules (Prompt 38.1, A2), run against the REAL steps of
# agent-review.yml and the REAL SPEC.md checker it hands to the Reviewer:
#   review/"Validate and render review result"  PASS needs evidence; verdict vs statuses
#   review/"Build Reviewer prompt"              fetches the checker, gives the exact command
#   review/"Run Claude Code Reviewer"           allows that exact command, nothing wider
#   .github/scripts/flowforge-spec.sh           the command's result -> PASS / FAIL / NOT_VERIFIED
# No network, no token, no Claude: the structured output is a fixture.
#
# Requires: bash, jq, yq (mikefarah v4). Usage: tests/review-evidence.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
review_yml="$root/.github/workflows/agent-review.yml"
helper="$root/.github/scripts/flowforge-spec.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

step() { yq -e ".jobs.review.steps[] | select(.name == \"$1\") | .$2" "$review_yml"; }
step "Validate and render review result" run > "$work/result.sh"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }
expect() { # name, actual, expected
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

# validate <name> <structured output>: runs the real step, prints "<verdict> <produced_by>".
validate() {
  local dir="$work/$1"
  mkdir -p "$dir"
  : > "$dir/github_output"; : > "$dir/summary"
  env CONTEXT_DIR="$dir" GITHUB_OUTPUT="$dir/github_output" GITHUB_STEP_SUMMARY="$dir/summary" \
    CLAUDE_OUTCOME=success STRUCTURED_OUTPUT="$2" GITHUB_REPOSITORY=owner/target PR_NUMBER=60 \
    BASE_BRANCH=main HEAD_BRANCH=agent/58-x HEAD_SHA=abc ISSUE_NUMBER=58 RUN_URL=https://run \
    bash --noprofile --norc -eo pipefail "$work/result.sh" > "$dir/log" 2>&1
  jq -r '"\(.verdict) \(.produced_by)"' "$dir/result/review.json"
}
review() { # verdict, criterion status, evidence, [finding severity]
  jq -cn --arg v "$1" --arg s "$2" --arg e "$3" --arg f "${4:-}" '{
    verdict: $v, summary: "s", blocked_reason: (if $v == "BLOCKED" then "missing" else "" end),
    acceptance_criteria: [{criterion: "SPEC.md passes the contract check", status: $s, evidence: $e}],
    findings: (if $f == "" then [] else [{severity: $f, title: "t", file: "SPEC.md",
      line_or_range: "N/A", description: "d", reason: "r", expected_fix: "x"}] end)}'
}

# --- Statuses and verdicts --------------------------------------------------------------------
expect "check executed, PASS with its result as evidence: APPROVE accepted" \
  "$(validate executed "$(review APPROVE PASS 'Ran the checker: SPEC contract: PASS')")" "APPROVE reviewer"
expect "PASS without evidence: refused, BLOCKED by the workflow" \
  "$(validate no-evidence "$(review APPROVE PASS '')")" "BLOCKED workflow"
expect "PASS with blank evidence: refused, BLOCKED by the workflow" \
  "$(validate blank-evidence "$(review APPROVE PASS $'  \n\t')")" "BLOCKED workflow"
expect "PASS without evidence refused under REQUEST_CHANGES too" \
  "$(validate no-evidence-rc "$(review REQUEST_CHANGES PASS '' MAJOR)")" "BLOCKED workflow"
expect "check not runnable: NOT_VERIFIED cannot APPROVE" \
  "$(validate nv-approve "$(review APPROVE NOT_VERIFIED 'Command refused by the permissions')")" "BLOCKED workflow"
expect "check not runnable: NOT_VERIFIED + MAJOR -> REQUEST_CHANGES accepted" \
  "$(validate nv-rc "$(review REQUEST_CHANGES NOT_VERIFIED 'Command refused by the permissions' MAJOR)")" "REQUEST_CHANGES reviewer"
expect "check not runnable: NOT_VERIFIED -> BLOCKED with a reason accepted" \
  "$(validate nv-blocked "$(review BLOCKED NOT_VERIFIED 'SPEC contract: ERROR')")" "BLOCKED reviewer"
expect "check failed: FAIL cannot APPROVE" \
  "$(validate fail-approve "$(review APPROVE FAIL 'SPEC contract: FAILED')")" "BLOCKED workflow"
expect "check failed: FAIL -> REQUEST_CHANGES accepted" \
  "$(validate fail-rc "$(review REQUEST_CHANGES FAIL 'SPEC contract: FAILED')")" "REQUEST_CHANGES reviewer"
expect "NOT_VERIFIED rendered unchecked in the comment" \
  "$(grep -c '^- \[ \] NOT_VERIFIED — SPEC.md passes the contract check (Command refused' "$work/nv-rc/result/review.md")" 1

# --- The SPEC.md checker the Reviewer is told to run -----------------------------------------
prompt="$(step "Build Reviewer prompt" run)"
claude_args="$(step "Run Claude Code Reviewer" with.claude_args)"
expect "checker fetched from FlowForge at the workflow commit, outside the workspace" \
  "$(grep -c 'contents/.github/scripts/flowforge-spec.sh?ref=$FLOWFORGE_SHA" \\$' <<<"$prompt")/$(grep -c '> "$CONTEXT_DIR/flowforge-spec.sh"' <<<"$prompt")" 1/1
expect "prompt gives the exact command and forbids PASS without running it" \
  "$(grep -c '^ *bash $CONTEXT_DIR/flowforge-spec.sh SPEC.md$' <<<"$prompt")/$(grep -c 'PASS from reading SPEC.md, nor from its presence' <<<"$prompt")" 1/1
# CONTEXT_DIR is "$RUNNER_TEMP/flowforge-review" (step "Resolve pull request context").
# claude_args is a folded scalar: one line. Exactly one mention of the checker, as a full rule.
expect "the allowed rule is that exact command (no prefix, no wildcard)" \
  "$(grep -o 'flowforge-spec[^)]*)' <<<"$claude_args" | paste -sd'|' -)/$(grep -cF ', Bash(bash ${{ runner.temp }}/flowforge-review/flowforge-spec.sh SPEC.md) ' <<<"$claude_args")" \
  "flowforge-spec.sh SPEC.md)/1"
expect "CONTEXT_DIR is the directory of the allowed rule" \
  "$(step "Resolve pull request context" run | grep -c '^CONTEXT_DIR="$RUNNER_TEMP/flowforge-review"$')" 1
expect "rules tell the Reviewer the same command and statuses" \
  "$(grep -c 'bash <runner temp>/flowforge-review/flowforge-spec.sh SPEC.md' "$root/agents/reviewer.md")/$(grep -c 'never conclude `PASS`' "$root/agents/reviewer.md")" 2/1

# The command's results, as the Reviewer sees them (workspace = PR head).
mkdir -p "$work/ws"
printf '## 1. Objectif et périmètre\n\nx\n\n## 2. Fonctionnalités\n\n### F-001 — a\n\nb\n\n## 3. Règles et contraintes\n\nc\n\n## 4. Scénarios de validation\n\nGIVEN a\nWHEN b\nTHEN c\n' > "$work/ws/SPEC.md"
check() { local out rc=0; out="$(cd "$work/ws" && bash "$helper" SPEC.md 2>&1)" || rc=$?; printf '%s/%s' "$rc" "$(tail -n 1 <<<"$out")"; }
expect "valid SPEC.md: 'SPEC contract: PASS', exit 0 (-> PASS)" "$(check)" "0/SPEC contract: PASS"
sed -i '/^## 4\./,$d' "$work/ws/SPEC.md"
expect "incomplete SPEC.md: 'SPEC contract: FAILED', exit 1 (-> FAIL)" "$(check)" "1/SPEC contract: FAILED"
rm "$work/ws/SPEC.md"; mkdir "$work/ws/SPEC.md"
expect "unreadable SPEC.md: 'SPEC contract: ERROR', exit 2 (-> NOT_VERIFIED)" "$(check)" "2/SPEC contract: ERROR"
expect "the Reviewer runs the gate's checker, no copy of its rules in the workflow" \
  "$(grep -cE 'objectif et|FLOWFORGE_SPEC_SECTIONS|flowforge_spec_check' "$review_yml" || true)" 0

echo
if (( failures > 0 )); then
  echo "$failures Reviewer evidence test(s) failed."
  exit 1
fi
echo "All Reviewer evidence tests passed."
