#!/usr/bin/env bash
# FlowForge — provision the Notion space "FlowForge" (Phase 7, Prompt 32).
#
# Desired state: docs/notion/model.md (§4, §5, §18), as provisioned in docs/notion/provisioning.md:
# three databases (Projects, Repositories, Needs), one data source each, their properties,
# two-way relations and the six views of the Needs database.
#
#   bootstrap.sh            create or converge the space, then write config/notion.json
#   bootstrap.sh --check    read-only: report drift between Notion and the model, exit 1 on drift
#
# Idempotent: a second run on a conform space makes no write call. Everything lives under ONE
# parent page: NOTION_PARENT_PAGE_ID if set, else parent_page_id from config/notion.json, else
# the single page titled "FlowForge" visible to the token. Databases are found by exact title
# among that page's children. Two matches is an error, never a guess.
# Converging only adds: a property of the wrong type, or an extra one, is reported, never
# changed or deleted (that would destroy data).
#
# Requires curl, jq and NOTION_TOKEN in the environment: the maintainer's Notion personal access
# token (acts as the maintainer, local use only), never the runtime credential of Prompts 33/34.
# The token is never printed, logged, written or passed on a command line.
set -euo pipefail

NOTION_API="https://api.notion.com/v1"
NOTION_VERSION="2026-03-11"
PARENT_TITLE="FlowForge"
CONFIG_FILE="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/config/notion.json"

CHECK=false
DRIFT=0

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  "") ;;
  --check) CHECK=true ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
drift() { log "DRIFT: $*"; DRIFT=$((DRIFT + 1)); }
manual() { log "MANUAL: $*"; }

[[ -n "${NOTION_TOKEN:-}" ]] || die "NOTION_TOKEN is not set"
command -v jq >/dev/null || die "jq is required"

# Calls the Notion API: api METHOD PATH [JSON_BODY]. Prints the response; fails with Notion's
# code and message (never the request, which may carry content). Retries on 429/5xx.
api() {
  local method="$1" path="$2" body="${3:-}" out status attempt
  for attempt in 1 2 3 4 5; do
    out="$(curl -sS -X "$method" "$NOTION_API$path" \
      -H @<(printf 'Authorization: Bearer %s\n' "$NOTION_TOKEN") \
      -H "Notion-Version: $NOTION_VERSION" \
      -H "Content-Type: application/json" \
      ${body:+--data-binary @-} \
      -w '\n%{http_code}' <<<"$body")" || die "$method $path: network error"
    status="${out##*$'\n'}"
    out="${out%$'\n'*}"
    case "$status" in
      2??) printf '%s\n' "$out"; return 0 ;;
      429 | 5??) sleep "$((attempt * 2))" ;;
      *) break ;;
    esac
  done
  die "$method $path: HTTP $status $(jq -r '"\(.code // "?"): \(.message // "?")"' <<<"$out" 2>/dev/null || echo "?")"
}

# Prints every result of the paginated GET $1 (a path with '?' already in it) as one JSON array.
api_all() {
  local cursor="" page acc="[]"
  while :; do
    page="$(api GET "$1${cursor:+&start_cursor=$cursor}")"
    acc="$(jq -c --argjson a "$acc" '$a + .results' <<<"$page")"
    [[ "$(jq -r '.has_more' <<<"$page")" == "true" ]] || break
    cursor="$(jq -r '.next_cursor' <<<"$page")"
  done
  printf '%s\n' "$acc"
}

# --- Desired schema (docs/notion/model.md §5) ----------------------------------------------

# Select options: name|color, in display order.
opts() {
  printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("|")
    | {name: .[0], color: .[1]})'
}
STATUS_OPTS="$(opts "Draft|default" "Backlog|gray" "Refining|purple" "Ready|blue" "Developing|yellow" \
  "Review|orange" "Iteration|pink" "Human validation|red" "Done|green" "Closed|brown")"
PRIORITY_OPTS="$(opts "Low|gray" "Medium|blue" "High|orange" "Urgent|red")"
INTEGRATION_OPTS="$(opts "Pending|yellow" "OK|green" "Error|red")"
ATTENTION_OPTS="$(opts "Needs clarification|yellow" "Blocked|orange" "Max iterations|pink" "Failed|red")"

# Scalar properties, created with the database. Relations come after (they need data source IDs).
PROJECTS_PROPS='{
  "Name": {"title": {}},
  "Owners": {"people": {}},
  "Active": {"checkbox": {}},
  "Description": {"rich_text": {}},
  "Documentation": {"url": {}},
  "GitHub Project": {"url": {}}
}'
REPOSITORIES_PROPS='{
  "Name": {"title": {}},
  "GitHub repository": {"rich_text": {}},
  "FlowForge enabled": {"checkbox": {}}
}'
NEEDS_PROPS="$(jq -n --argjson st "$STATUS_OPTS" --argjson pr "$PRIORITY_OPTS" \
  --argjson in "$INTEGRATION_OPTS" --argjson at "$ATTENTION_OPTS" '{
  "Title": {"title": {}},
  "Need": {"rich_text": {}},
  "Requested by": {"people": {}},
  "Created by": {"created_by": {}},
  "Priority": {"select": {"options": $pr}},
  "Submit": {"checkbox": {}},
  "FlowForge Status": {"select": {"options": $st}},
  "GitHub Issue": {"url": {}},
  "Pull request": {"url": {}},
  "Integration status": {"select": {"options": $in}},
  "Integration message": {"rich_text": {}},
  "Attention": {"select": {"options": $at}},
  "Completed at": {"date": {}},
  "Need ID": {"unique_id": {"prefix": "NEED"}},
  "Last synced": {"date": {}},
  "Business reason": {"rich_text": {}},
  "Context": {"files": {}}
}')"

# --- Parent page ---------------------------------------------------------------------------

if [[ -n "${NOTION_PARENT_PAGE_ID:-}" ]]; then
  parent_id="$NOTION_PARENT_PAGE_ID"
elif [[ -f "$CONFIG_FILE" ]]; then
  parent_id="$(jq -r '.parent_page_id' "$CONFIG_FILE")"
else
  pages="$(api POST /search "$(jq -n --arg q "$PARENT_TITLE" \
    '{query: $q, filter: {property: "object", value: "page"}, page_size: 100}')")"
  parents="$(jq -c --arg t "$PARENT_TITLE" '[.results[]
    | select(.in_trash | not)
    | select(([.properties[]? | select(.type == "title") | .title[].plain_text] | join("")) == $t)]' <<<"$pages")"
  case "$(jq 'length' <<<"$parents")" in
    0) die "no page titled '$PARENT_TITLE' visible to the token" ;;
    1) parent_id="$(jq -r '.[0].id' <<<"$parents")" ;;
    *) die "several pages titled '$PARENT_TITLE': set NOTION_PARENT_PAGE_ID to the right one" ;;
  esac
fi
parent="$(api GET "/pages/$parent_id")"
[[ "$(jq -r '.in_trash' <<<"$parent")" == "false" ]] || die "parent page $parent_id is in the trash"
parent_id="$(jq -r '.id' <<<"$parent")"
log "Parent page: $(jq -r '.url' <<<"$parent")"

# Prints the ID of the child database titled $1 under the parent page, or nothing.
find_database() {
  local found
  found="$(api_all "/blocks/$parent_id/children?page_size=100" \
    | jq -c --arg t "$1" '[.[] | select(.type == "child_database" and .child_database.title == $t) | .id]')"
  case "$(jq 'length' <<<"$found")" in
    0) ;;
    1) jq -r '.[0]' <<<"$found" ;;
    *) die "several databases titled '$1' under the parent page" ;;
  esac
}

# Prints {database_id, data_source_id, url} for database $1, creating it with properties $2.
ensure_database() {
  local title="$1" props="$2" db_id db
  db_id="$(find_database "$title")"
  if [[ -z "$db_id" ]]; then
    if $CHECK; then
      drift "database '$title' missing"
      return 0
    fi
    log "Creating database '$title'"
    db_id="$(api POST /databases "$(jq -n --arg p "$parent_id" --arg t "$title" --argjson props "$props" '{
        parent: {type: "page_id", page_id: $p},
        title: [{type: "text", text: {content: $t}}],
        initial_data_source: {properties: $props}
      }')" | jq -r '.id')"
  fi
  db="$(api GET "/databases/$db_id")"
  [[ "$(jq '.data_sources | length' <<<"$db")" == 1 ]] \
    || die "database '$title' must have exactly one data source (model §4)"
  jq -c '{database_id: .id, data_source_id: .data_sources[0].id, url}' <<<"$db"
}

projects="$(ensure_database "FlowForge Projects" "$PROJECTS_PROPS")"
repositories="$(ensure_database "FlowForge Repositories" "$REPOSITORIES_PROPS")"
needs="$(ensure_database "FlowForge Needs" "$NEEDS_PROPS")"
if [[ -z "$projects" || -z "$repositories" || -z "$needs" ]]; then
  log "Check: missing database(s), nothing else checked."
  exit 1
fi
ds() { jq -r '.data_source_id' <<<"$1"; }

# Relations (model §6). dual_property creates the reverse property on the target data source.
rel() { jq -n --arg d "$1" --arg s "$2" '{relation: {data_source_id: $d, type: "dual_property", dual_property: {synced_property_name: $s}}}'; }
REPOSITORIES_PROPS="$(jq --argjson r "$(rel "$(ds "$projects")" "Repositories")" '. + {"Project": $r}' <<<"$REPOSITORIES_PROPS")"
NEEDS_PROPS="$(jq --argjson p "$(rel "$(ds "$projects")" "Needs")" \
  --argjson r "$(rel "$(ds "$repositories")" "Needs")" \
  --arg self "$(ds "$needs")" '. + {
    "Project": $p,
    "Target repository": $r,
    "Related needs": {relation: {data_source_id: $self, type: "single_property", single_property: {}}}
  }' <<<"$NEEDS_PROPS")"
# Reverse sides: created by the relations above, so only checked here (empty relation = reverse).
PROJECTS_PROPS="$(jq '. + {"Repositories": {relation: {}}, "Needs": {relation: {}}}' <<<"$PROJECTS_PROPS")"
REPOSITORIES_PROPS="$(jq '. + {"Needs": {relation: {}}}' <<<"$REPOSITORIES_PROPS")"

# --- Properties ----------------------------------------------------------------------------

# Converges data source $1 (named $2) to the properties $3: adds missing ones and missing select
# options; reports type mismatches, wrong relation targets, missing reverse relations and extras,
# unless $4 is "add-only".
ensure_properties() {
  local ds_id="$1" name="$2" desired="$3" mode="${4:-}" current add
  current="$(api GET "/data_sources/$ds_id" | jq -c '.properties')"

  [[ "$mode" == "add-only" ]] || while IFS= read -r msg; do drift "$name: $msg"; done < <(jq -r --argjson want "$desired" '
    . as $have
    | (($want | to_entries[]) as $w
    | ($w.value | keys[0]) as $type
    | $have[$w.key] as $h
    | if $h == null then (if $w.value.relation == {} then "reverse relation \($w.key) missing" else empty end)
      elif $h.type != $type then "property \($w.key) is \($h.type), want \($type) (fix by hand)"
      elif $type == "relation" and ($w.value.relation.data_source_id // $h.relation.data_source_id) != $h.relation.data_source_id
        then "relation \($w.key) targets another data source"
      elif $type == "relation" and ($w.value.relation.type // $h.relation.type) != $h.relation.type
        then "relation \($w.key) is \($h.relation.type), want \($w.value.relation.type)"
      elif $type == "unique_id" and $h.unique_id.prefix != $w.value.unique_id.prefix
        then "property \($w.key) prefix is \($h.unique_id.prefix), want \($w.value.unique_id.prefix)"
      elif $type == "select" and ([$h.select.options[].name] != [$w.value.select.options[].name])
        then "select \($w.key) options \([$h.select.options[].name]), want \([$w.value.select.options[].name])"
      else empty end),
    ($have | keys[] | select(. as $k | $want | has($k) | not) | "extra property \(.) (not in the model)")
  ' <<<"$current")

  # Missing properties (reverse relations excluded) and select options the schema lacks.
  add="$(jq -c --argjson want "$desired" '. as $have | $want | with_entries(
      select(.value.relation == {} | not)
      | select($have[.key] == null
        or (.value.select != null and $have[.key].type == "select"
          and ([.value.select.options[].name] - [$have[.key].select.options[].name] | length > 0))))' <<<"$current")"
  [[ "$add" == "{}" ]] && return 0
  if $CHECK; then
    while IFS= read -r p; do drift "$name: property $p missing or incomplete"; done < <(jq -r 'keys[]' <<<"$add")
    return 0
  fi
  log "$name: adding $(jq -r 'keys | join(", ")' <<<"$add")"
  api PATCH "/data_sources/$ds_id" "$(jq -n --argjson p "$add" '{properties: $p}')" >/dev/null
}

# Apply: first add what is missing without expecting reverse sides, which the relations of
# Repositories and Needs create; then every data source is checked against its full schema.
if ! $CHECK; then
  no_reverse='with_entries(select(.value.relation != {}))'
  ensure_properties "$(ds "$repositories")" "FlowForge Repositories" "$(jq "$no_reverse" <<<"$REPOSITORIES_PROPS")" add-only
  ensure_properties "$(ds "$needs")" "FlowForge Needs" "$(jq "$no_reverse" <<<"$NEEDS_PROPS")" add-only
fi
ensure_properties "$(ds "$projects")" "FlowForge Projects" "$PROJECTS_PROPS"
ensure_properties "$(ds "$repositories")" "FlowForge Repositories" "$REPOSITORIES_PROPS"
ensure_properties "$(ds "$needs")" "FlowForge Needs" "$NEEDS_PROPS"

# --- Views of FlowForge Needs (model §18) --------------------------------------------------

needs_schema="$(api GET "/data_sources/$(ds "$needs")" | jq -c '.properties')"
pid() { jq -r --arg n "$1" '.[$n].id // error("no property \($n)")' <<<"$needs_schema"; }

# Column list: the named properties visible, in that order, every other one hidden.
columns() {
  jq -c --arg names "$1" '($names | split(",")) as $v
    | [($v[] as $n | .[$n] | {property_id: .id, visible: true}),
       (to_entries[] | select(.key as $k | $v | index($k) | not) | {property_id: .value.id, visible: false})]' <<<"$needs_schema"
}

VIEWS="$(jq -n \
  --argjson all "$(columns "Title,Need ID,Project,Target repository,Requested by,Priority,FlowForge Status,Integration status,GitHub Issue")" \
  --argjson board "$(columns "Title,Need ID,Target repository,Priority,Attention")" \
  --argjson attn "$(columns "Title,Need ID,Target repository,Submit,FlowForge Status,Attention,Integration status,Integration message,GitHub Issue,Pull request")" \
  --arg project "$(pid Project)" --arg repo "$(pid "Target repository")" --arg status "$(pid "FlowForge Status")" '
  {property: "Need ID", direction: "descending"} as $recent
  | [
    {name: "All Needs", type: "table", sorts: [$recent], configuration: {type: "table", properties: $all}},
    {name: "My Needs", type: "table", sorts: [$recent],
     filter: {or: [{property: "Created by", created_by: {contains: "me"}},
                   {property: "Requested by", people: {contains: "me"}}]},
     configuration: {type: "table", properties: $all}},
    {name: "By Project", type: "table", sorts: [$recent],
     configuration: {type: "table", properties: $all,
       group_by: {type: "relation", property_id: $project, sort: {type: "ascending"}, hide_empty_groups: true}}},
    {name: "By Repository", type: "table", sorts: [$recent],
     configuration: {type: "table", properties: $all,
       group_by: {type: "relation", property_id: $repo, sort: {type: "ascending"}, hide_empty_groups: true}}},
    {name: "FlowForge Board", type: "board",
     configuration: {type: "board", properties: $board,
       group_by: {type: "select", property_id: $status, sort: {type: "manual"}, hide_empty_groups: false}}},
    {name: "Needs attention", type: "table", sorts: [$recent],
     filter: {or: [
       {and: [{property: "Submit", checkbox: {equals: true}}, {property: "GitHub Issue", url: {is_empty: true}}]},
       {property: "Attention", select: {is_not_empty: true}},
       {property: "FlowForge Status", select: {equals: "Human validation"}},
       {property: "Integration status", select: {equals: "Error"}}]},
     configuration: {type: "table", properties: $attn}}
  ]')"

URLDECODE='def urldecode: if . == null then . else gsub("%(?<h>[0-9A-Fa-f]{2})";
  .h | ascii_downcase | explode | map(if . >= 97 then . - 87 else . - 48 end) | [.[0] * 16 + .[1]] | implode) end;'
needs_db="$(jq -r '.database_id' <<<"$needs")"
list_views() {
  api_all "/views?database_id=$needs_db&page_size=100" | jq -r '.[].id' \
    | while IFS= read -r id; do api GET "/views/$id"; done | jq -s -c '.'
}
views="$(list_views)"

# A new database comes with one default table view: reuse it as the first view.
default_view="$(jq -r --argjson want "$VIEWS" 'if length == 1 and (.[0].name as $n | $want | map(.name) | index($n) | not)
  then .[0].id else "" end' <<<"$views")"

while IFS= read -r spec; do
  name="$(jq -r '.name' <<<"$spec")"
  matches="$(jq -c --arg n "$name" '[.[] | select(.name == $n)]' <<<"$views")"
  case "$(jq 'length' <<<"$matches")" in
    0)
      if $CHECK; then
        drift "view '$name' missing"
      elif [[ -n "$default_view" && "$(jq -r '.type' <<<"$spec")" == "table" ]]; then
        log "Renaming the default view to '$name'"
        api PATCH "/views/$default_view" "$(jq -c 'del(.type)' <<<"$spec")" >/dev/null
        default_view=""
      else
        log "Creating view '$name'"
        api POST /views "$(jq -c --arg db "$needs_db" --arg ds "$(ds "$needs")" \
          '. + {database_id: $db, data_source_id: $ds}' <<<"$spec")" >/dev/null
      fi
      ;;
    1)
      # Layout, grouping and filter presence are compared; Notion normalises filter bodies, and
      # returns property IDs URL-decoded in views but URL-encoded in schemas.
      have="$(jq -c "$URLDECODE"' .[0] | {type, group: (.configuration.group_by.property_id // null | urldecode), filtered: (.filter != null)}' <<<"$matches")"
      want="$(jq -c "$URLDECODE"' {type, group: (.configuration.group_by.property_id // null | urldecode), filtered: (.filter != null)}' <<<"$spec")"
      if [[ "$have" != "$want" ]]; then
        if $CHECK || [[ "$(jq -r '.type' <<<"$have")" != "$(jq -r '.type' <<<"$want")" ]]; then
          drift "view '$name' is $have, want $want"
        else
          log "Updating view '$name'"
          api PATCH "/views/$(jq -r '.[0].id' <<<"$matches")" "$(jq -c 'del(.type)' <<<"$spec")" >/dev/null
        fi
      fi
      ;;
    *) drift "several views named '$name'" ;;
  esac
done < <(jq -c '.[]' <<<"$VIEWS")

$CHECK || views="$(list_views)"
while IFS= read -r extra; do
  drift "extra view '$extra' on FlowForge Needs (not in the model)"
done < <(jq -r --argjson want "$VIEWS" '.[].name | select(. as $n | $want | map(.name) | index($n) | not)' <<<"$views")

# --- Not settable through the API: reported on every run -----------------------------------

manual "relations 'Project', 'Target repository' (Needs) and 'Project' (Repositories): limit to 1 page (property → Limit)"
manual "sharing: contributors 'Can view' on Projects and Repositories, 'Can edit content' on Needs (provisioning.md §6)"

# --- IDs for Prompts 33/34 -----------------------------------------------------------------

describe() {
  local db="$1" schema
  schema="$(api GET "/data_sources/$(ds "$db")" | jq -c '.properties')"
  jq -c --argjson s "$schema" '. + {properties: ($s | with_entries(.value = .value.id))}' <<<"$db"
}
config="$(jq -n --arg page "$parent_id" --arg version "$NOTION_VERSION" \
  --argjson p "$(describe "$projects")" --argjson r "$(describe "$repositories")" \
  --argjson n "$(describe "$needs")" --argjson v "$views" '{
    notion_version: $version,
    parent_page_id: $page,
    databases: {
      "FlowForge Projects": $p,
      "FlowForge Repositories": $r,
      "FlowForge Needs": ($n + {views: ($v | map({key: .name, value: .id}) | from_entries)})
    }
  }')"

if $CHECK; then
  if [[ ! -f "$CONFIG_FILE" ]] || ! diff -q <(jq -S . "$CONFIG_FILE") <(jq -S . <<<"$config") >/dev/null; then
    drift "$CONFIG_FILE is missing or differs from Notion (re-run without --check)"
  fi
  if ((DRIFT > 0)); then
    log "Check: $DRIFT drift(s)."
    exit 1
  fi
  log "Check: Notion space conforms to the model."
else
  mkdir -p "$(dirname "$CONFIG_FILE")"
  jq . <<<"$config" >"$CONFIG_FILE"
  log "Wrote $CONFIG_FILE"
  ((DRIFT == 0)) || log "Done, with $DRIFT drift(s) to fix by hand."
fi
