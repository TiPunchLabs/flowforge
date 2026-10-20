# shellcheck shell=bash
# FlowForge — SPEC.md contract (Phase 8.1). Sourced by agent-develop.yml, never run on its own.
#
# The workflow fetches this file from FlowForge at the commit it was called at
# (job.workflow_sha), like the state helper, so the contract always matches the workflow.
#
# A target repository must hold SPEC.md at its root, on the branch the Developer starts from,
# with four level-2 sections (French or English title; case, accents, emoji, numbering and
# spacing ignored) and at least one behaviour and one validation scenario. The check is structural
# only: it never judges the quality of the specification. See docs/spec-contract.md.
#
#   PASS    the contract holds                          -> the Developer may start
#   FAILED  SPEC.md is absent, empty or incomplete      -> conformity error, fixed in the target
#   ERROR   SPEC.md could not be read (API, rights, ref) -> technical error, never "absent"
#
# Requires gh (GH_TOKEN), tr and awk.

FLOWFORGE_SPEC_FILE=SPEC.md
FLOWFORGE_SPEC_DOC="docs/spec-contract.md in FlowForge"

# key|French title|English title|accepted normalised titles. Normalising is locale-free: non-ASCII
# bytes are dropped, so each French title is listed with its accents removed and with plain letters.
FLOWFORGE_SPEC_SECTIONS=(
  "objective|## 1. Objectif et périmètre|## 1. Objective and scope|objectif et primtre,objectif et perimetre,objective and scope"
  "features|## 2. Fonctionnalités|## 2. Features|fonctionnalits,fonctionnalites,features"
  "rules|## 3. Règles et contraintes|## 3. Rules and constraints|rgles et contraintes,regles et contraintes,rules and constraints"
  "scenarios|## 4. Scénarios de validation|## 4. Validation scenarios|scnarios de validation,scenarios de validation,validation scenarios"
)

# Prints "<key> <present 0|1> <content lines>" for each contract section of the Markdown file
# $1. Content lines are non-blank lines that are neither headings nor HTML comments; fenced
# code is content (a GIVEN/WHEN/THEN block often lives in one) but never a heading.
_flowforge_spec_sections() {
  local names="" entry
  for entry in "${FLOWFORGE_SPEC_SECTIONS[@]}"; do
    names+="${entry%%|*}=${entry##*|};"
  done
  LC_ALL=C tr -d '\200-\377' < "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C awk -v names="$names" '
      BEGIN {
        n = split(names, defs, ";")
        for (i = 1; i <= n; i++) {
          if (defs[i] == "") continue
          split(defs[i], kv, "=")
          keys[++k] = kv[1]
          m = split(kv[2], titles, ",")
          for (j = 1; j <= m; j++) key_of[titles[j]] = kv[1]
        }
      }
      /^ ? ? ?(```|~~~)/ { fence = !fence; next }
      fence { if (cur != "") count[cur]++; next }
      comment { if ($0 ~ /-->/) comment = 0; next }
      /^[ \t]*<!--/ { if ($0 !~ /-->/) { comment = 1; next } if ($0 ~ /-->[ \t]*$/) next }
      /^ ? ? ?##([^#]|$)/ {
        t = $0
        sub(/^ *##/, "", t); gsub(/[^a-z0-9]+/, " ", t)
        sub(/^ +/, "", t); sub(/ +$/, "", t); sub(/^[0-9]+ /, "", t)
        cur = (t in key_of) ? key_of[t] : ""
        if (cur != "") present[cur] = 1
        next
      }
      /^ ? ? ?#([^#]|$)/ { cur = ""; next }
      /^ ? ? ?###/ { next }
      /[^ \t]/ { if (cur != "") count[cur]++ }
      END { for (i = 1; i <= k; i++) printf "%s %d %d\n", keys[i], present[keys[i]], count[keys[i]] + 0 }
    '
}

# Checks the local file $1 against the contract. Prints one "reason|action" line per failed
# check and returns 1 if any; prints nothing and returns 0 when the contract holds.
flowforge_spec_check() {
  local file="$1" entry key title english present count failed=0
  if ! grep -q '[^[:space:]]' "$file"; then
    echo "$FLOWFORGE_SPEC_FILE is empty.|Write the specification: the four sections of the contract, at least one behaviour and one validation scenario."
    return 1
  fi
  while read -r key present count; do
    for entry in "${FLOWFORGE_SPEC_SECTIONS[@]}"; do
      if [[ "${entry%%|*}" == "$key" ]]; then
        title="$(cut -d'|' -f2 <<<"$entry")"; english="$(cut -d'|' -f3 <<<"$entry")"
      fi
    done
    if (( present == 0 )); then
      echo "Missing section '$title'.|Add the level-2 heading '$title', or '$english' in an English-speaking repository (exact title, see the contract)."
      failed=1
    elif [[ "$key" == features ]] && (( count == 0 )); then
      echo "Section '$title' describes no behaviour.|Describe at least one expected behaviour, e.g. '### F-001 — <name>' followed by its description."
      failed=1
    elif [[ "$key" == scenarios ]] && (( count == 0 )); then
      echo "Section '$title' holds no validation scenario.|Add at least one scenario, e.g. '### S-001 — <name>' with GIVEN / WHEN / THEN lines."
      failed=1
    fi
  done < <(_flowforge_spec_sections "$file")
  return "$failed"
}

# Downloads SPEC.md of repository $1 at branch $2 into $3. Returns 0 when read, 3 when the
# file does not exist while the repository and branch are readable, 2 on any other error, with
# a sanitised reason in _FLOWFORGE_SPEC_ERROR. A 404 alone never means "absent": GitHub answers
# 404 for an unreadable repository too.
_flowforge_spec_fetch() {
  local repo="$1" ref="$2" out="$3" err
  if err="$(gh api -H "Accept: application/vnd.github.raw+json" \
      "repos/$repo/contents/$FLOWFORGE_SPEC_FILE?ref=$ref" 2>&1 >"$out")"; then
    return 0
  fi
  if [[ "$err" == *"HTTP 404"* ]]; then
    if gh api "repos/$repo/branches/$ref" --silent >/dev/null 2>&1; then
      return 3
    fi
    _FLOWFORGE_SPEC_ERROR="repository '$repo' or branch '$ref' is not readable with the workflow token (HTTP 404)."
    return 2
  fi
  _FLOWFORGE_SPEC_ERROR="$(grep -v '^[[:space:]]*$' <<<"$err" | tail -n 1 | tr -cd '[:print:]' | cut -c1-200)"
  _FLOWFORGE_SPEC_ERROR="GitHub API error while reading $FLOWFORGE_SPEC_FILE: ${_FLOWFORGE_SPEC_ERROR:-no message}"
  return 2
}

# Gate run before the Developer starts: checks SPEC.md of repository $1 at branch $2.
# Returns 0 (PASS), 1 (FAILED, conformity) or 2 (ERROR, technical); prints an explicit
# diagnostic, writes result=<PASS|FAILED|ERROR> to GITHUB_OUTPUT and a job summary line.
flowforge_spec_gate() {
  local repo="$1" ref="$2" spec rc=0 result failures="" line
  spec="$(mktemp)"
  _flowforge_spec_fetch "$repo" "$ref" "$spec" || rc=$?
  case "$rc" in
    0) failures="$(flowforge_spec_check "$spec")" && result=PASS || result=FAILED ;;
    3) result=FAILED
       failures="Missing $FLOWFORGE_SPEC_FILE at repository root (branch '$ref').|Create and validate $FLOWFORGE_SPEC_FILE on '$ref' before starting an autonomous development task." ;;
    *) result=ERROR ;;
  esac
  rm -f -- "$spec"

  [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "result=$result" >> "$GITHUB_OUTPUT"
  case "$result" in
    PASS)
      echo "SPEC CONTRACT PASSED — $repo, branch '$ref'."
      [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "- SPEC contract: **PASS**" >> "$GITHUB_STEP_SUMMARY"
      return 0 ;;
    FAILED)
      {
        printf 'SPEC CONTRACT FAILED\n\nRepository: %s\nBranch: %s\nFile: %s\n\nReason:\n' "$repo" "$ref" "$FLOWFORGE_SPEC_FILE"
        while IFS= read -r line; do printf -- '- %s\n' "${line%%|*}"; done <<<"$failures"
        printf '\nAction:\n'
        while IFS= read -r line; do printf -- '- %s\n' "${line#*|}"; done <<<"$failures"
        printf '\nContract: %s. The Developer did not start; the Issue keeps its label.\n' "$FLOWFORGE_SPEC_DOC"
      } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
      while IFS= read -r line; do
        echo "::error title=SPEC contract failed::$repo: ${line%%|*}"
      done <<<"$failures"
      return 1 ;;
    *)
      {
        printf 'SPEC CONTRACT ERROR (technical: no conformity verdict)\n\nRepository: %s\nBranch: %s\n\n' "$repo" "$ref"
        printf 'Reason:\n%s\n\nAction:\nCheck the GitHub status, the workflow token and the base branch, then re-run.\n' "$_FLOWFORGE_SPEC_ERROR"
        printf '%s was not found absent; the Developer did not start; the Issue keeps its label.\n' "$FLOWFORGE_SPEC_FILE"
      } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
      echo "::error title=SPEC contract error::$repo: $_FLOWFORGE_SPEC_ERROR"
      return 2 ;;
  esac
}
