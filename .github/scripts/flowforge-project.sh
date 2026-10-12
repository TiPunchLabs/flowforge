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
  local item_id current attention target target_attention

  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || { echo "invalid Issue number '$issue'" >&2; return 1; }
  jq -ne --arg e "$event" --argjson events "$FLOWFORGE_PROJECT_EVENTS" '$events | has($e)' >/dev/null \
    || { echo "unknown event '$event'" >&2; return 1; }
  [[ -n "${PROJECT_TOKEN:-}" ]] \
    || { echo "no Project token (app_client_id / app_private_key not set, or the token could not be created)" >&2; return 1; }

  config="$(_flowforge_project_config)" || { echo "IDs file config/github-project.json not readable" >&2; return 1; }
  [[ "$(jq -r '.number' <<<"$config")" == "${PROJECT_NUMBER:-}" ]] \
    || { echo "project_number '${PROJECT_NUMBER:-}' does not match the IDs file (Project #$(jq -r '.number' <<<"$config"))" >&2; return 1; }
  project_id="$(jq -r '.project_id' <<<"$config")"
  status_field="$(jq -r '.fields.Status.id' <<<"$config")"
  attention_field="$(jq -r '.fields.Attention.id' <<<"$config")"

  # Identified by repository + number through the API, never by number alone; PRs refused.
  content="$(gh api "repos/$GITHUB_REPOSITORY/issues/$issue" \
    --jq 'if .pull_request then "PR" else .node_id end')" \
    || { echo "Issue #$issue not readable in $GITHUB_REPOSITORY" >&2; return 1; }
  [[ "$content" != PR && -n "$content" ]] || { echo "#$issue is a pull request, not an Issue" >&2; return 1; }

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
    || { echo "could not add or read the Project item" >&2; return 1; }
  item_id="$(jq -r '.id // empty' <<<"$item")"
  [[ -n "$item_id" ]] || { echo "no Project item returned" >&2; return 1; }
  current="$(jq -r '.status' <<<"$item")"
  attention="$(jq -r '.attention' <<<"$item")"

  decision="$(flowforge_project_decide "$event" "$current" "$attention" "${FLOWFORGE_PROJECT_FORCE:-}")" || return 1
  action="$(jq -r '.action' <<<"$decision")"
  target="$(jq -r '.status' <<<"$decision")"
  target_attention="$(jq -r '.attention' <<<"$decision")"

  if [[ "$action" == update ]]; then
    if [[ "$target" != "$current" ]]; then
      status_option="$(jq -r --arg s "$target" '.fields.Status.options[$s] // empty' <<<"$config")"
      [[ -n "$status_option" ]] || { echo "Status option '$target' missing from the IDs file" >&2; return 1; }
      _flowforge_project_set "$project_id" "$item_id" "$status_field" "$status_option" \
        || { echo "could not set Status to $target" >&2; return 1; }
    fi
    if [[ "$target_attention" != "$attention" ]]; then
      attention_option=""
      if [[ -n "$target_attention" ]]; then
        attention_option="$(jq -r --arg a "$target_attention" '.fields.Attention.options[$a] // empty' <<<"$config")"
        [[ -n "$attention_option" ]] || { echo "Attention option '$target_attention' missing from the IDs file" >&2; return 1; }
      fi
      _flowforge_project_set "$project_id" "$item_id" "$attention_field" "$attention_option" \
        || { echo "could not set Attention to '${target_attention:-empty}'" >&2; return 1; }
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
  line="Project sync $GITHUB_REPOSITORY#$1 [$2] failed: $(tail -n 1 "$err"). The card is unchanged; the agent run is not affected."
  rm -f "$err"
  echo "::warning::$line"
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "- ⚠️ $line" >> "$GITHUB_STEP_SUMMARY"
  [[ "${FLOWFORGE_PROJECT_STRICT:-}" != 1 ]]
}
