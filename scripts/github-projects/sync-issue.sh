#!/usr/bin/env bash
# GraphQL documents are single-quoted on purpose: their $variables are GraphQL, not shell.
# shellcheck disable=SC2016
# FlowForge — apply one sync event to an Issue's card by hand (Phase 6, Prompt 28).
#
# Runs the SAME helper as the workflows (.github/scripts/flowforge-project.sh), with the
# maintainer's gh login instead of the FlowForge App token, in strict mode (any error exits 1).
# Uses: integration test of the sync on a real Project, manual entry of an Issue (issue-added),
# repair of a card after a failed sync (--force bypasses the stale guard).
#
#   sync-issue.sh <owner/repo> <issue> <event> [--force]   apply the event, print the transition
#   sync-issue.sh <owner/repo> <issue> --show              print the card (Status, Attention)
#   sync-issue.sh --events                                 list the events
#
# Never moves a card in a way that starts anything: Project changes trigger no workflow.
# Requires gh (scope `project`; `read:project` for --show), jq. No token is read or written
# here: gh uses its own credential store or GH_TOKEN from the environment.
set -euo pipefail

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
config="$root/config/github-project.json"
# shellcheck source=/dev/null
source "$root/.github/scripts/flowforge-project.sh"

usage() { sed -n '/^#   sync-issue.sh/s/^#   //p' "$0" >&2; exit 2; }

if [[ "${1:-}" == --events ]]; then
  jq -r 'to_entries[] | "\(.key)\t→ \(.value.status // "(status kept)")\(if .value.attention != "" then " + \(.value.attention)" else "" end)\tfrom: \(.value.from | map(if . == "" then "(none)" else . end) | join(", "))"' \
    <<<"$FLOWFORGE_PROJECT_EVENTS" | column -t -s $'\t'
  exit 0
fi
(( $# >= 3 )) || usage
repo="$1" issue="$2" event="$3"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Invalid repository '$repo'." >&2; exit 2; }

if [[ "$event" == --show ]]; then
  gh api graphql -F owner="${repo%/*}" -F name="${repo#*/}" -F number="$issue" -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issue(number: $number) {
          projectItems(first: 20, includeArchived: true) {
            nodes {
              id isArchived project { number owner { ... on Organization { login } } }
              status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
              attention: fieldValueByName(name: "Attention") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
            }
          }
        }
      }
    }' | jq -c --arg owner "$(jq -r .owner "$config")" --argjson number "$(jq .number "$config")" '
      [.data.repository.issue.projectItems.nodes[]
       | select(.project.number == $number and .project.owner.login == $owner)
       | {item: .id, archived: .isArchived, status: (.status.name // ""), attention: (.attention.name // "")}]'
  exit 0
fi

force=""
[[ "${4:-}" == --force ]] && force=1
token="$(gh auth token)"
GITHUB_REPOSITORY="$repo" GH_TOKEN="$token" PROJECT_TOKEN="$token" \
  PROJECT_NUMBER="$(jq -r .number "$config")" FLOWFORGE_PROJECT_CONFIG="$config" \
  FLOWFORGE_PROJECT_FORCE="$force" FLOWFORGE_PROJECT_STRICT=1 GITHUB_STEP_SUMMARY="" \
  bash -c 'source "$1"; flowforge_project_sync "$2" "$3"' _ \
  "$root/.github/scripts/flowforge-project.sh" "$issue" "$event"
