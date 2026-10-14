# shellcheck shell=bash
# FlowForge — Notion → GitHub submission (Phase 7, Prompt 33). Sourced by
# .github/workflows/notion-submit.yml and tests/notion-submit.sh, never run on its own.
#
# One Need (a page of "FlowForge Needs") becomes at most ONE GitHub Issue, created by the
# Notion Bridge GitHub App in the Need's target repository, raw need only, no label. Nothing
# here starts an agent. See docs/notion/submission.md (and docs/notion/model.md §10, §14, §15).
#
# The workflow runs three steps, each with only the credential it needs, sharing files in
# FLOWFORGE_NOTION_WORK:
#
#   flowforge_notion_prepare <page_id>   NOTION_TOKEN   read the Need, guards, claim Pending,
#                                                       validate, render the Issue
#   flowforge_notion_deliver             GH_TOKEN       find the Issue carrying the Need's marker,
#                                        (Bridge App)   or create it
#   flowforge_notion_finish              NOTION_TOKEN   write the outcome back to the Need
#
# Results: CREATED, LINKED (existing Issue found and linked: recovery), ALREADY_SUBMITTED,
# REFUSED (functional, the run stays green), FAILED (technical, the run fails).
#
# Environment: FLOWFORGE_NOTION_CONFIG (config/notion.json), FLOWFORGE_NOTION_ALLOWLIST
# (config/notion-allowlist.json), FLOWFORGE_NOTION_WORK (a private directory), BRIDGE_LOGIN
# (deliver: the Bridge App's bot login). Optional: FLOWFORGE_NOTION_API, FLOWFORGE_NOTION_RETRY_DELAY.
# Requires curl, jq, gh. Tokens are never printed, logged or passed on a command line.

FLOWFORGE_NOTION_TITLE_MAX=256
FLOWFORGE_NOTION_NEED_MAX=20000
# Notion rejects a rich text object above 2000 characters.
FLOWFORGE_NOTION_MESSAGE_MAX=1900
FLOWFORGE_NOTION_PRIORITIES='["Low", "Medium", "High", "Urgent"]'
FLOWFORGE_NOTION_MARKER_PREFIX='<!-- flowforge:notion-page-id='

# --- Pure functions (no API) -----------------------------------------------------------------

# Prints the canonical page ID (lowercase, dashed UUID) of $1: a page ID with or without dashes,
# or a Notion page URL (query and fragment ignored, the ID is the path's trailing 32 hex digits).
# Fails on anything else.
flowforge_notion_page_id() {
  local in="$1" hex
  in="${in#"${in%%[![:space:]]*}"}"
  in="${in%"${in##*[![:space:]]}"}"
  if [[ "$in" =~ ^https://([a-z0-9-]+\.)?notion\.(so|com|site)/ ]]; then
    in="${in%%[?#]*}"
    [[ "$in" =~ ([0-9a-fA-F]{32})$ ]] || return 1
    hex="${BASH_REMATCH[1]}"
  elif [[ "$in" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    hex="${in//-/}"
  elif [[ "$in" =~ ^[0-9a-fA-F]{32}$ ]]; then
    hex="$in"
  else
    return 1
  fi
  hex="${hex,,}"
  printf '%s-%s-%s-%s-%s\n' "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

# The hidden marker that ties an Issue to its Need (model §14).
flowforge_notion_marker() {
  printf '%s%s -->' "$FLOWFORGE_NOTION_MARKER_PREFIX" "$1"
}

# Prints a Need page ($1: JSON of GET /pages/{id}) as the flat object the rules work on. Fails
# if a property the submission relies on is missing or of another type (schema drift).
flowforge_notion_parse_need() {
  # shellcheck disable=SC2016  # jq program
  jq -e '
    def has_type($n; $t): (.properties[$n].type // "") == $t;
    def text($n): [.properties[$n][.properties[$n].type][]?.plain_text] | join("");
    if (has_type("Title"; "title") and has_type("Need"; "rich_text")
        and has_type("Submit"; "checkbox") and has_type("FlowForge Status"; "select")
        and has_type("Integration status"; "select") and has_type("GitHub Issue"; "url")
        and has_type("Priority"; "select") and has_type("Need ID"; "unique_id")
        and has_type("Project"; "relation") and has_type("Target repository"; "relation"))
    | not then error("schema") else . end
    | {
        id,
        in_trash: ((.in_trash // .archived) == true),
        data_source: (if .parent.type == "data_source_id" then .parent.data_source_id else "" end),
        title: text("Title"),
        need: text("Need"),
        submit: .properties.Submit.checkbox,
        status: (.properties["FlowForge Status"].select.name // ""),
        integration: (.properties["Integration status"].select.name // ""),
        issue: (.properties["GitHub Issue"].url // ""),
        priority: (.properties.Priority.select.name // ""),
        need_id: (.properties["Need ID"].unique_id
                  | if .number == null then "" elif .prefix then "\(.prefix)-\(.number)" else "\(.number)" end),
        projects: [.properties.Project.relation[].id],
        projects_more: (.properties.Project.has_more == true),
        repositories: [.properties["Target repository"].relation[].id],
        repositories_more: (.properties["Target repository"].has_more == true)
      }' "$1" 2>/dev/null
}

# Reads stdin as untrusted text and prints it safe to put in an Issue: HTML comments removed (no
# forged flowforge marker), "<!--" left over escaped, @mentions neutralised with a zero-width
# space (no notification), CR removed. Length is checked by the caller, never silently cut.
flowforge_notion_sanitize() {
  jq -Rrs '
    gsub("\r"; "")
    | gsub("<!--(?:.|\n)*?-->"; "")
    | gsub("<!--"; "&lt;!--")
    | gsub("(?<p>^|[^A-Za-z0-9_`/])@(?<n>[A-Za-z0-9])"; "\(.p)@​\(.n)")'
}

# Prints the Issue title from the raw Notion title on stdin: sanitised, one line, trimmed.
flowforge_notion_title() {
  flowforge_notion_sanitize | jq -Rrs 'gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "")'
}

# Prints the Issue body for the Need $1 (flat JSON from flowforge_notion_parse_need) and the
# Project name $2. Only the Need text crosses (model §11): no page content, no person.
flowforge_notion_render_body() {
  local need_file="$1" project="$2" id text need_id priority
  id="$(jq -r '.id' "$need_file")"
  text="$(jq -r '.need' "$need_file" | flowforge_notion_sanitize | sed -e 's/[[:space:]]*$//')"
  project="$(printf '%s' "$project" | flowforge_notion_title)"
  need_id="$(jq -r '.need_id | select(test("^[A-Z]+-[0-9]+$"))' "$need_file")"
  priority="$(jq -r '.priority' "$need_file")"
  printf '%s\n## Need\n\n%s\n\n## Context\n\n- Project: %s\n- Business priority: %s\n\n## Source\n\n' \
    "$(flowforge_notion_marker "$id")" "$text" "$project" "$priority"
  printf -- '- Submitted from Notion (FlowForge Needs%s)\n' "${need_id:+ \`$need_id\`}"
  # Built from the validated page ID, never from a URL read in Notion.
  printf -- '- Notion Need: <https://app.notion.com/p/%s>\n' "${id//-/}"
}

# Prints the Notion error of the last failed call, one line, size-limited (never a payload).
flowforge_notion_last_error() {
  local f="$FLOWFORGE_NOTION_WORK/last-error"
  [[ -s "$f" ]] && tr '\n' ' ' < "$f" | cut -c1-400 || echo "unknown error"
}

# --- Notion API ------------------------------------------------------------------------------

# Calls the Notion API: flowforge_notion_api METHOD PATH [JSON_BODY]. Prints the response. On
# failure records "METHOD PATH: HTTP <status> <code>: <message>" in last-error (Notion's reason,
# never the request) and the status in last-status, then fails. Retries 429 and 5xx.
flowforge_notion_api() {
  local method="$1" path="$2" body="${3:-}" out status="000" attempt version
  local w="$FLOWFORGE_NOTION_WORK"
  version="$(jq -r '.notion_version' "$FLOWFORGE_NOTION_CONFIG")"
  for attempt in 1 2 3 4; do
    if out="$(curl -sS -X "$method" "${FLOWFORGE_NOTION_API:-https://api.notion.com/v1}$path" \
      -H @<(printf 'Authorization: Bearer %s\n' "$NOTION_TOKEN") \
      -H "Notion-Version: $version" \
      -H "Content-Type: application/json" \
      ${body:+--data-binary @-} \
      -w '\n%{http_code}' <<<"$body" 2>"$w/curl-error")"; then
      status="${out##*$'\n'}"
      out="${out%$'\n'*}"
    else
      status="000"
      out=""
    fi
    case "$status" in
      2??) printf '%s\n' "$out"; return 0 ;;
      000 | 429 | 5??) sleep "$((attempt * ${FLOWFORGE_NOTION_RETRY_DELAY:-2}))" ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$status" > "$w/last-status"
  if [[ "$status" == "000" ]]; then
    printf '%s %s: network error\n' "$method" "${path%%\?*}" > "$w/last-error"
  else
    printf '%s %s: HTTP %s %s\n' "$method" "${path%%\?*}" "$status" \
      "$(jq -r '"\(.code // "?"): \(.message // "?")"' <<<"$out" 2>/dev/null || echo "?")" > "$w/last-error"
  fi
  return 1
}

# Updates properties of the Need $1 with the properties object $2 (JSON); always stamps
# "Last synced".
flowforge_notion_update() {
  local body
  body="$(jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{properties: (. + {"Last synced": {date: {start: $now}}})}' <<<"$2")"
  flowforge_notion_api PATCH "/pages/$1" "$body" >/dev/null
}

# Properties of an Error outcome: message $1, Submit unticked when $2 = untick.
flowforge_notion_error_props() {
  jq -nc --arg m "$1" --argjson max "$FLOWFORGE_NOTION_MESSAGE_MAX" --arg untick "$2" '
    {"Integration status": {select: {name: "Error"}},
     "Integration message": {rich_text: [{text: {content: ($m | .[0:$max])}}]}}
    + (if $untick == "untick" then {"Submit": {checkbox: false}} else {} end)'
}

# --- Decision files --------------------------------------------------------------------------

# Records the step outcome: result, reason, what finish must write to Notion
# (none | error_untick | error_keep | link).
_flowforge_notion_decide() {
  local w="$FLOWFORGE_NOTION_WORK"
  printf '%s\n' "$1" > "$w/result"
  printf '%s\n' "$2" > "$w/reason"
  printf '%s\n' "$3" > "$w/notion_action"
}

# Reads the related page $1 and checks it belongs to the data source $2 and is not trashed.
# Prints the page; fails with the reason in $FLOWFORGE_NOTION_WORK/related-error.
_flowforge_notion_related() {
  local page label="$3"
  if ! page="$(flowforge_notion_api GET "/pages/$1")"; then
    printf '%s\n' "$label could not be read: $(flowforge_notion_last_error)" > "$FLOWFORGE_NOTION_WORK/related-error"
    return 1
  fi
  if ! jq -e --arg ds "$2" '.parent.data_source_id == $ds and ((.in_trash // .archived) != true)' <<<"$page" >/dev/null; then
    printf '%s\n' "$label is not a live page of its FlowForge database." > "$FLOWFORGE_NOTION_WORK/related-error"
    return 1
  fi
  printf '%s\n' "$page"
}

# --- Step 1: prepare (NOTION_TOKEN) ----------------------------------------------------------

# Reads the Need $1 and decides. PROCEED leaves submission.json and issue-body.md for deliver.
flowforge_notion_prepare() {
  local id="$1" w="$FLOWFORGE_NOTION_WORK" cfg="$FLOWFORGE_NOTION_CONFIG"
  local needs_ds projects_ds repos_ds page need project repo project_name repository allowed
  local title need_len reason allow_create=true
  needs_ds="$(jq -r '.databases["FlowForge Needs"].data_source_id' "$cfg")"
  projects_ds="$(jq -r '.databases["FlowForge Projects"].data_source_id' "$cfg")"
  repos_ds="$(jq -r '.databases["FlowForge Repositories"].data_source_id' "$cfg")"
  printf '%s\n' "$id" > "$w/page_id"

  if ! page="$(flowforge_notion_api GET "/pages/$id")"; then
    case "$(cat "$w/last-status")" in
      400 | 404) _flowforge_notion_decide REFUSED "Page $id not found or not shared with the FlowForge Notion integration." none ;;
      *) _flowforge_notion_decide FAILED "Reading the Need failed: $(flowforge_notion_last_error)" none ;;
    esac
    return 0
  fi
  printf '%s\n' "$page" > "$w/page.json"
  if ! need="$(flowforge_notion_parse_need "$w/page.json")"; then
    if jq -e --arg ds "$needs_ds" '.parent.data_source_id == $ds' "$w/page.json" >/dev/null; then
      _flowforge_notion_decide FAILED "The Need does not have the properties of the model (schema drift): see docs/notion/model.md §5.3." none
    else
      _flowforge_notion_decide REFUSED "Page $id is not a Need of FlowForge Needs." none
    fi
    return 0
  fi
  printf '%s\n' "$need" > "$w/need.json"

  # Nothing is written to a page that is not a live Need, that was not submitted, or that
  # already has its Issue.
  if [[ "$(jq -r '.data_source' <<<"$need")" != "$needs_ds" ]]; then
    _flowforge_notion_decide REFUSED "Page $id is not a Need of FlowForge Needs." none
    return 0
  fi
  if jq -e '.in_trash' <<<"$need" >/dev/null; then
    _flowforge_notion_decide REFUSED "The Need is in the trash." none
    return 0
  fi
  if ! jq -e '.submit' <<<"$need" >/dev/null; then
    _flowforge_notion_decide REFUSED "Submit is not ticked: nothing was requested." none
    return 0
  fi
  if jq -e '.issue != ""' <<<"$need" >/dev/null; then
    printf '%s\n' "$(jq -r '.issue' <<<"$need")" > "$w/issue_url"
    _flowforge_notion_decide ALREADY_SUBMITTED "The Need already links an Issue; no second Issue is created." none
    return 0
  fi

  # Claim before validating, so an interrupted attempt is visible (model §10.1).
  if ! flowforge_notion_update "$id" '{"Integration status": {"select": {"name": "Pending"}}, "Integration message": {"rich_text": []}}'; then
    _flowforge_notion_decide FAILED "Claiming the Need failed: $(flowforge_notion_last_error)" none
    return 0
  fi

  # A Need past Draft with no Issue link lost its link: only an existing Issue may be relinked,
  # never a new one created (model §14).
  if ! jq -e '.status | IN("", "Draft")' <<<"$need" >/dev/null; then
    allow_create=false
  fi

  title="$(jq -r '.title' <<<"$need" | flowforge_notion_title)"
  need_len="$(jq -r '.need | length' <<<"$need")"
  reason=""
  if [[ -z "$title" ]]; then
    reason="Title is empty."
  elif (( ${#title} > FLOWFORGE_NOTION_TITLE_MAX )); then
    reason="Title is longer than $FLOWFORGE_NOTION_TITLE_MAX characters."
  elif ! jq -e '.need | test("\\S")' <<<"$need" >/dev/null; then
    reason="Need is empty."
  elif (( need_len > FLOWFORGE_NOTION_NEED_MAX )); then
    reason="Need is longer than $FLOWFORGE_NOTION_NEED_MAX characters ($need_len)."
  elif ! jq -e --argjson p "$FLOWFORGE_NOTION_PRIORITIES" '.priority as $v | $p | index($v)' <<<"$need" >/dev/null; then
    reason="Priority must be one of Low, Medium, High, Urgent."
  elif ! jq -e '(.projects | length) == 1 and (.projects_more | not)' <<<"$need" >/dev/null; then
    reason="The Need must have exactly one Project ($(jq -r 'if .projects_more then "more than 25" else (.projects | length) end' <<<"$need") set)."
  elif ! jq -e '(.repositories | length) == 1 and (.repositories_more | not)' <<<"$need" >/dev/null; then
    reason="The Need must have exactly one Target repository ($(jq -r 'if .repositories_more then "more than 25" else (.repositories | length) end' <<<"$need") set)."
  fi
  if [[ -n "$reason" ]]; then
    _flowforge_notion_decide REFUSED "$reason" error_untick
    return 0
  fi

  if ! project="$(_flowforge_notion_related "$(jq -r '.projects[0]' <<<"$need")" "$projects_ds" "The Project")" \
    || ! repo="$(_flowforge_notion_related "$(jq -r '.repositories[0]' <<<"$need")" "$repos_ds" "The Target repository")"; then
    reason="$(cat "$w/related-error")"
    if [[ "$reason" == *"could not be read"* && "$reason" != *"HTTP 404"* ]]; then
      _flowforge_notion_decide FAILED "$reason" error_keep
    else
      _flowforge_notion_decide REFUSED "$reason" error_untick
    fi
    return 0
  fi

  project_name="$(jq -r '[.properties.Name.title[]?.plain_text] | join("")' <<<"$project")"
  repository="$(jq -r '[.properties["GitHub repository"].rich_text[]?.plain_text] | join("") | gsub("^\\s+|\\s+$"; "")' <<<"$repo")"
  reason=""
  # Coherence first: a Need pointing at another Project's repository is wrong whatever the
  # state of that repository.
  if ! jq -e --arg p "$(jq -r '.projects[0]' <<<"$need")" \
    '[.properties.Project.relation[]?.id] == [$p] and (.properties.Project.has_more != true)' <<<"$repo" >/dev/null; then
    reason="The Target repository does not belong to the Need's Project."
  elif ! jq -e '.properties.Active.checkbox == true' <<<"$project" >/dev/null; then
    reason="The Project is not Active."
  elif ! jq -e '.properties["FlowForge enabled"].checkbox == true' <<<"$repo" >/dev/null; then
    reason="The Target repository is not FlowForge enabled."
  elif [[ ! "$repository" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then
    reason="The Target repository's GitHub repository is not of the form owner/name."
  fi
  if [[ -z "$reason" ]]; then
    # The allowlist (Git) is the routing truth; its spelling is the one used for GitHub calls.
    allowed="$(jq -r --arg r "$repository" '.repositories[] | select(ascii_downcase == ($r | ascii_downcase))' "$FLOWFORGE_NOTION_ALLOWLIST")"
    [[ -n "$allowed" ]] || reason="Repository $repository is not in the FlowForge allowlist (config/notion-allowlist.json)."
  fi
  if [[ -n "$reason" ]]; then
    _flowforge_notion_decide REFUSED "$reason" error_untick
    return 0
  fi

  jq -n --arg page_id "$id" --arg repository "$allowed" --arg title "$title" \
    --arg project "$project_name" --argjson allow_create "$allow_create" \
    --argjson need "$need" \
    '{page_id: $page_id, repository: $repository, title: $title, project: $project,
      need_id: $need.need_id, status: $need.status, allow_create: $allow_create}' > "$w/submission.json"
  flowforge_notion_render_body "$w/need.json" "$project_name" > "$w/issue-body.md"
  _flowforge_notion_decide PROCEED "Validated." none
}

# --- Step 2: deliver (GH_TOKEN = Notion Bridge App token, no Notion credential) --------------

# Finds the Issue the Bridge created for this Need (marker in the body), else creates it.
# The listing is the REST issues list (strongly consistent, unlike search), restricted to
# Issues authored by the Bridge, so a marker forged in someone else's Issue is ignored.
flowforge_notion_deliver() {
  local w="$FLOWFORGE_NOTION_WORK" repo title marker found count created err
  repo="$(jq -r '.repository' "$w/submission.json")"
  title="$(jq -r '.title' "$w/submission.json")"
  marker="$(flowforge_notion_marker "$(jq -r '.page_id' "$w/submission.json")")"

  # The token step may fail (continue-on-error): never fall back to another credential.
  if [[ -z "${GH_TOKEN:-}" ]]; then
    _flowforge_notion_decide FAILED "GitHub App has no access to target repository $repo: no Notion Bridge token could be created (App not installed on $repo, or wrong App credentials in the notion-bridge environment)." error_keep
    return 0
  fi

  if ! found="$(gh api --paginate "repos/$repo/issues?state=all&per_page=100" 2>"$w/gh-error" \
    | jq -cs --arg login "$BRIDGE_LOGIN" --arg m "$marker" \
      '[add // [] | .[] | select(.pull_request == null and .user.login == $login
         and ((.body // "") | contains($m))) | {number, html_url}] | sort_by(.number)')"; then
    err="$(tr '\n' ' ' < "$w/gh-error" | cut -c1-400)"
    _flowforge_notion_decide FAILED "Listing the Issues of $repo failed: $err" error_keep
    return 0
  fi
  count="$(jq 'length' <<<"$found")"
  if (( count > 1 )); then
    _flowforge_notion_decide FAILED "Several Issues of $repo carry this Need's marker ($(jq -r 'map("#\(.number)") | join(", ")' <<<"$found")): a human must keep one." error_keep
    return 0
  fi
  if (( count == 1 )); then
    jq -r '.[0].html_url' <<<"$found" > "$w/issue_url"
    _flowforge_notion_decide LINKED "Existing Issue #$(jq -r '.[0].number' <<<"$found") of $repo found and linked; none created." link
    return 0
  fi
  if ! jq -e '.allow_create' "$w/submission.json" >/dev/null; then
    _flowforge_notion_decide REFUSED "The Need is past Draft but has no Issue link and no Issue of $repo carries its marker: a human must resolve it (model §14)." error_untick
    return 0
  fi

  # Title and body only: no labels, no assignees, no milestone, no Project field.
  if ! created="$(jq -n --arg t "$title" --rawfile b "$w/issue-body.md" '{title: $t, body: $b}' \
    | gh api -X POST "repos/$repo/issues" --input - 2>"$w/gh-error")"; then
    err="$(tr '\n' ' ' < "$w/gh-error" | cut -c1-400)"
    _flowforge_notion_decide FAILED "Creating the Issue in $repo failed: $err" error_keep
    return 0
  fi
  jq -r '.html_url' <<<"$created" > "$w/issue_url"
  _flowforge_notion_decide CREATED "Issue #$(jq -r '.number' <<<"$created") created in $repo." link
}

# --- Step 3: finish (NOTION_TOKEN) -----------------------------------------------------------

# Writes the outcome to the Need. A step that never decided (crash, token error) is FAILED.
flowforge_notion_finish() {
  local w="$FLOWFORGE_NOTION_WORK" id result reason action props url
  [[ -s "$w/page_id" ]] || return 0
  id="$(cat "$w/page_id")"
  result="$(cat "$w/result" 2>/dev/null || echo "")"
  if [[ -z "$result" || "$result" == "PROCEED" ]]; then
    _flowforge_notion_decide FAILED "The submission was interrupted before an Issue was created or found; re-run it (no second Issue can be created)." error_keep
  fi
  result="$(cat "$w/result")"
  reason="$(cat "$w/reason")"
  action="$(cat "$w/notion_action")"
  case "$action" in
    link)
      url="$(cat "$w/issue_url")"
      props="$(jq -nc --arg u "$url" --arg m "$result: $reason" \
        '{"GitHub Issue": {url: $u}, "Integration status": {select: {name: "OK"}}, "Integration message": {rich_text: [{text: {content: $m}}]}}')"
      # Draft -> Backlog is the only status move Notion makes (model §9); a later status stays.
      if jq -e '.status | IN("", "Draft")' "$w/submission.json" >/dev/null; then
        props="$(jq -c '. + {"FlowForge Status": {select: {name: "Backlog"}}}' <<<"$props")"
      fi
      if ! flowforge_notion_update "$id" "$props"; then
        _flowforge_notion_decide FAILED "Issue $url exists but the Notion write-back failed: $(flowforge_notion_last_error). Re-run: the Issue will be found and linked, not created again." none
      fi
      ;;
    error_untick | error_keep)
      if ! flowforge_notion_update "$id" "$(flowforge_notion_error_props "$result: $reason" "${action#error_}")"; then
        printf '%s\n' "$reason Recording the error in Notion also failed: $(flowforge_notion_last_error)" > "$w/reason"
      fi
      ;;
  esac
}
