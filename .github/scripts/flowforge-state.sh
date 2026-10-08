# shellcheck shell=bash
# FlowForge — Issue state labels. Sourced by the reusable workflows, never run on its own.
#
# The workflows fetch this file from FlowForge at the commit they were called at
# (job.workflow_sha), like the agent rules, so the helper always matches the workflow.
#
# An Issue carries AT MOST ONE FlowForge state label: its current lifecycle state. Labels are
# not a log; history lives in the GitHub timeline, Actions runs, PRs and reviews.
#
#   (none) ──human──► agent:ready ──Developer starts──► agent:running
#   agent:running ──Draft PR──► agent:review        ──no Draft PR──► agent:blocked
#   agent:review  ──cycle BLOCKED / MAX_ITERATIONS_REACHED──► agent:blocked
#   agent:review | agent:blocked ──PR merged──► agent:done
#   agent:review | agent:blocked ──PR closed unmerged──► (none)
#
# See docs/architecture.md §2.6. Requires gh (GH_TOKEN), jq and GITHUB_REPOSITORY.

FLOWFORGE_STATE_LABELS=(agent:ready agent:running agent:review agent:blocked agent:done)

# Prints, as a compact JSON array, the names of all labels the Issue $1 carries.
_flowforge_issue_labels() {
  gh api "repos/$GITHUB_REPOSITORY/issues/$1" | jq -c '[.labels[].name]'
}

# Succeeds if the Issue $1 currently carries at least one of the labels $2...
flowforge_has_state() {
  local issue="$1"
  shift
  _flowforge_issue_labels "$issue" \
    | jq -e --args 'any(.[]; IN($ARGS.positional[]))' "$@" >/dev/null
}

# Moves the Issue $1 to the state label $2, or to no state when $2 is empty. Every other
# FlowForge state label (and each extra label $3...) is removed; $2 is added if missing.
# Labels outside that set are never touched. Idempotent: a replayed transition changes
# nothing and makes no write call. A state label not created on the repository yet (Terraform
# not applied) is not added, with a warning; the stale labels are removed all the same.
flowforge_set_state() {
  local issue="$1" target="$2"
  shift 2
  if [[ ! "$issue" =~ ^[1-9][0-9]*$ ]]; then
    echo "::error::Invalid Issue number '$issue'."
    return 1
  fi
  if [[ -n "$target" ]] && ! printf '%s\n' "${FLOWFORGE_STATE_LABELS[@]}" | grep -Fxq -- "$target"; then
    echo "::error::'$target' is not a FlowForge state label."
    return 1
  fi

  local current label
  local -a remove=() edit=()
  current="$(_flowforge_issue_labels "$issue")"
  for label in "${FLOWFORGE_STATE_LABELS[@]}" "$@"; do
    if [[ -n "$label" && "$label" != "$target" ]] \
      && jq -e --arg l "$label" 'index($l) != null' <<<"$current" >/dev/null \
      && ! printf '%s\n' "${remove[@]}" | grep -Fxq -- "$label"; then
      remove+=("$label")
    fi
  done
  if (( ${#remove[@]} > 0 )); then
    edit+=(--remove-label "$(IFS=,; echo "${remove[*]}")")
  fi

  if [[ -n "$target" ]] && ! jq -e --arg l "$target" 'index($l) != null' <<<"$current" >/dev/null; then
    if gh api --paginate "repos/$GITHUB_REPOSITORY/labels?per_page=100" \
      | jq -s -e --arg l "$target" 'add | any(.[]; .name == $l)' >/dev/null; then
      edit+=(--add-label "$target")
    else
      echo "::warning::Label '$target' does not exist in $GITHUB_REPOSITORY (apply the target-repository Terraform module); Issue #$issue is left without a FlowForge state label."
    fi
  fi

  if (( ${#edit[@]} > 0 )); then
    gh issue edit "$issue" --repo "$GITHUB_REPOSITORY" "${edit[@]}" >/dev/null
  fi
  echo "Issue #$issue: FlowForge state ${target:-none}${remove[*]:+ (removed: ${remove[*]})}."
}

# Prints "<STATE> <ISSUE>" for the pull request $1: its state (OPEN, CLOSED or MERGED) and
# the one Issue of this repository it closes with a closing keyword, or an empty ISSUE when
# there is none or several. The Issue is resolved by GitHub, never parsed from PR text.
flowforge_pr_issue() {
  local pr
  # shellcheck disable=SC2016  # $owner, $name, $number are GraphQL variables
  pr="$(gh api graphql \
    -F owner="${GITHUB_REPOSITORY%/*}" -F name="${GITHUB_REPOSITORY#*/}" -F number="$1" \
    -f query='
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            number state
            closingIssuesReferences(first: 10) { nodes { number repository { nameWithOwner } } }
          }
        }
      }' \
    --jq '.data.repository.pullRequest')"
  if [[ "$(jq -r '.number // empty' <<<"$pr")" != "$1" ]]; then
    echo "::error::Pull request #$1 not found in $GITHUB_REPOSITORY." >&2
    return 1
  fi
  jq -r --arg repo "$GITHUB_REPOSITORY" '
    [.closingIssuesReferences.nodes[] | select(.repository.nameWithOwner == $repo) | .number] as $issues
    | "\(.state) \(if ($issues | length) == 1 then $issues[0] else "" end)"' <<<"$pr"
}
