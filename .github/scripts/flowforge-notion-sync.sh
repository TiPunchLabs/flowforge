# shellcheck shell=bash
# FlowForge — GitHub → Notion status feedback (Phase 7, Prompt 34). Sourced by
# .github/workflows/notion-sync.yml and tests/notion-sync.sh, never run on its own.
#
# A central, one-way reconciler: it reads the Needs that link a GitHub Issue, reads the CURRENT
# state of that Issue (Project card, close reason, linked pull request) and rewrites in Notion
# only the integration-owned properties that differ. It never reads Notion to decide anything
# on GitHub, never writes GitHub, never starts an agent. See docs/notion/feedback.md.
#
# Three steps, each with only the credential it needs, sharing files in FLOWFORGE_NOTION_WORK:
#
#   flowforge_notion_sync_collect [page_id]  NOTION_TOKEN  read the Needs (all, or one), check
#                                                          the correlation on the Notion side
#   flowforge_notion_sync_read_github        GH_TOKEN      read Issue, Project item, linked PRs;
#                                            (Bridge App)  check the correlation on the GitHub side
#   flowforge_notion_sync_apply              NOTION_TOKEN  decide, write only what differs
#
# Results per Need: UPDATED, UNCHANGED, REFUSED (correlation or data invalid), FAILED (technical).
#
# Environment: as flowforge-notion.sh (FLOWFORGE_NOTION_CONFIG, FLOWFORGE_NOTION_ALLOWLIST,
# FLOWFORGE_NOTION_WORK), plus FLOWFORGE_PROJECT_CONFIG (config/github-project.json) and
# BRIDGE_LOGIN (read step: the Bridge App's bot login).

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/flowforge-notion.sh"

FLOWFORGE_NOTION_SYNC_STATUSES='["Backlog", "Refining", "Ready", "Developing", "Review", "Iteration", "Human validation", "Done"]'

# --- Pure functions (no API) -----------------------------------------------------------------

# Prints "owner/name<TAB>number" for a canonical GitHub Issue URL $1; fails on anything else
# (query, fragment, trailing slash, pull request URL, other host).
flowforge_notion_sync_issue_ref() {
  [[ "$1" =~ ^https://github\.com/([A-Za-z0-9-]+/[A-Za-z0-9._-]+)/issues/([1-9][0-9]*)$ ]] || return 1
  printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# Prints a Need page ($1: JSON of a page) as the flat object the sync works on. Fails on schema
# drift (a property the sync reads or writes is missing or of another type).
flowforge_notion_sync_parse_need() {
  # shellcheck disable=SC2016  # jq program
  jq -e '
    def has_type($n; $t): (.properties[$n].type // "") == $t;
    def text($n): [.properties[$n][.properties[$n].type][]?.plain_text] | join("");
    if (has_type("GitHub Issue"; "url") and has_type("FlowForge Status"; "select")
        and has_type("Attention"; "select") and has_type("Pull request"; "url")
        and has_type("Completed at"; "date") and has_type("Integration status"; "select")
        and has_type("Integration message"; "rich_text") and has_type("Need ID"; "unique_id")
        and has_type("Target repository"; "relation"))
    | not then error("schema") else . end
    | {
        id,
        in_trash: ((.in_trash // .archived) == true),
        data_source: (if .parent.type == "data_source_id" then .parent.data_source_id else "" end),
        need_id: (.properties["Need ID"].unique_id
                  | if .number == null then "" elif .prefix then "\(.prefix)-\(.number)" else "\(.number)" end),
        issue: (.properties["GitHub Issue"].url // ""),
        status: (.properties["FlowForge Status"].select.name // ""),
        attention: (.properties.Attention.select.name // ""),
        pr: (.properties["Pull request"].url // ""),
        completed: (.properties["Completed at"].date.start // ""),
        integration: (.properties["Integration status"].select.name // ""),
        message: text("Integration message"),
        repositories: [.properties["Target repository"].relation[].id],
        repositories_more: (.properties["Target repository"].has_more == true)
      }' "$1" 2>/dev/null
}

# Prints the decision for one Need: $1 = Need record (collect), $2 = GitHub record (read, or
# "null" when the Need was refused before any GitHub call). Output (compact JSON):
#   {result, props, message, previous_status, status, previous_pr, pr, changed,
#    previous_completed, completed}
# props is the Notion properties object to PATCH; {} = nothing to write.
#
# Rules (docs/notion/feedback.md §5): FlowForge Status mirrors the Project Status, except an
# Issue closed as not planned / duplicate (Closed) or closed as completed (Done); no Project
# item = keep. Attention mirrors the Project. Pull request = merged PR of the same repository,
# else its latest open PR, else keep a valid link (never cleared). Completed at only for Done.
flowforge_notion_sync_decide() {
  # shellcheck disable=SC2016  # jq program
  jq -nc --argjson n "$1" --argjson g "$2" --argjson statuses "$FLOWFORGE_NOTION_SYNC_STATUSES" \
    --argjson max "$FLOWFORGE_NOTION_MESSAGE_MAX" '
    def norm: if . == null or . == "" then "" else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") end;
    # A date as a UTC instant at minute precision: Notion may return another offset than the
    # one written, and stores minutes. Unparsable values stay strings (never equal: rewritten).
    def instant: norm
      | if . == "" then ""
        else (capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})(T(?<t>[0-9]{2}:[0-9]{2})(:[0-9]{2})?(?<z>Z|[+-][0-9]{2}:[0-9]{2})?)?$") // null) as $c
        | if $c == null then .
          else ("\($c.d)T\($c.t // "00:00"):00Z" | fromdateiso8601)
               - (($c.z // "Z") | if . == "Z" then 0
                  else (.[0:1] | if . == "-" then -1 else 1 end) * ((.[1:3] | tonumber) * 3600 + (.[4:6] | tonumber) * 60) end)
          end
        end;
    def sel($v): {select: (if $v == "" then null else {name: $v} end)};
    def errprops($m): if $n.integration == "Error" and $n.message == $m then {}
      else {"Integration status": {select: {name: "Error"}},
            "Integration message": {rich_text: [{text: {content: $m}}]}} end;
    ($n.check // "") as $nc | (($g // {}).check // "") as $gc
    | if $nc != "ok" or $gc != "ok" then
        (if $nc != "ok" then $nc else $gc end | ascii_upcase) as $r
        | ((if $nc != "ok" then $n.reason else $g.reason end) as $why | "\($r): \($why)" | .[0:$max]) as $m
        | {result: $r, props: (if $n.writable then errprops($m) else {} end), message: $m,
           previous_status: $n.status, status: $n.status, previous_pr: $n.pr, pr: $n.pr,
           changed: [], previous_completed: ($n.completed // ""), completed: ($n.completed // "")}
      else
        $n.repository as $repo
        | $g.issue as $i | $g.item as $item
        | (if $i.state == "closed" and ($i.state_reason | IN("not_planned", "duplicate")) then "Closed"
           elif $i.state == "closed" then "Done"
           elif $item != null and ($statuses | index($item.status)) != null then $item.status
           else $n.status end) as $status
        | (if $item != null then $item.attention else $n.attention end) as $attention
        | [$g.prs[] | select((.repository | ascii_downcase) == ($repo | ascii_downcase))] as $prs
        | ([$prs[] | select(.state == "MERGED")] | max_by(.mergedAt)) as $merged
        | ($merged // ([$prs[] | select(.state == "OPEN")] | max_by(.number))) as $chosen
        | ("^https://github\\.com/\($repo | gsub("\\."; "\\."))/pull/[1-9][0-9]*$") as $valid
        | (if $chosen != null then "https://github.com/\($repo)/pull/\($chosen.number)"
           elif ($n.pr | test($valid; "i")) then $n.pr
           else "" end) as $pr
        | (if $status == "Done" then (($merged.mergedAt // $i.closed_at // $n.completed) | norm)
           else "" end) as $completed
        # Parenthesised: jq 1.7 binds `as` to the last term of a sum only.
        | ({}
           + (if $status != $n.status then {"FlowForge Status": sel($status)} else {} end)
           + (if $attention != $n.attention then {"Attention": sel($attention)} else {} end)
           + (if $pr != $n.pr then {"Pull request": {url: (if $pr == "" then null else $pr end)}} else {} end)
           + (if ($completed | instant) != ($n.completed | instant)
              then {"Completed at": {date: (if $completed == "" then null else {start: $completed} end)}}
              else {} end)) as $changes
        | ([ (if $changes | has("FlowForge Status") then
                (if $status == "Done" then "Need completed."
                 elif $status == "Human validation" then "Need reached Human validation."
                 elif $status == "Closed" then "Need closed (Issue closed as \($i.state_reason))."
                 else "FlowForge status updated to \($status)." end) else empty end),
             (if ($changes | has("Pull request")) and $pr != "" then
                "Pull request #\($pr | sub(".*/"; "")) linked." else empty end),
             (if $changes | has("Attention") then
                (if $attention == "" then "Attention cleared." else "Attention: \($attention)." end)
              else empty end) ]
           | if length == 0 then "Notion matches GitHub." else join(" ") end
           | "SYNCED: \(.)") as $m
        | (if ($changes | length) > 0 or $n.integration != "OK" then
             $changes + {"Integration status": {select: {name: "OK"}},
                         "Integration message": {rich_text: [{text: {content: $m}}]}}
           else {} end) as $props
        | {result: (if ($props | length) > 0 then "UPDATED" else "UNCHANGED" end), props: $props,
           message: (if ($props | length) > 0 then $m else "UNCHANGED: Notion already matches GitHub." end),
           previous_status: $n.status, status: $status, previous_pr: $n.pr, pr: $pr,
           changed: ($changes | keys), previous_completed: $n.completed,
           completed: (if $changes | has("Completed at") then $completed else $n.completed end)}
      end'
}

# --- Step 1: collect (NOTION_TOKEN) ----------------------------------------------------------

# Appends the record of one Need to needs.jsonl: the flat Need plus check (ok | refused |
# failed), reason, writable (may the Integration fields of this page be written), and, when
# ok, repository (allowlist spelling) and number.
_flowforge_notion_sync_record() {
  jq -c --arg check "$2" --arg reason "$3" --argjson writable "$4" \
    --arg repository "${5:-}" --arg number "${6:-}" \
    '. + {check: $check, reason: $reason, writable: $writable, repository: $repository, number: $number}' \
    <<<"$1" >> "$FLOWFORGE_NOTION_WORK/needs.jsonl"
}

# Checks one parsed Need ($1, JSON) on the Notion side and records it. Repository pages are
# cached in FLOWFORGE_NOTION_WORK/repos/.
_flowforge_notion_sync_check() {
  local need="$1" w="$FLOWFORGE_NOTION_WORK" ref repo number repo_id repo_page repository allowed
  local repos_ds
  repos_ds="$(jq -r '.databases["FlowForge Repositories"].data_source_id' "$FLOWFORGE_NOTION_CONFIG")"
  if ! ref="$(flowforge_notion_sync_issue_ref "$(jq -r '.issue' <<<"$need")")"; then
    _flowforge_notion_sync_record "$need" refused "GitHub Issue is not a canonical https://github.com/<owner>/<repo>/issues/<n> URL." true
    return 0
  fi
  IFS=$'\t' read -r repo number <<<"$ref"
  if ! jq -e '(.repositories | length) == 1 and (.repositories_more | not)' <<<"$need" >/dev/null; then
    _flowforge_notion_sync_record "$need" refused "The Need must have exactly one Target repository." true
    return 0
  fi
  repo_id="$(jq -r '.repositories[0]' <<<"$need")"
  mkdir -p "$w/repos"
  if [[ ! -s "$w/repos/$repo_id.json" ]]; then
    if ! repo_page="$(flowforge_notion_api GET "/pages/$repo_id")"; then
      if [[ "$(cat "$w/last-status")" == 404 ]]; then
        _flowforge_notion_sync_record "$need" refused "The Target repository page is not readable (not found or not shared)." true
      else
        _flowforge_notion_sync_record "$need" failed "Reading the Target repository failed: $(flowforge_notion_last_error)" true
      fi
      return 0
    fi
    printf '%s\n' "$repo_page" > "$w/repos/$repo_id.json"
  fi
  repo_page="$(cat "$w/repos/$repo_id.json")"
  repository="$(jq -r '[.properties["GitHub repository"].rich_text[]?.plain_text] | join("") | gsub("^\\s+|\\s+$"; "")' <<<"$repo_page")"
  if ! jq -e --arg ds "$repos_ds" '.parent.data_source_id == $ds and ((.in_trash // .archived) != true)' <<<"$repo_page" >/dev/null; then
    _flowforge_notion_sync_record "$need" refused "The Target repository is not a live page of FlowForge Repositories." true
  elif [[ "${repository,,}" != "${repo,,}" ]]; then
    _flowforge_notion_sync_record "$need" refused "GitHub Issue repository $repo does not match the Target repository (${repository:-empty})." true
  elif ! jq -e '.properties["FlowForge enabled"].checkbox == true' <<<"$repo_page" >/dev/null; then
    _flowforge_notion_sync_record "$need" refused "The Target repository is not FlowForge enabled." true
  else
    allowed="$(jq -r --arg r "$repo" '.repositories[] | select(ascii_downcase == ($r | ascii_downcase))' "$FLOWFORGE_NOTION_ALLOWLIST")"
    if [[ -z "$allowed" ]]; then
      _flowforge_notion_sync_record "$need" refused "Repository $repo is not in the FlowForge allowlist (config/notion-allowlist.json)." true
    else
      _flowforge_notion_sync_record "$need" ok "" true "$allowed" "$number"
    fi
  fi
}

# Parses the page in file $1 and checks it. A page that is not a live, submitted Need is
# recorded as refused and NOT writable: the sync never writes to it.
_flowforge_notion_sync_page() {
  local file="$1" need needs_ds
  needs_ds="$(jq -r '.databases["FlowForge Needs"].data_source_id' "$FLOWFORGE_NOTION_CONFIG")"
  if ! need="$(flowforge_notion_sync_parse_need "$file")"; then
    need="$(jq -c '{id, need_id: "", issue: "", status: "", pr: "", integration: "", message: ""}' "$file")"
    if jq -e --arg ds "$needs_ds" '.parent.data_source_id == $ds' "$file" >/dev/null; then
      _flowforge_notion_sync_record "$need" failed "The Need does not have the properties of the model (schema drift): see docs/notion/model.md §5.3." false
    else
      _flowforge_notion_sync_record "$need" refused "The page is not a Need of FlowForge Needs." false
    fi
  elif [[ "$(jq -r '.data_source' <<<"$need")" != "$needs_ds" ]]; then
    _flowforge_notion_sync_record "$need" refused "The page is not a Need of FlowForge Needs." false
  elif jq -e '.in_trash' <<<"$need" >/dev/null; then
    _flowforge_notion_sync_record "$need" refused "The Need is in the trash." false
  elif jq -e '.issue == ""' <<<"$need" >/dev/null; then
    _flowforge_notion_sync_record "$need" refused "The Need has no GitHub Issue (not submitted): nothing to sync." false
  else
    _flowforge_notion_sync_check "$need"
  fi
}

# Collects the Needs to sync into needs.jsonl: the page $1 only, or every Need of FlowForge
# Needs whose GitHub Issue is set. A failure to list is recorded in run-error.
flowforge_notion_sync_collect() {
  local w="$FLOWFORGE_NOTION_WORK" needs_ds body cursor="" out n=0
  : > "$w/needs.jsonl"
  needs_ds="$(jq -r '.databases["FlowForge Needs"].data_source_id' "$FLOWFORGE_NOTION_CONFIG")"
  mkdir -p "$w/pages"
  if [[ -n "${1:-}" ]]; then
    if ! out="$(flowforge_notion_api GET "/pages/$1")"; then
      if [[ "$(cat "$w/last-status")" =~ ^(400|404)$ ]]; then
        jq -nc --arg id "$1" '{id: $id, need_id: "", issue: "", status: "", pr: "", integration: "", message: ""}' \
          | { read -r need; _flowforge_notion_sync_record "$need" refused "Page $1 not found or not shared with the FlowForge Notion integration." false; }
      else
        printf 'Reading the Need failed: %s\n' "$(flowforge_notion_last_error)" > "$w/run-error"
      fi
      return 0
    fi
    printf '%s\n' "$out" > "$w/pages/0.json"
    _flowforge_notion_sync_page "$w/pages/0.json"
    return 0
  fi
  while :; do
    body="$(jq -nc --arg c "$cursor" '{page_size: 100, filter: {property: "GitHub Issue", url: {is_not_empty: true}}}
      + (if $c == "" then {} else {start_cursor: $c} end)')"
    if ! out="$(flowforge_notion_api POST "/data_sources/$needs_ds/query" "$body")"; then
      printf 'Listing FlowForge Needs failed: %s\n' "$(flowforge_notion_last_error)" > "$w/run-error"
      return 0
    fi
    while IFS= read -r page; do
      n=$((n + 1))
      printf '%s\n' "$page" > "$w/pages/$n.json"
      _flowforge_notion_sync_page "$w/pages/$n.json"
    done < <(jq -c '.results[]' <<<"$out")
    jq -e '.has_more == true' <<<"$out" >/dev/null || break
    cursor="$(jq -r '.next_cursor' <<<"$out")"
  done
}

# --- Step 2: read GitHub (GH_TOKEN = Notion Bridge App token, read-only scopes) --------------

# Appends the GitHub record of one Need to github.jsonl.
_flowforge_notion_sync_github() {
  jq -nc --arg id "$1" --arg check "$2" --arg reason "$3" --argjson data "${4:-null}" \
    '{id: $id, check: $check, reason: $reason} + ($data // {})' >> "$FLOWFORGE_NOTION_WORK/github.jsonl"
}

# For each Need checked ok: the Issue (REST: author, body marker, state), its card in the
# FlowForge Project and the pull requests that close it (GraphQL). The Issue must have been
# created by the Bridge for THIS page (marker), so a Need cannot claim another Need's Issue.
flowforge_notion_sync_read_github() {
  local w="$FLOWFORGE_NOTION_WORK" line id repo number issue err project_id data
  : > "$w/github.jsonl"
  project_id="$(jq -r '.project_id' "$FLOWFORGE_PROJECT_CONFIG")"
  while IFS= read -r line; do
    id="$(jq -r '.id' <<<"$line")"
    repo="$(jq -r '.repository' <<<"$line")"
    number="$(jq -r '.number' <<<"$line")"
    if [[ -z "${GH_TOKEN:-}" ]]; then
      _flowforge_notion_sync_github "$id" failed "No Notion Bridge token could be created (App not installed on $repo, or wrong App credentials / permissions)."
      continue
    fi
    if ! issue="$(gh api "repos/$repo/issues/$number" 2>"$w/gh-error")"; then
      err="$(tr '\n' ' ' < "$w/gh-error" | cut -c1-400)"
      if [[ "$err" == *"HTTP 404"* || "$err" == *"HTTP 410"* ]]; then
        _flowforge_notion_sync_github "$id" refused "Issue $repo#$number not found (deleted or transferred)."
      else
        _flowforge_notion_sync_github "$id" failed "Reading Issue $repo#$number failed: $err"
      fi
      continue
    fi
    if jq -e '.pull_request != null' <<<"$issue" >/dev/null; then
      _flowforge_notion_sync_github "$id" refused "$repo#$number is a pull request, not an Issue."
      continue
    fi
    if ! jq -e --arg login "$BRIDGE_LOGIN" --arg m "$(flowforge_notion_marker "$id")" \
      '.user.login == $login and ((.body // "") | contains($m))' <<<"$issue" >/dev/null; then
      _flowforge_notion_sync_github "$id" refused "Issue $repo#$number was not created by the Notion Bridge for this Need (author or marker mismatch)."
      continue
    fi
    # shellcheck disable=SC2016  # GraphQL variables
    if ! data="$(gh api graphql -f owner="${repo%%/*}" -f name="${repo#*/}" -F number="$number" -f query='
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          issue(number: $number) {
            projectItems(first: 20, includeArchived: true) {
              nodes {
                isArchived
                project { id }
                status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
                attention: fieldValueByName(name: "Attention") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
              }
            }
            closedByPullRequestsReferences(first: 20, includeClosedPrs: true) {
              nodes { number state mergedAt repository { nameWithOwner } }
            }
          }
        }
      }' 2>"$w/gh-error")"; then
      err="$(tr '\n' ' ' < "$w/gh-error" | cut -c1-400)"
      _flowforge_notion_sync_github "$id" failed "Reading the Project card / pull requests of $repo#$number failed: $err"
      continue
    fi
    data="$(jq -c --arg p "$project_id" --argjson i "$issue" '
      .data.repository.issue as $x
      | ([$x.projectItems.nodes[] | select(.project.id == $p)] | sort_by(.isArchived) | first) as $item
      | {issue: {state: $i.state, state_reason: ($i.state_reason // ""), closed_at: ($i.closed_at // "")},
         item: (if $item == null then null
                else {status: ($item.status.name // ""), attention: ($item.attention.name // "")} end),
         prs: [$x.closedByPullRequestsReferences.nodes[]
               | {number, state, mergedAt, repository: .repository.nameWithOwner}]}' <<<"$data")" || {
      _flowforge_notion_sync_github "$id" failed "Unexpected GraphQL answer for $repo#$number."
      continue
    }
    _flowforge_notion_sync_github "$id" ok "" "$data"
  done < <(jq -c 'select(.check == "ok")' "$w/needs.jsonl")
}

# --- Step 3: apply (NOTION_TOKEN) ------------------------------------------------------------

# Decides each Need and writes only what differs (Last synced is stamped by every write).
# Records results.jsonl: {need_id, id, repository, issue, previous_status, status, pr, result,
# writeback (OK | none | FAILED), message}.
flowforge_notion_sync_apply() {
  local w="$FLOWFORGE_NOTION_WORK" line id gh decision props result writeback message
  : > "$w/results.jsonl"
  [[ -f "$w/github.jsonl" ]] || : > "$w/github.jsonl"
  while IFS= read -r line; do
    id="$(jq -r '.id' <<<"$line")"
    gh="$(jq -c --arg id "$id" 'select(.id == $id)' "$w/github.jsonl" | head -1)"
    [[ -n "$gh" ]] || gh=null
    if [[ "$gh" == null && "$(jq -r '.check' <<<"$line")" == ok ]]; then
      gh='{"check": "failed", "reason": "GitHub was not read (the read step did not run)."}'
    fi
    decision="$(flowforge_notion_sync_decide "$line" "$gh")"
    props="$(jq -c '.props' <<<"$decision")"
    result="$(jq -r '.result' <<<"$decision")"
    message="$(jq -r '.message' <<<"$decision")"
    writeback=none
    if [[ "$props" != "{}" ]]; then
      if flowforge_notion_update "$id" "$props"; then
        writeback=OK
      else
        writeback=FAILED
        result=FAILED
        message="Notion write-back failed: $(flowforge_notion_last_error) (intended: $message)"
      fi
    fi
    jq -c --argjson d "$decision" --arg result "$result" --arg writeback "$writeback" --arg m "$message" '
      {need_id, id, repository, issue, previous_status: $d.previous_status, status: $d.status,
       changed: $d.changed, previous_completed: $d.previous_completed, completed: $d.completed,
       pr: $d.pr, result: $result, writeback: $writeback, message: $m}' <<<"$line" >> "$w/results.jsonl"
  done < "$w/needs.jsonl"
}

# --- Report (no credential) ------------------------------------------------------------------

# Writes the step summary and one log line per Need. Fails when the run or any Need FAILED.
flowforge_notion_sync_report() {
  local w="$FLOWFORGE_NOTION_WORK" summary="${GITHUB_STEP_SUMMARY:-/dev/null}" failed=0
  {
    echo "### FlowForge — Notion feedback"
    if [[ -s "$w/run-error" ]]; then
      echo "- Result: **FAILED** — $(cat "$w/run-error")"
    elif [[ ! -s "$w/results.jsonl" ]]; then
      echo "- No Need with a GitHub Issue to sync."
    else
      echo "| Need | Repository | Issue | Previous status | New status | Pull request | Result | Notion write-back | Message | Changed | Completed at (Notion → written) |"
      echo "|---|---|---|---|---|---|---|---|---|---|---|"
      jq -r 'def c: tostring | gsub("\\|"; "/") | if . == "" then "-" else . end;
        "| \(.need_id | c) | \(.repository | c) | \(.issue | sub(".*/issues/"; "#") | c) | \(.previous_status | c) | \(.status | c) | \(.pr | c) | **\(.result)** | \(.writeback) | \(.message | c) | \(.changed // [] | join(", ") | c) | \(.previous_completed // "" | c) → \(.completed // "" | c) |"' \
        "$w/results.jsonl"
      jq -rs '"\nTotals: " + (group_by(.result) | map("\(.[0].result) \(length)") | join(", "))' "$w/results.jsonl"
    fi
  } >> "$summary"
  if [[ -s "$w/run-error" ]]; then
    echo "::error::FAILED: $(cat "$w/run-error")"
    return 1
  fi
  [[ -s "$w/results.jsonl" ]] || { echo "No Need with a GitHub Issue to sync."; return 0; }
  while IFS= read -r line; do
    echo "$line"
  done < <(jq -r '"Notion feedback need=\(.need_id // "-") page=\(.id) issue=\(.issue // "-") \(.previous_status // "-") -> \(.status // "-") pr=\(if (.pr // "") == "" then "-" else .pr end) result=\(.result) writeback=\(.writeback) changed=[\(.changed // [] | join(","))] completed=\(if (.previous_completed // "") == "" then "-" else .previous_completed end)->\(if (.completed // "") == "" then "-" else .completed end): \(.message)"' "$w/results.jsonl")
  if jq -e -s 'any(.result == "FAILED")' "$w/results.jsonl" >/dev/null; then
    failed=1
    echo "::error::At least one Need FAILED to sync: see the summary."
  fi
  if jq -e -s 'any(.result == "REFUSED")' "$w/results.jsonl" >/dev/null; then
    echo "::notice::At least one Need was REFUSED: see the summary."
  fi
  return "$failed"
}
