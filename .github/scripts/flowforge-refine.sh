# shellcheck shell=bash
# FlowForge — Refiner result: preconditions, validation and deterministic rendering. Sourced by
# agent-refine.yml, never run on its own; fetched at job.workflow_sha like flowforge-state.sh.
#
# The agent returns structured output only (refinement fields, verdict). Everything that must
# not depend on the model is built here: the "Original request" block (quoted from the real
# Issue on the first refinement, carried over unchanged afterwards) and the "Refinement record"
# (earlier entries kept, one entry appended per run). See docs/issue-contract.md and
# docs/architecture.md §2.9.
#
# Requires jq, awk, sha256sum.

FLOWFORGE_REFINER_MARKER='<!-- flowforge-refiner: schema_version=1 -->'
FLOWFORGE_REFINER_COMMENT_MARKER='<!-- flowforge-refiner -->'
FLOWFORGE_ORIGINAL_START='<!-- flowforge-original-request:start -->'
FLOWFORGE_ORIGINAL_END='<!-- flowforge-original-request:end -->'
FLOWFORGE_RECORD_START='<!-- flowforge-refinement-record:start -->'
FLOWFORGE_RECORD_END='<!-- flowforge-refinement-record:end -->'
# GitHub rejects an Issue body above 65536 characters.
FLOWFORGE_REFINER_MAX_BODY=65536

# Succeeds if the Issue $1 (JSON of the REST issues API) may be refined: an open Issue, not a
# pull request, with no FlowForge state label other than agent:needs-clarification. An Issue
# already handed to the Developer (ready, running, review, blocked, done) is never re-specified.
flowforge_refine_preconditions() {
  local issue_file="$1" n state busy
  n="$(jq -r '.number' "$issue_file")"
  if jq -e '.pull_request != null' "$issue_file" >/dev/null; then
    echo "::error::#$n is a pull request, not an Issue."
    return 1
  fi
  state="$(jq -r '.state' "$issue_file")"
  if [[ "$state" != "open" ]]; then
    echo "::error::Issue #$n is $state, expected open."
    return 1
  fi
  busy="$(jq -r '[.labels[].name | select(IN("agent:ready", "agent:running", "agent:review", "agent:blocked", "agent:done"))] | join(", ")' "$issue_file")"
  if [[ -n "$busy" ]]; then
    echo "::error::Issue #$n is already in FlowForge state '$busy': the Refiner only runs on an Issue with no state or agent:needs-clarification."
    return 1
  fi
}

# Prints the digest of the Issue $1's title and body, to detect a human edit made while the
# Refiner was running.
flowforge_refine_digest() {
  jq -j '.title, "\n", (.body // "")' "$1" | sha256sum | cut -d' ' -f1
}

# Validates the agent output file $1 against the result contract and the verdict rules.
# Succeeds silently; otherwise prints the reason and fails.
flowforge_refine_validate() {
  if ! jq -e 'type == "object"' "$1" >/dev/null 2>&1; then
    echo "The Refiner returned no parsable structured output."
    return 1
  fi
  # shellcheck disable=SC2016  # jq program
  if ! jq -e '
    def str: type == "string";
    def strs: type == "array" and all(.[]; type == "string");
    def filled: test("\\S");
    def blocking: [.open_questions[] | select(.blocking)] | length;
    def well_formed:
      (.verdict | IN("READY", "NEEDS_CLARIFICATION", "BLOCKED"))
      and ([.blocked_reason, .title, .goal, .added] | all(str))
      and ([.context, .scope, .out_of_scope, .acceptance_criteria, .constraints, .references,
            .assumptions, .notes_for_agents, .proposed_labels, .references_used] | all(strs))
      and (.open_questions | type == "array"
           and all(.[]; type == "object" and (.question | str)
                        and (.blocking | type == "boolean") and (.default | str)));
    def consistent:
      if .verdict == "BLOCKED" then .blocked_reason | filled
      else (.title | filled) and (.title | length) <= 256 and .blocked_reason == ""
        and all(.open_questions[]; .question | filled)
        and all(.open_questions[] | select(.blocking | not); .default | filled)
        and all(.acceptance_criteria[]; test("\\[(provided|recommended|observed)\\]"))
        and if .verdict == "READY" then
              blocking == 0 and (.goal | filled)
              and ([.context, .scope, .out_of_scope, .acceptance_criteria, .constraints, .references]
                   | all(length > 0))
            else blocking > 0 end
      end;
    well_formed and consistent' "$1" >/dev/null 2>&1; then
    echo "The Refiner output violates the result contract or the verdict rules (docs/issue-contract.md §5, agents/refiner.md §5.3)."
    return 1
  fi
}

# Prints the lines strictly between the marker lines $2 and $3 of the file $1. Fails unless
# each marker appears exactly once, start before end.
_flowforge_refine_block() {
  awk -v s="$2" -v e="$3" '
    { sub(/\r$/, "") }
    $0 == s { ns++; if (ns == 1 && ne == 0) { inside = 1 }; next }
    $0 == e { ne++; if (inside) { inside = 0; done = 1 }; next }
    inside { print }
    END { exit !(ns == 1 && ne == 1 && done) }' "$1"
}

# Succeeds if the body of the Issue $1 was written by the Refiner (first line is the marker).
flowforge_refine_is_refined() {
  [[ "$(jq -r '.body // ""' "$1" | head -n 1 | tr -d '\r')" == "$FLOWFORGE_REFINER_MARKER" ]]
}

# Prints the content of the "Original request" block for the Issue $1: carried over unchanged
# from a refined body, or the current title and body quoted verbatim on the first refinement.
# A refined body whose markers are missing or duplicated is an error: never guess, never
# overwrite the requester's text.
flowforge_refine_original() {
  local issue_file="$1" body_file
  body_file="$(mktemp)"
  jq -r '.body // ""' "$issue_file" > "$body_file"
  if flowforge_refine_is_refined "$issue_file"; then
    if ! _flowforge_refine_block "$body_file" "$FLOWFORGE_ORIGINAL_START" "$FLOWFORGE_ORIGINAL_END" \
      || ! _flowforge_refine_block "$body_file" "$FLOWFORGE_ORIGINAL_START" "$FLOWFORGE_ORIGINAL_END" \
        | grep -q '[^[:space:]]'; then
      echo "::error::The refined body of Issue #$(jq -r '.number' "$issue_file") has no single, non-empty Original request block; restore it from the Issue edit history before re-running." >&2
      rm -f -- "$body_file"
      return 1
    fi
  else
    printf '> **Title:** %s\n>\n' "$(jq -r '.title' "$issue_file")"
    if grep -q '[^[:space:]]' "$body_file"; then
      tr -d '\r' < "$body_file" | sed 's/^/> /; s/^> $/>/'
    else
      echo '> _(empty body)_'
    fi
  fi
  rm -f -- "$body_file"
}

# Prints the earlier entries of the "Refinement record" of the Issue $1; nothing on the first
# refinement. Fails on a refined body with missing or duplicated record markers.
flowforge_refine_records() {
  local issue_file="$1" body_file rc=0
  flowforge_refine_is_refined "$issue_file" || return 0
  body_file="$(mktemp)"
  jq -r '.body // ""' "$issue_file" > "$body_file"
  if ! _flowforge_refine_block "$body_file" "$FLOWFORGE_RECORD_START" "$FLOWFORGE_RECORD_END"; then
    echo "::error::The refined body of Issue #$(jq -r '.number' "$issue_file") has no single Refinement record block; restore it from the Issue edit history before re-running." >&2
    rc=1
  fi
  rm -f -- "$body_file"
  return "$rc"
}

# Prints the refined Issue body (docs/issue-contract.md §2) from the refinement file $1 (agent
# output plus run metadata, see agent-refine.yml) and the Issue $2 as read before the run.
# Agent strings are flattened to one line and cannot open an HTML comment, so they can never
# forge a marker line.
flowforge_refine_render_body() {
  local refinement="$1" issue_file="$2" original records
  original="$(flowforge_refine_original "$issue_file")" || return 1
  records="$(flowforge_refine_records "$issue_file")" || return 1
  # shellcheck disable=SC2016  # jq program
  jq -r --arg original "$original" --arg records "$records" \
    --arg marker "$FLOWFORGE_REFINER_MARKER" \
    --arg os "$FLOWFORGE_ORIGINAL_START" --arg oe "$FLOWFORGE_ORIGINAL_END" \
    --arg rs "$FLOWFORGE_RECORD_START" --arg re "$FLOWFORGE_RECORD_END" '
    def clean: gsub("[\r\n]+"; " ") | gsub("<!--"; "&lt;!--");
    def items($none): if length == 0 then "- \($none)" else .[] | "- \(clean)" end;
    def section($t): "", "## \($t)";
    ([$records | scan("(?m)^### Refinement [0-9]+$")] | length + 1) as $n
    | ([.open_questions[] | select(.blocking)] | length) as $blocking
    | $marker,
      section("Context"), (.context | items("None stated.")),
      section("Goal"), (if (.goal | test("\\S")) then .goal | clean else "Not determinable yet — see *Open questions*." end),
      section("Scope"), (.scope | items("To be defined from the answers.")),
      section("Out of scope"), (.out_of_scope | items("Nothing specific.")),
      section("Acceptance criteria"),
      (if (.acceptance_criteria | length) == 0
        then "None yet: no criterion can be written without inventing the requirement."
        else .acceptance_criteria[] | "- [ ] \(clean)" end),
      section("Constraints"), (.constraints | items("None known.")),
      section("References"), (.references | items("None provided.")),
      (if (.open_questions | length) > 0 then section("Open questions"),
        (.open_questions[] | if .blocking then "- (blocking) \(.question | clean)"
          else "- (non-blocking) \(.question | clean) Default: \(.default | clean)" end)
        else empty end),
      (if (.assumptions | length) > 0 then section("Assumptions"), (.assumptions | items("")) else empty end),
      (if (.notes_for_agents | length) > 0 then section("Notes for agents"), (.notes_for_agents | items("")) else empty end),
      section("Proposed labels"),
      (if (.proposed_labels | length) == 0 then "None." else .proposed_labels | map(clean) | join(", ") end),
      section("Original request"), $os, $original, $oe,
      section("Refinement record"), $rs,
      (if $records != "" then $records, "" else empty end),
      "### Refinement \($n)",
      "- Source: Issue #\(.issue) by @\(.author | clean)",
      "- Refined at: \(.refined_at)",
      "- Refined by: FlowForge Refiner, `agents/refiner.md` at `\(.rules_sha)` ([workflow run](\(.run_url)))",
      "- Verdict: \(.verdict)",
      "- Added: \(if (.added | test("\\S")) then .added | clean else "not stated" end)",
      "- Assumptions: \(.assumptions | length)",
      "- References used: \(if (.references_used | length) == 0 then "none" else .references_used | map(clean) | join(", ") end)",
      "- Open questions: \($blocking) blocking, \((.open_questions | length) - $blocking) non-blocking",
      $re' "$refinement"
}

# Prints the single FlowForge Refiner comment for the refinement file $1. Re-runs update it in
# place (marker + github-actions[bot] author) instead of adding comments.
flowforge_refine_render_comment() {
  # shellcheck disable=SC2016  # jq program
  jq -r --arg marker "$FLOWFORGE_REFINER_COMMENT_MARKER" '
    def clean: gsub("[\r\n]+"; " ") | gsub("<!--"; "&lt;!--");
    $marker,
    "## FlowForge Refinement",
    "",
    "Verdict: **\(.verdict)**",
    "",
    (if .verdict == "READY" then
       "The Issue title and body were rewritten to the refined format; the original request is kept verbatim in *Original request*.",
       "",
       "Review it, then a human may apply `agent:ready` to start the Developer. Applying it accepts the `[recommended]` items as requirements."
     elif .verdict == "NEEDS_CLARIFICATION" then
       "The Issue title and body were rewritten to the refined format; the original request is kept verbatim in *Original request*. `agent:ready` must not be applied yet.",
       "",
       "**Blocking questions** — answer them in a comment (or edit the Issue), then re-run the Refiner:",
       "",
       (.open_questions[] | select(.blocking) | "- \(.question | clean)")
     else
       "**Blocked:** \(.blocked_reason | clean)",
       "",
       "The Issue title, body and labels were not changed. A human decision is needed."
     end),
    "",
    "<sub>FlowForge Refiner · Issue #\(.issue) · \(.refined_at) · rules `agents/refiner.md` at `\(.rules_sha)` · [workflow run](\(.run_url))</sub>"
  ' "$1"
}
