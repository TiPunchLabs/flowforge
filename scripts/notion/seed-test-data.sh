#!/usr/bin/env bash
# FlowForge — minimal test data for the Notion space (Phase 7, Prompt 32).
#
#   seed-test-data.sh       create the missing test rows (2 Projects, 3 Repositories, 4 Needs)
#
# Shape (docs/notion/provisioning.md §7):
#   Test Project A ── test-repo-a, test-repo-b        Test Project B ── test-repo-c
# plus one deliberately inconsistent Need (Test Project A → test-repo-c) that Notion accepts
# and that Prompt 33 must reject.
#
# Safe by construction: every test repository has "FlowForge enabled" unticked and points to a
# repository that does not exist, no row has a GitHub Issue, and nothing here calls GitHub.
# Idempotent: rows are found by exact title, never created twice. Person fields are set to the
# creator of the parent page (the maintainer); no user list is read.
#
# Requires curl, jq, NOTION_TOKEN and config/notion.json (written by bootstrap.sh).
set -euo pipefail

NOTION_API="https://api.notion.com/v1"
CONFIG_FILE="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/config/notion.json"

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

case "${1:-}" in
  "") ;;
  -h | --help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown argument: $1" ;;
esac

[[ -n "${NOTION_TOKEN:-}" ]] || die "NOTION_TOKEN is not set"
[[ -f "$CONFIG_FILE" ]] || die "$CONFIG_FILE missing: run scripts/notion/bootstrap.sh first"
NOTION_VERSION="$(jq -r '.notion_version' "$CONFIG_FILE")"

# Same contract as bootstrap.sh: api METHOD PATH [JSON_BODY], token never on a command line.
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

ds() { jq -r --arg d "$1" '.databases[$d].data_source_id' "$CONFIG_FILE"; }
PROJECTS_DS="$(ds "FlowForge Projects")"
REPOSITORIES_DS="$(ds "FlowForge Repositories")"
NEEDS_DS="$(ds "FlowForge Needs")"
MAINTAINER="$(api GET "/pages/$(jq -r '.parent_page_id' "$CONFIG_FILE")" | jq -r '.created_by.id')"

# Prints the page ID of the row titled $2 (title property $3) in data source $1, creating it
# with the properties $4 (JSON, title excluded) when absent.
ensure_row() {
  local ds_id="$1" title="$2" title_prop="$3" props="$4" found
  found="$(api POST "/data_sources/$ds_id/query" "$(jq -n --arg p "$title_prop" --arg t "$title" \
    '{filter: {property: $p, title: {equals: $t}}, page_size: 10}')" | jq -r '[.results[].id]')"
  case "$(jq 'length' <<<"$found")" in
    0)
      log "Creating '$title'"
      api POST /pages "$(jq -n --arg d "$ds_id" --arg p "$title_prop" --arg t "$title" --argjson props "$props" '{
          parent: {type: "data_source_id", data_source_id: $d},
          properties: ($props + {($p): {title: [{text: {content: $t}}]}})
        }')" | jq -r '.id'
      ;;
    1) log "Exists: '$title'"; jq -r '.[0]' <<<"$found" ;;
    *) die "several rows titled '$title'" ;;
  esac
}

text() { jq -n --arg t "$1" '{rich_text: [{text: {content: $t}}]}'; }
link() { jq -n --arg id "$1" '{relation: [{id: $id}]}'; }
me="$(jq -n --arg id "$MAINTAINER" '{people: [{id: $id}]}')"

project() {
  ensure_row "$PROJECTS_DS" "$1" "Name" "$(jq -n --argjson me "$me" --argjson d "$(text "$2")" \
    '{Owners: $me, Active: {checkbox: true}, Description: $d}')"
}
repository() {
  ensure_row "$REPOSITORIES_DS" "$1" "Name" "$(jq -n --argjson r "$(text "TiPunchLabs/$1")" --argjson p "$(link "$2")" \
    '{"GitHub repository": $r, "FlowForge enabled": {checkbox: false}, Project: $p}')"
}
# need TITLE PROJECT_ID REPOSITORY_ID PRIORITY SUBMIT NEED_TEXT
need() {
  ensure_row "$NEEDS_DS" "$1" "Title" "$(jq -n --argjson me "$me" --argjson p "$(link "$2")" --argjson r "$(link "$3")" \
    --arg prio "$4" --argjson submit "$5" --argjson n "$(text "$6")" '{
      Need: $n, Project: $p, "Target repository": $r, "Requested by": $me,
      Priority: {select: {name: $prio}}, Submit: {checkbox: $submit},
      "FlowForge Status": {select: {name: "Draft"}}
    }')" >/dev/null
}

project_a="$(project "Test Project A" "Prompt 32 test data: two repositories. Never submitted.")"
project_b="$(project "Test Project B" "Prompt 32 test data: one repository. Never submitted.")"
repo_a="$(repository "test-repo-a" "$project_a")"
repo_b="$(repository "test-repo-b" "$project_a")"
repo_c="$(repository "test-repo-c" "$project_b")"

need "Test — paginate the task list" "$project_a" "$repo_a" Medium false \
  "When there are many tasks the list is slow and hard to read. I would like to see them page by page."
need "Test — add a health endpoint" "$project_a" "$repo_b" High true \
  "Our monitoring needs a simple way to know whether the service is up."
need "Test — export candidates as CSV" "$project_b" "$repo_c" Low false \
  "I want to download the candidate list to open it in a spreadsheet."
need "Test — inconsistent target (Project A → test-repo-c)" "$project_a" "$repo_c" Medium false \
  "Deliberately inconsistent: test-repo-c belongs to Test Project B. Notion accepts it; Prompt 33 must reject it."

log "Test data ready."
