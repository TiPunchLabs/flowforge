#!/usr/bin/env bash
# GraphQL documents are single-quoted on purpose: their $variables are GraphQL, not shell.
# shellcheck disable=SC2016
# FlowForge — provision the GitHub Project "FlowForge Development" (Phase 6, Prompt 27).
#
# Desired state: docs/github-projects/kanban-model.md (§2–§4, §14), as provisioned in
# docs/github-projects/provisioning.md. The GraphQL API cannot set a view's grouping nor turn
# built-in workflows on or off: those stay manual UI steps, reported by --check.
#
#   bootstrap.sh            create or converge the Project, then write config/github-project.json
#   bootstrap.sh --check    read-only: report drift between GitHub and the model, exit 1 on drift
#
# Idempotent: a second run on a conform Project makes no write call. The Project is found by
# its exact title; two open Projects with that title is an error, never a guess.
#
# Requires gh (scope `project`, plus `read:org`), jq. No token is read or written here: gh uses
# its own credential store or GH_TOKEN from the environment.
set -euo pipefail

OWNER="TiPunchLabs"
TITLE="FlowForge Development"
SHORT_DESCRIPTION="FlowForge: where each agent-driven Issue stands. Visual only: labels and Actions runs are the source of truth of execution; moving a card never starts an agent."
CONFIG_FILE="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/config/github-project.json"

# name|color|description — order is the board's column order.
STATUS_OPTIONS=(
  "Backlog|GRAY|Raw need, or parked: waits for the requester or a human decision (see Attention)"
  "Refining|PURPLE|A Refiner run is in progress"
  "Ready|BLUE|Executable Issue: waits for the human go (label agent:ready)"
  "Developing|YELLOW|The Developer works on the Issue"
  "Review|ORANGE|Draft PR delivered: agent review pending or running"
  "Iteration|PINK|The Iterator fixes the Reviewer findings (max 3 per cycle)"
  "Human validation|RED|Agents are done: a human approves and merges, re-runs, or abandons"
  "Done|GREEN|Merged by a human, or Issue closed as completed. Terminal"
)
ATTENTION_OPTIONS=(
  "Needs clarification|YELLOW|Refiner asked questions: the requester must answer"
  "Blocked|ORANGE|An agent returned BLOCKED: a human decision is required"
  "Max iterations|PINK|Review cycle spent its iteration budget without APPROVE"
  "Failed|RED|Technical failure of a FlowForge run: see the Actions run, then re-run"
)
PRIORITY_OPTIONS=(
  "P0|RED|Critical"
  "P1|ORANGE|High"
  "P2|YELLOW|Normal"
  "P3|GRAY|Low"
)
# name|layout|filter|visible fields (comma-separated field names; built-in names as on GitHub)
VIEWS=(
  "Board|BOARD_LAYOUT||Title,Attention,Priority,Linked pull requests"
  "Attention|TABLE_LAYOUT|-no:attention|Title,Status,Attention,Repository,Linked pull requests"
  "By repository|TABLE_LAYOUT||Title,Status,Attention,Priority,Repository,Labels,Linked pull requests"
)

CHECK=false
DRIFT=0

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
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

# Runs the GraphQL document $1 with the JSON variables $2; prints .data, fails on any error.
gql() {
  local out
  out="$(jq -n --arg q "$1" --argjson v "${2:-{\}}" '{query: $q, variables: $v}' \
    | gh api graphql --input - 2>&1)" || die "GraphQL call failed: $out"
  if jq -e '.errors? // empty | length > 0' <<<"$out" >/dev/null; then
    die "GraphQL errors: $(jq -c '.errors' <<<"$out")"
  fi
  jq '.data' <<<"$out"
}

# Prints the desired options $@ ("name|color|description") as a JSON array.
options_json() {
  printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("|")
    | {name: .[0], color: .[1], description: .[2]})'
}

PROJECT_QUERY='query($owner: String!, $title: String!) {
  organization(login: $owner) {
    id
    projectsV2(first: 20, query: $title) { nodes { id number title closed } }
  }
}'

PROJECT_STATE_QUERY='query($id: ID!) {
  node(id: $id) {
    ... on ProjectV2 {
      id number title url public shortDescription
      fields(first: 50) {
        nodes {
          ... on ProjectV2FieldCommon { id name dataType }
          ... on ProjectV2SingleSelectField { options { id name color description } }
        }
      }
      views(first: 20) {
        nodes {
          id number name layout filter
          fields(first: 30) { nodes { ... on ProjectV2FieldCommon { id name } } }
          verticalGroupByFields(first: 5) { nodes { ... on ProjectV2FieldCommon { name } } }
          groupByFields(first: 5) { nodes { ... on ProjectV2FieldCommon { name } } }
        }
      }
      workflows(first: 20) { nodes { id number name enabled } }
      items(first: 100) {
        totalCount
        nodes {
          fieldValues(first: 20) {
            nodes { ... on ProjectV2ItemFieldSingleSelectValue { optionId } }
          }
        }
      }
    }
  }
}'

project_state() {
  gql "$PROJECT_STATE_QUERY" "$(jq -n --arg id "$1" '{id: $id}')" | jq '.node'
}

# --- Project -----------------------------------------------------------------------------

found="$(gql "$PROJECT_QUERY" "$(jq -n --arg o "$OWNER" --arg t "$TITLE" '{owner: $o, title: $t}')")"
owner_id="$(jq -r '.organization.id' <<<"$found")"
matches="$(jq -c --arg t "$TITLE" '[.organization.projectsV2.nodes[] | select(.title == $t and (.closed | not))]' <<<"$found")"
case "$(jq 'length' <<<"$matches")" in
  0)
    if $CHECK; then
      drift "no open Project titled '$TITLE' in $OWNER"
      exit 1
    fi
    log "Creating Project '$TITLE' in $OWNER"
    project_id="$(gql 'mutation($owner: ID!, $title: String!) {
        createProjectV2(input: {ownerId: $owner, title: $title}) { projectV2 { id } }
      }' "$(jq -n --arg o "$owner_id" --arg t "$TITLE" '{owner: $o, title: $t}')" \
      | jq -r '.createProjectV2.projectV2.id')"
    ;;
  1) project_id="$(jq -r '.[0].id' <<<"$matches")" ;;
  *) die "several open Projects titled '$TITLE' in $OWNER: $(jq -c 'map(.number)' <<<"$matches"); resolve by hand" ;;
esac

state="$(project_state "$project_id")"
log "Project #$(jq -r '.number' <<<"$state"): $(jq -r '.url' <<<"$state")"

if [[ "$(jq -r '.public' <<<"$state")" != "false" \
  || "$(jq -r '.shortDescription // ""' <<<"$state")" != "$SHORT_DESCRIPTION" ]]; then
  if $CHECK; then
    drift "Project must be private with the reference short description"
  else
    log "Setting visibility (private) and short description"
    gql 'mutation($id: ID!, $d: String!) {
        updateProjectV2(input: {projectId: $id, public: false, shortDescription: $d}) { projectV2 { id } }
      }' "$(jq -n --arg id "$project_id" --arg d "$SHORT_DESCRIPTION" '{id: $id, d: $d}')" >/dev/null
  fi
fi

# --- Single-select fields ----------------------------------------------------------------

# Converges the single-select field $1 to the options $2... (created if missing, except
# Status which is built in). Option IDs are preserved by name, so item values survive. An
# option to drop that still holds items is an error: the values would be silently cleared.
ensure_single_select() {
  local name="$1"
  shift
  local desired field current used update
  desired="$(options_json "$@")"
  field="$(jq -c --arg n "$name" '.fields.nodes[] | select(.name == $n)' <<<"$state")"

  if [[ -z "$field" ]]; then
    [[ "$name" == "Status" ]] && die "built-in field Status not found"
    if $CHECK; then
      drift "field '$name' missing"
      return
    fi
    log "Creating field '$name'"
    gql 'mutation($p: ID!, $n: String!, $o: [ProjectV2SingleSelectFieldOptionInput!]!) {
        createProjectV2Field(input: {projectId: $p, dataType: SINGLE_SELECT, name: $n, singleSelectOptions: $o}) {
          projectV2Field { ... on ProjectV2FieldCommon { id } }
        }
      }' "$(jq -n --arg p "$project_id" --arg n "$name" --argjson o "$desired" '{p: $p, n: $n, o: $o}')" >/dev/null
    return
  fi

  [[ "$(jq -r '.dataType' <<<"$field")" == "SINGLE_SELECT" ]] \
    || die "field '$name' exists but is $(jq -r '.dataType' <<<"$field"), expected SINGLE_SELECT"
  [[ "$(jq --arg n "$name" '[.fields.nodes[] | select(.name == $n)] | length' <<<"$state")" == 1 ]] \
    || die "several fields named '$name'"

  current="$(jq -c '[.options[] | {name, color, description}]' <<<"$field")"
  [[ "$current" == "$desired" ]] && return

  if $CHECK; then
    drift "field '$name' options: have $(jq -c 'map(.name)' <<<"$current"), want $(jq -c 'map(.name)' <<<"$desired")"
    return
  fi

  used="$(jq -c --argjson f "$field" --argjson d "$desired" '
      [$f.options[] | select(.name as $n | $d | map(.name) | index($n) | not) | .id] as $dropped
      | [.items.nodes[].fieldValues.nodes[].optionId? | select(. != null and ($dropped | index(.)))]
      | unique' <<<"$state")"
  [[ "$used" == "[]" ]] || die "field '$name': options to remove still hold items ($used); move them first"

  update="$(jq -c --argjson f "$field" \
    'map(. as $o | . + ([$f.options[] | select(.name == $o.name) | {id}] | first // {}))' <<<"$desired")"
  log "Updating options of field '$name'"
  gql 'mutation($f: ID!, $o: [ProjectV2SingleSelectFieldOptionInput!]!) {
      updateProjectV2Field(input: {fieldId: $f, singleSelectOptions: $o}) {
        projectV2Field { ... on ProjectV2FieldCommon { id } }
      }
    }' "$(jq -n --arg f "$(jq -r '.id' <<<"$field")" --argjson o "$update" '{f: $f, o: $o}')" >/dev/null
}

ensure_single_select "Status" "${STATUS_OPTIONS[@]}"
ensure_single_select "Attention" "${ATTENTION_OPTIONS[@]}"
ensure_single_select "Priority" "${PRIORITY_OPTIONS[@]}"
$CHECK || state="$(project_state "$project_id")"

# --- Views -------------------------------------------------------------------------------

# Prints the IDs of the fields named in the comma-separated list $1, as a JSON array.
field_ids() {
  jq -c --arg names "$1" '($names | split(",")) as $n
    | [$n[] as $want | .fields.nodes[] | select(.name == $want) | .id]' <<<"$state"
}

for spec in "${VIEWS[@]}"; do
  IFS='|' read -r v_name v_layout v_filter v_fields <<<"$spec"
  view="$(jq -c --arg n "$v_name" '[.views.nodes[] | select(.name == $n)]' <<<"$state")"
  ids="$(field_ids "$v_fields")"
  [[ "$(jq 'length' <<<"$ids")" == "$(awk -F, '{print NF}' <<<"$v_fields")" ]] \
    || die "view '$v_name': some fields of '$v_fields' do not exist on the Project"

  case "$(jq 'length' <<<"$view")" in
    0)
      # A new Project comes with one unnamed default table view: reuse it for the first view.
      default="$(jq -r 'if (.views.nodes | length) == 1 and (.views.nodes[0].name | test("^View [0-9]+$"))
        then .views.nodes[0].id else "" end' <<<"$state")"
      if $CHECK; then
        drift "view '$v_name' missing"
        continue
      fi
      if [[ -n "$default" ]]; then
        log "Renaming the default view to '$v_name'"
        gql 'mutation($v: ID!, $n: String!, $l: ProjectV2ViewLayout!, $f: String!, $ids: [ID!]!) {
            updateProjectV2View(input: {viewId: $v, name: $n, layout: $l, filter: $f, configuration: {visibleFieldIds: $ids}}) {
              projectV2View { id }
            }
          }' "$(jq -n --arg v "$default" --arg n "$v_name" --arg l "$v_layout" --arg f "$v_filter" --argjson ids "$ids" \
          '{v: $v, n: $n, l: $l, f: $f, ids: $ids}')" >/dev/null
      else
        log "Creating view '$v_name'"
        gql 'mutation($p: ID!, $n: String!, $l: ProjectV2ViewLayout!, $ids: [ID!]!) {
            createProjectV2View(input: {projectId: $p, name: $n, layout: $l, configuration: {visibleFieldIds: $ids}}) {
              projectV2View { id }
            }
          }' "$(jq -n --arg p "$project_id" --arg n "$v_name" --arg l "$v_layout" --argjson ids "$ids" \
          '{p: $p, n: $n, l: $l, ids: $ids}')" >/dev/null
        if [[ -n "$v_filter" ]]; then
          new_id="$(project_state "$project_id" | jq -r --arg n "$v_name" '.views.nodes[] | select(.name == $n) | .id')"
          gql 'mutation($v: ID!, $f: String!) {
              updateProjectV2View(input: {viewId: $v, filter: $f}) { projectV2View { id } }
            }' "$(jq -n --arg v "$new_id" --arg f "$v_filter" '{v: $v, f: $f}')" >/dev/null
        fi
      fi
      state="$(project_state "$project_id")"
      ;;
    1)
      v="$(jq -c '.[0]' <<<"$view")"
      if [[ "$(jq -r '.layout' <<<"$v")" != "$v_layout" || "$(jq -r '.filter // ""' <<<"$v")" != "$v_filter" ]]; then
        if $CHECK; then
          drift "view '$v_name': layout/filter $(jq -c '[.layout, .filter]' <<<"$v"), want [\"$v_layout\",\"$v_filter\"]"
        else
          log "Updating view '$v_name'"
          gql 'mutation($v: ID!, $l: ProjectV2ViewLayout!, $f: String!, $ids: [ID!]!) {
              updateProjectV2View(input: {viewId: $v, layout: $l, filter: $f, configuration: {visibleFieldIds: $ids}}) {
                projectV2View { id }
              }
            }' "$(jq -n --arg v "$(jq -r '.id' <<<"$v")" --arg l "$v_layout" --arg f "$v_filter" --argjson ids "$ids" \
            '{v: $v, l: $l, f: $f, ids: $ids}')" >/dev/null
        fi
      fi
      ;;
    *) die "several views named '$v_name'" ;;
  esac
done

# --- Manual UI steps (not settable through the API): reported, never fatal on apply --------

final="$(project_state "$project_id")"

board_group="$(jq -r '[.views.nodes[] | select(.name == "Board") | .verticalGroupByFields.nodes[]?.name] | join(",")' <<<"$final")"
[[ "$board_group" == "Status" ]] || drift "view 'Board' columns are '${board_group:-<none>}', want 'Status' (UI: view menu → Column by)"
repo_group="$(jq -r '[.views.nodes[] | select(.name == "By repository") | .groupByFields.nodes[]?.name] | join(",")' <<<"$final")"
[[ "$repo_group" == "Repository" ]] || drift "view 'By repository' grouped by '${repo_group:-<none>}', want 'Repository' (UI: view menu → Group by)"
while IFS= read -r wf; do
  drift "built-in workflow '$wf' is enabled; FlowForge keeps every built-in workflow off (UI: ⋯ → Workflows)"
done < <(jq -r '.workflows.nodes[] | select(.enabled) | .name' <<<"$final")

# --- IDs for Prompt 28 -------------------------------------------------------------------

config="$(jq --arg owner "$OWNER" '{
    owner: $owner,
    title,
    number,
    url,
    project_id: .id,
    fields: ([.fields.nodes[] | select(.name == "Status" or .name == "Attention" or .name == "Priority")
      | {key: .name, value: {id, options: ([.options[] | {key: .name, value: .id}] | from_entries)}}]
      | from_entries),
    views: ([.views.nodes[] | {key: .name, value: {id, number}}] | from_entries)
  }' <<<"$final")"

if $CHECK; then
  if [[ ! -f "$CONFIG_FILE" ]] || ! diff -q <(jq -S . "$CONFIG_FILE") <(jq -S . <<<"$config") >/dev/null; then
    drift "$CONFIG_FILE is missing or differs from GitHub (re-run without --check)"
  fi
  if ((DRIFT > 0)); then
    log "Check: $DRIFT drift(s)."
    exit 1
  fi
  log "Check: Project conforms to the model."
else
  mkdir -p "$(dirname "$CONFIG_FILE")"
  jq . <<<"$config" >"$CONFIG_FILE"
  log "Wrote $CONFIG_FILE"
  ((DRIFT == 0)) || log "Done, with $DRIFT manual step(s) left: see docs/github-projects/provisioning.md §4."
fi
