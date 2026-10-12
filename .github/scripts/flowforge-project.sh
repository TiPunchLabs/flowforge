# shellcheck shell=bash
# FlowForge — GitHub Project status sync. Sourced by the reusable workflows, never run on its
# own (maintainers use scripts/github-projects/sync-issue.sh).
#
# One-way: a real FlowForge event writes the Issue's card (Status + Attention); nothing ever
# reads the Project to decide anything, and no card move starts an agent. Best-effort: a sync
# failure is a warning, never a failed agent run. See docs/github-projects/synchronization.md.
#
#   flowforge_project_sync <issue> <event>   add the Issue to the Project if needed, then apply
#                                            the event through the transition rules below
#   flowforge_project_decide <event> <status> <attention> [force]   pure decision, no API
#
# Environment: GITHUB_REPOSITORY; GH_TOKEN (reads the Issue in the calling repository);
# PROJECT_TOKEN (FlowForge App token, organization projects: write); PROJECT_NUMBER (opt-in,
# must match the IDs file); FLOWFORGE_PROJECT_CONFIG (path of config/github-project.json) or
# FLOWFORGE_REPOSITORY + FLOWFORGE_SHA to fetch it; optional FLOWFORGE_PROJECT_FORCE=1
# (maintainer bypass of the stale guard) and FLOWFORGE_PROJECT_STRICT=1 (fail instead of warn).

# Flow order. Review and Iteration share a rank: the loop goes both ways.
FLOWFORGE_PROJECT_RANKS='{"": 0, "Backlog": 1, "Refining": 2, "Ready": 3, "Developing": 4,
  "Review": 5, "Iteration": 5, "Human validation": 6, "Done": 7}'

# Event -> target Status (null: keep the card where it is), Attention ("" clears it) and the
# source statuses the model allows (kanban-model.md §7, §11; "" = new item, no Status yet).
FLOWFORGE_PROJECT_EVENTS='{
  "issue-added":                {"status": "Backlog", "attention": "", "from": [""], "reason": "Issue added"},
  "refine-started":             {"status": "Refining", "attention": "", "from": ["", "Backlog", "Ready", "Refining"], "reason": "Refiner started"},
  "refine-ready":               {"status": "Ready", "attention": "", "from": ["Refining"], "reason": "Refiner READY"},
  "refine-needs-clarification": {"status": "Backlog", "attention": "Needs clarification", "from": ["Refining"], "reason": "Refiner NEEDS_CLARIFICATION"},
  "refine-blocked":             {"status": "Backlog", "attention": "Blocked", "from": ["Refining"], "reason": "Refiner BLOCKED"},
  "refine-failed":              {"status": null, "attention": "Failed", "from": ["Refining"], "reason": "Refiner technical failure"},
  "develop-started":            {"status": "Developing", "attention": "", "from": ["", "Backlog", "Ready", "Developing"], "reason": "Developer started"},
  "develop-delivered":          {"status": "Review", "attention": "", "from": ["Developing"], "reason": "Draft PR delivered"},
  "develop-stopped":            {"status": "Backlog", "attention": "Blocked", "from": ["Developing"], "reason": "Developer stopped without Draft PR"},
  "develop-failed":             {"status": null, "attention": "Failed", "from": ["Developing"], "reason": "Developer technical failure"},
  "cycle-started":              {"status": "Review", "attention": "", "from": ["Review", "Iteration", "Human validation"], "reason": "Review cycle started"},
  "iterate-started":            {"status": "Iteration", "attention": "", "from": ["Review"], "reason": "Iterator started"},
  "iterate-completed":          {"status": "Review", "attention": "", "from": ["Iteration"], "reason": "Iterator COMPLETED / PARTIAL"},
  "cycle-approved":             {"status": "Human validation", "attention": "", "from": ["Review"], "reason": "Review cycle APPROVED"},
  "cycle-blocked":              {"status": "Human validation", "attention": "Blocked", "from": ["Review", "Iteration"], "reason": "Review cycle BLOCKED"},
  "cycle-max-iterations":       {"status": "Human validation", "attention": "Max iterations", "from": ["Review"], "reason": "Review cycle MAX_ITERATIONS_REACHED"},
  "cycle-failed":               {"status": null, "attention": "Failed", "from": ["Review", "Iteration"], "reason": "Review cycle technical failure"},
  "pr-merged":                  {"status": "Done", "attention": "", "from": ["Human validation"], "reason": "Pull request merged"},
  "pr-closed":                  {"status": "Backlog", "attention": "", "from": ["Review", "Iteration", "Human validation"], "reason": "Pull request closed without merge"}
}'

# Prints the decision for event $1 on a card in Status $2 with Attention $3 ($4 = 1: force),
# as compact JSON {action, status, attention, previous_status, previous_attention, reason, note}:
#   update     write status/attention (only the fields that differ)
#   unchanged  the card already shows the event: no write (idempotent replay)
#   refused    stale event: the card is further in the flow than the event's target
#   skipped    status-keeping event (technical failure) on a card that is elsewhere
# Rule: an allowed source is applied; an unexpected source is applied only when the target is
# ahead in the flow (a missed event is caught up), never when it is behind (stale event).
# Fails on an unknown event.
flowforge_project_decide() {
  local event="$1" current="$2" attention="$3" force="${4:-}"
  jq -nce --arg e "$event" --arg cur "$current" --arg att "$attention" --arg force "$force" \
    --argjson events "$FLOWFORGE_PROJECT_EVENTS" --argjson ranks "$FLOWFORGE_PROJECT_RANKS" '
    $events[$e] as $ev
    | if $ev == null then error("unknown event \($e)") else . end
    | {status: ($ev.status // $cur), attention: $ev.attention, previous_status: $cur,
       previous_attention: $att, reason: $ev.reason} as $base
    | ($ev.from | index($cur) != null) as $allowed
    | if ($ranks | has($cur) | not) then
        $base + {action: (if $force == "1" then "update" else "refused" end),
                 note: "current Status \($cur) is not a FlowForge status"}
      elif $ev.status == null then
        if $allowed or $force == "1" then
          $base + {action: (if $att == $ev.attention then "unchanged" else "update" end), note: ""}
        else
          $base + {action: "skipped", note: "card is in \(if $cur == "" then "no status" else $cur end), not in \($ev.from | join(" / ")): Attention left as is"}
        end
      elif $ev.status == $cur and $att == $ev.attention then
        $base + {action: "unchanged", note: ""}
      elif $allowed or $ev.status == $cur then
        $base + {action: "update", note: ""}
      elif $force == "1" then
        $base + {action: "update", note: "forced from \($cur)"}
      elif $ranks[$ev.status] > $ranks[$cur] then
        $base + {action: "update", note: "unexpected source \(if $cur == "" then "(no status)" else $cur end), applied: execution wins over a missed event"}
      else
        $base + {action: "refused", note: "stale event: card already in \($cur), ahead of \($ev.status)"}
      end'
}

# Prints the IDs file (config/github-project.json) of the FlowForge commit in use.
_flowforge_project_config() {
  if [[ -n "${FLOWFORGE_PROJECT_CONFIG:-}" ]]; then
    cat "$FLOWFORGE_PROJECT_CONFIG"
  else
    gh api -H "Accept: application/vnd.github.raw+json" \
      "repos/$FLOWFORGE_REPOSITORY/contents/config/github-project.json?ref=$FLOWFORGE_SHA"
  fi
}

# The sync itself. Prints "<action><TAB><log line>"; returns 1 with the reason on stderr on
# any failure.
_flowforge_project_sync() {
  local issue="$1" event="$2" config content item decision action
  local project_id status_field attention_field status_option attention_option
  local item_id current attention target target_attention written=""

  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || { _flowforge_project_fail "invalid Issue number '$issue'"; return 1; }
  jq -ne --arg e "$event" --argjson events "$FLOWFORGE_PROJECT_EVENTS" '$events | has($e)' >/dev/null \
    || { _flowforge_project_fail "unknown event '$event'"; return 1; }
  [[ -n "${PROJECT_TOKEN:-}" ]] \
    || { _flowforge_project_fail "no Project token (app_client_id / app_private_key not set, or the token could not be created)"; return 1; }

  config="$(_flowforge_project_config)" || { _flowforge_project_fail "IDs file config/github-project.json not readable"; return 1; }
  [[ "$(jq -r '.number' <<<"$config")" == "${PROJECT_NUMBER:-}" ]] \
    || { _flowforge_project_fail "project_number '${PROJECT_NUMBER:-}' does not match the IDs file (Project #$(jq -r '.number' <<<"$config"))"; return 1; }
  project_id="$(jq -r '.project_id' <<<"$config")"
  status_field="$(jq -r '.fields.Status.id' <<<"$config")"
  attention_field="$(jq -r '.fields.Attention.id' <<<"$config")"

  # Identified by repository + number through the API, never by number alone; PRs refused.
  content="$(gh api "repos/$GITHUB_REPOSITORY/issues/$issue" \
    --jq 'if .pull_request then "PR" else .node_id end')" \
    || { _flowforge_project_fail "Issue #$issue not readable in $GITHUB_REPOSITORY"; return 1; }
  [[ "$content" != PR && -n "$content" ]] || { _flowforge_project_fail "#$issue is a pull request, not an Issue"; return 1; }

  # Adding an Issue already in the Project returns its existing item: find-or-add in one call.
  # shellcheck disable=SC2016  # $project, $content are GraphQL variables
  item="$(GH_TOKEN="$PROJECT_TOKEN" gh api graphql -f project="$project_id" -f content="$content" -f query='
    mutation($project: ID!, $content: ID!) {
      addProjectV2ItemById(input: {projectId: $project, contentId: $content}) {
        item {
          id
          status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
          attention: fieldValueByName(name: "Attention") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
        }
      }
    }' --jq '.data.addProjectV2ItemById.item | {id, status: (.status.name // ""), attention: (.attention.name // "")}')" \
    || { _flowforge_project_fail "could not add or read the Project item"; return 1; }
  item_id="$(jq -r '.id // empty' <<<"$item")"
  [[ -n "$item_id" ]] || { _flowforge_project_fail "no Project item returned"; return 1; }
  current="$(jq -r '.status' <<<"$item")"
  attention="$(jq -r '.attention' <<<"$item")"

  decision="$(flowforge_project_decide "$event" "$current" "$attention" "${FLOWFORGE_PROJECT_FORCE:-}")" || return 1
  action="$(jq -r '.action' <<<"$decision")"
  target="$(jq -r '.status' <<<"$decision")"
  target_attention="$(jq -r '.attention' <<<"$decision")"

  if [[ "$action" == update ]]; then
    if [[ "$target" != "$current" ]]; then
      status_option="$(jq -r --arg s "$target" '.fields.Status.options[$s] // empty' <<<"$config")"
      [[ -n "$status_option" ]] || { _flowforge_project_fail "Status option '$target' missing from the IDs file"; return 1; }
      _flowforge_project_set "$project_id" "$item_id" "$status_field" "$status_option" \
        || { _flowforge_project_fail "could not set Status ${current:-(none)} → $target"; return 1; }
      written="Status ${current:-(none)} → $target"
    fi
    if [[ "$target_attention" != "$attention" ]]; then
      attention_option=""
      if [[ -n "$target_attention" ]]; then
        attention_option="$(jq -r --arg a "$target_attention" '.fields.Attention.options[$a] // empty' <<<"$config")"
        [[ -n "$attention_option" ]] \
          || { _flowforge_project_fail "Attention option '$target_attention' missing from the IDs file" "$written"; return 1; }
      fi
      _flowforge_project_set "$project_id" "$item_id" "$attention_field" "$attention_option" \
        || { _flowforge_project_fail "could not set Attention ${attention:-(none)} → ${target_attention:-(none)}" "$written"
             return 1; }
    fi
  fi

  jq -r --arg ref "$GITHUB_REPOSITORY#$issue" '
    def s: if . == "" then "(none)" else . end;
    "\(.action)\tProject sync \($ref) [\(.reason)]: \(.action) — Status \(.previous_status | s) → \(.status | s), Attention \(.previous_attention | s) → \(.attention | s)"
    + (if .note != "" then " (\(.note))" else "" end)' <<<"$decision"
}

# Sets the single-select field $3 of item $2 to option $4, or clears it when $4 is empty.
_flowforge_project_set() {
  # shellcheck disable=SC2016  # GraphQL variables
  if [[ -n "$4" ]]; then
    GH_TOKEN="$PROJECT_TOKEN" gh api graphql --silent \
      -f project="$1" -f item="$2" -f field="$3" -f option="$4" -f query='
      mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
        updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field,
                                              value: {singleSelectOptionId: $option}}) { clientMutationId }
      }'
  else
    GH_TOKEN="$PROJECT_TOKEN" gh api graphql --silent -f project="$1" -f item="$2" -f field="$3" -f query='
      mutation($project: ID!, $item: ID!, $field: ID!) {
        clearProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field}) { clientMutationId }
      }'
  fi
}

# Reports a failure of the sync on stderr, tagged so that the wrapper can tell it from the
# output of gh / jq: "flowforge: <operation>", plus "flowforge-partial: <write>" when a write
# already succeeded in this call.
_flowforge_project_fail() {
  printf 'flowforge: %s\n' "$1" >&2
  [[ -z "${2:-}" ]] || printf 'flowforge-partial: %s\n' "$2" >&2
}

# Masks credentials in stdin: the exact PROJECT_TOKEN / GH_TOKEN values, then known shapes
# (GitHub tokens, Claude tokens, JWTs such as App JWTs, Authorization / Bearer / token= values,
# private keys). Does not rely on GitHub Actions masking.
_flowforge_project_redact() {
  local text secret
  text="$(cat)"
  for secret in "${PROJECT_TOKEN:-}" "${GH_TOKEN:-}"; do
    if (( ${#secret} >= 8 )); then text="${text//"$secret"/[REDACTED]}"; fi
  done
  sed -E \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----.*/[REDACTED]/' \
    -e 's/([Aa]uthorization:)[[:space:]]*(([Bb]earer|[Tt]oken|[Bb]asic)[[:space:]]+)?[^[:space:]]+/\1 [REDACTED]/g' \
    -e 's/([Bb]earer)[[:space:]]+[^[:space:][]+/\1 [REDACTED]/g' \
    -e 's/((^|[^[:alnum:]_])[Tt]oken[=:][[:space:]]*)[^[:space:],;&[]+/\1[REDACTED]/g' \
    -e 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]+/[REDACTED]/g' \
    -e 's/sk-ant-[A-Za-z0-9_-]+/[REDACTED]/g' \
    -e 's/eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/[REDACTED]/g' <<<"$text"
}

# Turns what gh / jq printed (stdin) into one line: GraphQL JSON errors as "TYPE: message",
# the "gh: " prefix dropped, blank lines skipped, credentials masked. At most 5 lines of 300
# characters, 800 in total; a cut is marked with "…".
_flowforge_project_reason() {
  local text line joined="" n=0
  text="$(cat)"
  if jq -e 'type == "object" and (.errors | type == "array")' <<<"$text" >/dev/null 2>&1; then
    text="$(jq -r '.errors[] | if .type then "\(.type): \(.message)" else .message end' <<<"$text")"
  fi
  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] || continue
    if (( n == 5 )); then joined+=" | …"; break; fi
    line="${line#gh: }"
    (( ${#line} <= 300 )) || line="${line:0:299}…"
    joined+="${joined:+ | }$line"
    n=$((n + 1))
  done < <(_flowforge_project_redact <<<"$text")
  (( ${#joined} <= 800 )) || joined="${joined:0:799}…"
  printf '%s' "$joined"
}

# The failure line for Issue $1, event $2, from the stderr file $3 of _flowforge_project_sync:
# "<operation> — GitHub: <reason>", and whether the card was left unchanged.
_flowforge_project_failure() {
  local operation="" partial="" reason line card="The card is unchanged"
  local -a other=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "flowforge: "*) operation+="${operation:+; }${line#flowforge: }" ;;
      "flowforge-partial: "*) partial="${line#flowforge-partial: }" ;;
      *) other+=("$line") ;;
    esac
  done < "$3"
  reason="$(printf '%s\n' "${other[@]}" | _flowforge_project_reason)"
  operation="$(_flowforge_project_redact <<<"$operation")"
  [[ -z "$partial" ]] || card="The card is partially updated ($partial)"
  if [[ -n "$operation" && -n "$reason" ]]; then
    reason="$operation — GitHub: $reason"
  elif [[ -n "$operation" ]]; then
    reason="$operation"
  elif [[ -n "$reason" ]]; then
    reason="GitHub: $reason"
  else
    reason="Unknown GitHub Project sync error"
  fi
  printf 'Project sync %s#%s [%s] failed: %s. %s; the agent run is not affected.\n' \
    "$GITHUB_REPOSITORY" "$1" "$2" "$reason" "$card"
}

# Applies event $2 to Issue $1 on the Project. Never fails the caller (unless
# FLOWFORGE_PROJECT_STRICT=1): a failure is a warning plus a step summary line, and sets
# FLOWFORGE_PROJECT_RESULT=failed. A refused or skipped event is a warning too.
flowforge_project_sync() {
  local out line err
  FLOWFORGE_PROJECT_RESULT=failed
  err="$(mktemp)"
  if out="$(_flowforge_project_sync "$1" "$2" 2>"$err")"; then
    rm -f "$err"
    IFS=$'\t' read -r FLOWFORGE_PROJECT_RESULT line <<<"$out"
    case "$FLOWFORGE_PROJECT_RESULT" in
      refused | skipped) echo "::warning::$line" ;;
      *) echo "$line" ;;
    esac
    [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "- $line" >> "$GITHUB_STEP_SUMMARY"
    return 0
  fi
  line="$(_flowforge_project_failure "$1" "$2" "$err")"
  rm -f "$err"
  echo "::warning::$line"
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "- ⚠️ $line" >> "$GITHUB_STEP_SUMMARY"
  [[ "${FLOWFORGE_PROJECT_STRICT:-}" != 1 ]]
}
