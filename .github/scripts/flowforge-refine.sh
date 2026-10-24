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
# Phase 9 (docs/autonomy-contract.md): opt-out label (a control label, not a state label) and the
# marker every Notion-submitted Issue carries (flowforge-notion.sh).
FLOWFORGE_MANUAL_LABEL=agent:manual
FLOWFORGE_NOTION_MARKER='flowforge:notion-page-id='
# Keyword floor (autonomy contract §3.1): word prefixes, case-insensitive, matched at a word start
# (a term starting with a non-word character, a path fragment, matches anywhere). One hit => HIGH.
FLOWFORGE_RISK_KEYWORDS=(
  authent authoriz autoris login password "mot de passe" token jeton secret credential
  permission role oauth jwt session security sécurité crypt tls ssl cve vulnerab
  terraform .tf infra .github/ workflow pipeline ci/cd deploy docker migration migrat
  delete suppression drop truncate purge schema database "base de données"
)
# Prohibition clauses (autonomy contract §3.1): in the original request, the constraints and the
# notes, a clause (cut at . ; , : ! ? before a space, and at line ends) that opens with a ban on a
# change ("Do not modify …", "No change to …", "Ne pas modifier …") and holds no connective that
# could carry a second operation ("but", "and", "unless", …) is not scanned. Anything else is.
FLOWFORGE_RISK_BAN='^[[:space:]>*_`-]*([0-9]+[.)][[:space:]]+)?((do not|don.t|never|must not|should not|ne pas|ne jamais)[[:space:]]+(modify|change|edit|touch|alter|update|rewrite|remove|delete|modifier|changer|toucher|supprimer)|ne[[:space:]]+(modifiez|modifie|touchez|changez|supprimez)[[:space:]]+pas|(no|without|aucune?|sans|pas de)[[:space:]]+(changes?|modifications?|edits?|changements?)|sans[[:space:]]+(modifier|toucher))\b'
FLOWFORGE_RISK_BAN_BREAK='\b(but|unless|except|instead|however|then|and|also|plus|mais|sauf|sinon|puis|et|aussi|ensuite|plutôt)\b'

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

# Validates the agent output file $1 against the result contract and the verdict rules. $2 is
# "true" when the target holds SPEC.md on its default branch, "false" otherwise (Phase 8.2:
# docs/issue-contract.md §5 R9, agents/refiner.md §5.4). Succeeds silently; otherwise prints the
# reason and fails.
flowforge_refine_validate() {
  local spec_present="${2:-}"
  if [[ "$spec_present" != true && "$spec_present" != false ]]; then
    echo "flowforge_refine_validate: SPEC.md presence must be true or false, got '$spec_present'."
    return 1
  fi
  if ! jq -e 'type == "object"' "$1" >/dev/null 2>&1; then
    echo "The Refiner returned no parsable structured output."
    return 1
  fi
  # shellcheck disable=SC2016  # jq program
  if ! jq -e --argjson spec "$spec_present" '
    def str: type == "string";
    def strs: type == "array" and all(.[]; type == "string");
    def filled: test("\\S");
    def blocking: [.open_questions[] | select(.blocking)] | length;
    def well_formed:
      (.verdict | IN("READY", "NEEDS_CLARIFICATION", "BLOCKED"))
      and (.spec_impact | IN("COMPLIANT", "EXTENDS", "NEW_FEATURE", "MODIFIES", "CONTRADICTS",
                             "NEEDS_DECISION", "NO_SPEC"))
      and ([.blocked_reason, .title, .goal, .added] | all(str))
      and ([.context, .scope, .out_of_scope, .acceptance_criteria, .constraints, .references,
            .assumptions, .notes_for_agents, .proposed_labels, .references_used,
            .spec_references, .spec_changes, .definition_of_done] | all(strs))
      and (.open_questions | type == "array"
           and all(.[]; type == "object" and (.question | str)
                        and (.blocking | type == "boolean") and (.default | str)));
    def contract_change: .spec_impact | IN("EXTENDS", "NEW_FEATURE", "MODIFIES");
    def spec_consistent:
      if $spec then .spec_impact != "NO_SPEC"
      else .spec_impact == "NO_SPEC" and (.spec_references | length) == 0 end
      and (if .spec_impact | IN("CONTRADICTS", "NEEDS_DECISION") then .verdict != "READY" else true end)
      and (if .verdict == "READY" then
             ((.spec_changes | length) > 0) == contract_change
             and (.spec_impact == "NO_SPEC" or (.spec_references | length) > 0)
             and (.definition_of_done | length) > 0
           else true end);
    def consistent:
      if .verdict == "BLOCKED" then .blocked_reason | filled
      else (.title | filled) and (.title | length) <= 256 and .blocked_reason == ""
        and spec_consistent
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
    echo "The Refiner output violates the result contract or the verdict rules (docs/issue-contract.md §5, agents/refiner.md §5.3, §5.4)."
    return 1
  fi
}

# Prints the autonomy mode for the raw input $1: SEMI_AUTO only on an exact match, SUPERVISED
# otherwise (absent, empty, any other value); an unexpected value is reported on stderr.
flowforge_autonomy_mode() {
  case "${1:-}" in
    SEMI_AUTO) echo SEMI_AUTO ;;
    "" | SUPERVISED) echo SUPERVISED ;;
    *) echo "::warning::Unknown autonomy mode '$(tr -cd 'A-Za-z0-9_-' <<<"$1" | cut -c1-32)': SUPERVISED applies." >&2
       echo SUPERVISED ;;
  esac
}

# Prints, as a compact JSON array, the SPEC.md item identifiers (F-/R-/S-) found in the Markdown
# headings of the file $1 (gate G5: a cited item must exist as a heading).
flowforge_refine_spec_ids() {
  { grep -E '^ {0,3}#{2,6}[[:space:]]' "$1" || true; } \
    | { grep -oE '\b[FRS]-[0-9]+\b' || true; } | sort -u | jq -Rnc '[inputs]'
}

# Autonomy decision (docs/autonomy-contract.md §3, §4): deterministic, no LLM, no GitHub call.
#   $1 refinement.json, already validated by flowforge_refine_validate
#   $2 the Issue as read before the agent ran (REST JSON)
#   $3 every comment author except FlowForge's own Refiner comment: [{login, type}]
#   $4 workflow context: {mode, owner, actor, spec_check, spec_ids, repo_labels}
# Prints the `autonomy` object (gates G1-G12, risk, decision). Every gate is evaluated, so the
# trace lists all failed gates. Fails on any evaluation error: the caller then falls back to
# flowforge_autonomy_error (G12), never to AUTO_START.
flowforge_autonomy_decide() {
  local refinement="$1" issue="$2" commenters="$3" context="$4" original keywords
  original="$(flowforge_refine_original "$issue" 2>/dev/null)" || return 1
  keywords="$(printf '%s\n' "${FLOWFORGE_RISK_KEYWORDS[@]}" | jq -Rnc '[inputs]')" || return 1
  # shellcheck disable=SC2016  # jq program
  jq -ce --slurpfile issue "$issue" --slurpfile commenters "$commenters" --slurpfile ctx "$context" \
    --arg original "$original" --argjson keywords "$keywords" \
    --arg ban "$FLOWFORGE_RISK_BAN" --arg ban_break "$FLOWFORGE_RISK_BAN_BREAK" \
    --arg manual "$FLOWFORGE_MANUAL_LABEL" --arg notion "$FLOWFORGE_NOTION_MARKER" '
    def rank: {LOW: 0, MEDIUM: 1, HIGH: 2}[.];
    def level: ["LOW", "MEDIUM", "HIGH"][.];
    def esc: gsub("(?<c>[.*+?^$|(){}\\[\\]\\\\])"; "\\\(.c)");
    def login: ascii_downcase | gsub("[^a-z0-9\\[\\]-]"; "");
    def clauses: [splits("[.;,:!?](?=\\s|$)|\\n")];
    def ban: test($ban; "i") and (test($ban_break; "i") | not);
    def gate($id; $pass; $code; $detail):
      {($id): {result: (if $pass then "PASS" else "BLOCKED" end), code: $code, detail: $detail}};
    $issue[0] as $issue | $commenters[0] as $commenters | $ctx[0] as $ctx
    | if ([$ctx.repo_labels, $ctx.spec_ids, $commenters, $issue.labels] | all(type == "array")) | not
      then error("incomplete autonomy context") else . end
    | (([.context, .scope, .out_of_scope, .acceptance_criteria, .constraints, .references,
         .notes_for_agents, .spec_references, .spec_changes, .definition_of_done] | flatten) + [.goal])
      as $agent_text

    # Risk (§3.1): the proposal can raise the floor, never lower it; unknown => HIGH.
    | (.risk_level | if type == "string" and rank != null then . else null end) as $proposed
    | ({COMPLIANT: "LOW", EXTENDS: "MEDIUM", NEW_FEATURE: "MEDIUM"}[.spec_impact] // "HIGH") as $impact_floor
    | ((.title | capture("^(?<t>[a-z]+)(\\([^()]*\\))?(?<b>!?): ")) // {t: "", b: ""}) as $type
    | (if $type.t | IN("ci", "build") then "HIGH"
       elif ($type.t | IN("test", "docs", "refactor")) and $type.b == "" then "LOW"
       else "MEDIUM" end) as $type_floor
    # A clause that only forbids a change is not an operation: dropped from the original
    # request, the constraints and the notes. Positive fields are always scanned whole.
    | ([.title, .goal, .scope[], .acceptance_criteria[], .references[], .spec_changes[],
        ([.constraints[], .notes_for_agents[], $original][] | clauses[] | select(ban | not))]
       | join("\n")) as $text
    | [$keywords[] as $k
       | select($text | test((if $k | test("^\\w") then "\\b" else "" end) + ($k | esc); "i")) | $k] as $hits
    | ([$impact_floor, $type_floor, (if $hits == [] then "LOW" else "HIGH" end)] | map(rank) | max) as $floor
    | (if $proposed == null then 2 else [($proposed | rank), $floor] | max end | level) as $effective
    | ([if $impact_floor != "LOW" then .spec_impact else empty end,
        if $type_floor != "LOW" then "type \(if $type.t == "" then "none" else $type.t + $type.b end)" else empty end]
       + $hits) as $risk_words

    # Explicitness (#58), SPEC.md items, origin.
    | ([$agent_text[] | scan("\\b[FRS]-[0-9]+\\b")] | unique) as $cited
    | ([.spec_references[] | scan("\\b[FRS]-[0-9]+\\b")] | unique) as $refs
    | ($cited - $ctx.spec_ids) as $unknown
    | ([$agent_text[] | select(test("\\[(recommended|assumption)\\]"))] | length) as $tagged
    | ($ctx.owner // "" | login) as $owner
    | [$commenters[] | select((.login // "" | login) != $owner or .type != "User") | .login // "" | login] as $others
    | ($owner != "" and $issue.user.type == "User" and ($issue.user.login // "" | login) == $owner
       and ($ctx.actor // "" | login) == $owner and $others == []) as $owner_ok
    | ((($issue.body // "") + "\n" + $original) | contains($notion)) as $from_notion
    | ([$issue.labels[].name] | index($manual) != null) as $has_manual
    | ($ctx.repo_labels | index($manual) != null) as $manual_exists

    | (gate("G1"; .verdict == "READY"; "D-VERDICT"; "verdict \(.verdict)")
      + gate("G2"; $ctx.mode == "SEMI_AUTO"; "D-MODE"; "mode \($ctx.mode)")
      + gate("G3"; .spec_present == true and $ctx.spec_check == "PASS"; "D-SPEC";
             if .spec_present == true then "SPEC.md contract check \($ctx.spec_check)" else "no SPEC.md" end)
      + gate("G4"; .spec_impact == "COMPLIANT" and .spec_changes == []; "D-IMPACT";
             "impact \(.spec_impact), \(.spec_changes | length) contract change(s)")
      + gate("G5"; $refs != [] and $unknown == []; "D-REFS";
             if $refs == [] then "no SPEC.md item cited"
             elif $unknown != [] then "not in SPEC.md: \($unknown | join(", "))"
             else "cited: \($cited | join(", "))" end)
      + gate("G6"; (.acceptance_criteria | length) > 0 and (.definition_of_done | length) > 0; "D-INCOMPLETE";
             "\(.acceptance_criteria | length) criteria, \(.definition_of_done | length) Definition of Done item(s)")
      + gate("G7"; .open_questions == [] and .assumptions == [] and $tagged == 0; "D-IMPLICIT";
             "\(.open_questions | length) open question(s), \(.assumptions | length) assumption(s), \($tagged) [recommended] / [assumption] item(s)")
      + gate("G8"; $proposed != null and $effective == "LOW";
             (if $proposed == null then "D-RISK-UNKNOWN" elif $effective == "LOW" then "D-RISK" else "D-RISK-\($effective)" end);
             "effective \($effective) (proposed \($proposed // "none"), floor \($floor | level))\(if $risk_words != [] then ": " + ($risk_words | join(", ")) else "" end)")
      + gate("G9"; $owner_ok; "D-OWNER";
             if $owner == "" then "no autonomy owner declared"
             else "owner @\($owner); author @\($issue.user.login // "" | login) (\($issue.user.type // "unknown")), dispatched by @\($ctx.actor // "" | login), other commenters: \(if $others == [] then "none" else $others | unique | map("@" + .) | join(", ") end)" end)
      + gate("G10"; $from_notion | not; "D-NOTION"; if $from_notion then "Notion page marker found" else "no Notion marker" end)
      + gate("G11"; ($has_manual | not) and $manual_exists; (if $has_manual or $manual_exists then "D-MANUAL" else "D-MANUAL-MISSING" end);
             if $has_manual then "the Issue carries \($manual)" elif $manual_exists then "\($manual) absent" else "label \($manual) missing on the repository" end)
      + gate("G12"; true; "D-ERROR"; "evaluated without error")) as $gates
    | [$gates | to_entries[] | select(.value.result == "BLOCKED")] as $blocked
    | {mode: $ctx.mode, owner: ($ctx.owner // ""), proposed_risk: $proposed, risk_floor: ($floor | level),
       risk_floor_reasons: $risk_words, effective_risk: $effective, spec_check: $ctx.spec_check,
       gates: $gates,
       reasons: [$blocked[] | .value.code + (if .key == "G8" and $risk_words != [] then ": " + ($risk_words | join(", ")) else "" end)],
       would_auto_start: ([$blocked[] | select(.key != "G2")] == []),
       decision: (if $gates.G1.result == "BLOCKED" or $gates.G6.result == "BLOCKED" then "NO_START"
                  elif $blocked == [] then "AUTO_START" else "HUMAN_REQUIRED" end)}
  ' "$refinement"
}

# Prints the fail-closed `autonomy` object used when flowforge_autonomy_decide failed (G12):
# verdict $1, mode $2. Never AUTO_START: the v0.1.0 human path applies.
flowforge_autonomy_error() {
  # shellcheck disable=SC2016  # jq program
  jq -nc --arg verdict "$1" --arg mode "$2" '
    {mode: $mode, owner: "", proposed_risk: null, risk_floor: "HIGH", risk_floor_reasons: [],
     effective_risk: "HIGH", spec_check: "", gates: {G12: {result: "BLOCKED", code: "D-ERROR",
     detail: "the autonomy check could not be evaluated"}}, reasons: ["D-ERROR"],
     would_auto_start: false, decision: (if $verdict == "READY" then "HUMAN_REQUIRED" else "NO_START" end)}'
}

# Downgrades, in place, the decision of the refinement file $1 to HUMAN_REQUIRED (D-MANUAL): the
# publish job found agent:manual right before applying agent:ready (G11 re-check). Never upgrades.
flowforge_autonomy_downgrade() {
  local tmp
  tmp="$(mktemp)"
  # shellcheck disable=SC2016  # jq program
  jq --arg manual "$FLOWFORGE_MANUAL_LABEL" '
    .autonomy |= (.gates.G11 = {result: "BLOCKED", code: "D-MANUAL", detail: "\($manual) added while the Refiner ran"}
      | .reasons = (if (.reasons | index("D-MANUAL")) then .reasons else .reasons + ["D-MANUAL"] end)
      | .would_auto_start = false
      | .decision = (if .decision == "AUTO_START" then "HUMAN_REQUIRED" else .decision end))' "$1" > "$tmp" \
    && mv -- "$tmp" "$1"
}

# Prints the run summary block of the autonomy decision held by the refinement file $1.
flowforge_autonomy_summary() {
  # shellcheck disable=SC2016  # jq program
  jq -r '
    .autonomy as $a
    | def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
    "### FlowForge autonomy",
    "- Autonomy mode: `\($a.mode)`",
    "- Risk: **\($a.effective_risk)** (proposed \($a.proposed_risk // "none"), floor \($a.risk_floor))",
    "- Decision: **\($a.decision)**",
    (if $a.mode != "SEMI_AUTO" then "- Would start automatically in `SEMI_AUTO`: \(if $a.would_auto_start then "yes" else "no" end)" else empty end),
    "- Reasons: \(if $a.reasons == [] then "G1–G12 passed" else $a.reasons | map(cell) | join(", ") end)",
    "",
    "| Gate | Result | Code | Detail |",
    "|---|---|---|---|",
    ($a.gates | to_entries[] | "| \(.key) | \(.value.result) | `\(.value.code)` | \(.value.detail | cell) |")
  ' "$1"
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

# Prints, as a JSON array, the items of the "Assumptions" section of the refined body of the
# Issue $1: the Refiner's own earlier output, handed back to the agent to re-evaluate one by one
# (agents/refiner.md §4.1). [] on a first refinement or without the section. Only the generated
# part is read: lines of the quoted Original request start with "> " and never match.
flowforge_refine_previous_assumptions() {
  flowforge_refine_is_refined "$1" || { echo '[]'; return 0; }
  jq -r '.body // ""' "$1" | tr -d '\r' \
    | awk -v stop="$FLOWFORGE_ORIGINAL_START" '
        $0 == stop { exit }
        /^## / { inside = ($0 == "## Assumptions"); next }
        inside && /^- / { print substr($0, 3) }' \
    | jq -Rnc '[inputs]'
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
    def impact:
      {COMPLIANT: "the request respects the existing contract",
       EXTENDS: "the request extends an existing feature; `SPEC.md` is updated in the same PR",
       NEW_FEATURE: "the request adds a feature `SPEC.md` does not cover; `SPEC.md` is updated in the same PR",
       MODIFIES: "the request changes an existing requirement, as explicitly decided; `SPEC.md` is updated in the same PR",
       CONTRADICTS: "the request contradicts a confirmed requirement: arbitration needed, see *Open questions*",
       NEEDS_DECISION: "the request needs an owner decision on the contract, see *Open questions*",
       NO_SPEC: "the repository has no `SPEC.md` on its default branch; the Developer will not start until one is added"}[.];
    def spec_ids: [.spec_references[] | scan("\\b[FRS]-[0-9]+\\b")] | unique;
    def autonomy_line:
      "- Autonomy: SEMI_AUTO · risk \(.effective_risk) (proposed \(.proposed_risk // "none"), floor \(.risk_floor)) · \(.decision)\(if .reasons == [] then "" else " (" + (.reasons | map(clean) | join(", ")) + ")" end)";
    ([$records | scan("(?m)^### Refinement [0-9]+$")] | length + 1) as $n
    | ([.open_questions[] | select(.blocking)] | length) as $blocking
    | $marker,
      section("Context"), (.context | items("None stated.")),
      section("Goal"), (if (.goal | test("\\S")) then .goal | clean else "Not determinable yet — see *Open questions*." end),
      section("Specification"),
      "Impact on `SPEC.md`: `\(.spec_impact)` — \(.spec_impact | impact).",
      (if (.spec_references | length) > 0 then "", (.spec_references | items("")) else empty end),
      (if (.spec_changes | length) > 0 then "", "Contract changes to make in `SPEC.md`, in the same PR:",
        (.spec_changes | items("")) else empty end),
      section("Scope"), (.scope | items("To be defined from the answers.")),
      section("Out of scope"), (.out_of_scope | items("Nothing specific.")),
      section("Acceptance criteria"),
      (if (.acceptance_criteria | length) == 0
        then "None yet: no criterion can be written without inventing the requirement."
        else .acceptance_criteria[] | "- [ ] \(clean)" end),
      section("Definition of Done"), (.definition_of_done | items("To be defined from the answers.")),
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
      "- SPEC.md: \(.spec_impact)\(if (spec_ids | length) > 0 then " (" + (spec_ids | join(", ")) + ")" else "" end)",
      "- Added: \(if (.added | test("\\S")) then .added | clean else "not stated" end)",
      "- Assumptions: \(.assumptions | length)",
      "- References used: \(if (.references_used | length) == 0 then "none" else .references_used | map(clean) | join(", ") end)",
      "- Open questions: \($blocking) blocking, \((.open_questions | length) - $blocking) non-blocking",
      (if (.autonomy.mode // "") == "SEMI_AUTO" then .autonomy | autonomy_line else empty end),
      $re' "$refinement"
}

# Prints the single FlowForge Refiner comment for the refinement file $1. Re-runs update it in
# place (marker + github-actions[bot] author) instead of adding comments.
flowforge_refine_render_comment() {
  # shellcheck disable=SC2016  # jq program
  jq -r --arg marker "$FLOWFORGE_REFINER_COMMENT_MARKER" --arg manual "$FLOWFORGE_MANUAL_LABEL" '
    def clean: gsub("[\r\n]+"; " ") | gsub("<!--"; "&lt;!--");
    def plain:
      (split(": ") | .[0]) as $code | (.[($code | length):] | ltrimstr(": ")) as $words
      | ({"D-VERDICT": "the refinement is not READY",
          "D-MODE": "the repository is not in SEMI_AUTO mode",
          "D-SPEC": "SPEC.md does not pass the contract check",
          "D-IMPACT": "the request is not COMPLIANT with SPEC.md, or changes it",
          "D-REFS": "SPEC.md items are not cited, or a cited item does not exist",
          "D-INCOMPLETE": "acceptance criteria or Definition of Done missing",
          "D-IMPLICIT": "open questions, assumptions or `[recommended]` items remain",
          "D-RISK-MEDIUM": "the effective risk is MEDIUM",
          "D-RISK-HIGH": "the effective risk is HIGH",
          "D-RISK-UNKNOWN": "the proposed risk is missing or unknown",
          "D-OWNER": "the Issue author, the dispatcher or a commenter is not the repository owner",
          "D-NOTION": "the Issue was submitted from Notion",
          "D-MANUAL": "the Issue carries `\($manual)`",
          "D-MANUAL-MISSING": "the `\($manual)` label does not exist on the repository",
          "D-ERROR": "the autonomy check could not be evaluated"}[$code] // "unknown reason")
        + " (`\($code)`\(if $words == "" then "" else ": " + ($words | clean) end))";
    $marker,
    "## FlowForge Refinement",
    "",
    "Verdict: **\(.verdict)** · `SPEC.md` impact: **\(.spec_impact)**",
    "",
    (if .verdict == "READY" then
       "The Issue title and body were rewritten to the refined format; the original request is kept verbatim in *Original request*.",
       "",
       (if (.autonomy.mode // "") == "SEMI_AUTO" and .autonomy.decision == "AUTO_START" then
          "This run starts the Developer automatically (`SEMI_AUTO`, risk `LOW`): every autonomy gate passed, so no human `agent:ready` is needed. The merge stays human."
        else
          "Review it, then a human may apply `agent:ready` to start the Developer. Applying it accepts the `[recommended]` items as requirements.",
          (if (.autonomy.mode // "") == "SEMI_AUTO" then
             "",
             "**No automatic start** (`SEMI_AUTO`, risk `\(.autonomy.effective_risk)`), human validation required:",
             "",
             (.autonomy.reasons[] | "- \(plain)")
           else empty end)
        end)
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
