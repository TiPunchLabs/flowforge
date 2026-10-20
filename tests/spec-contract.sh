#!/usr/bin/env bash
# Tests of the SPEC.md contract (Phase 8.1), run against the REAL step script:
#   agent-develop.yml  develop/"Check SPEC contract"
# and the helper .github/scripts/flowforge-spec.sh it fetches and sources. `gh` is a stub on
# PATH serving one SPEC.md per (repository, branch) from files: no network, no token.
#
# Requires: bash, jq, yq (mikefarah v4). Usage: tests/spec-contract.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wf="$root/.github/workflows"
helper="$root/.github/scripts/flowforge-spec.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

yq -e '.jobs.develop.steps[] | select(.name == "Check SPEC contract") | .run' \
  "$wf/agent-develop.yml" > "$work/spec.sh"

failures=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }
expect() { # name, actual, expected
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

# Stub of the GitHub CLI. A readable (repository, branch) is a directory
# $FAKE_STATE/repos/<owner>/<name>/<branch>/, holding SPEC.md or not. FAKE_HTTP=<code> makes
# the SPEC.md read fail with that status. Every call is logged to $FAKE_STATE/gh.log.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_STATE/gh.log"
[[ "$1" == api ]] || { echo "gh stub: unexpected call: $*" >&2; exit 1; }
if [[ "$2" == -H ]]; then path="$4"; else path="$2"; fi
not_found() { echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
case "$path" in
  repos/*/contents/.github/scripts/flowforge-spec.sh\?ref=*) cat "$FAKE_HELPER" ;;
  repos/*/contents/SPEC.md\?ref=*)
    if [[ -n "${FAKE_HTTP:-}" ]]; then echo "gh: Server Error (HTTP $FAKE_HTTP)" >&2; exit 1; fi
    repo="${path#repos/}"; repo="${repo%%/contents/*}"
    f="$FAKE_STATE/repos/$repo/${path##*\?ref=}/SPEC.md"
    [[ -f "$f" ]] && cat "$f" || not_found ;;
  repos/*/branches/*)
    repo="${path#repos/}"; repo="${repo%%/branches/*}"
    [[ -d "$FAKE_STATE/repos/$repo/${path##*/branches/}" ]] || not_found ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"

valid_spec() {
  cat <<'EOF'
# Project Specification

## 1. Objectif et périmètre

Une API de démonstration.

## 2. Fonctionnalités

### F-001 — Santé

`GET /health` répond `200` avec `{"status": "ok"}`.

## 3. Règles et contraintes

### R-001 — Pas d'état

Le service ne conserve aucun état entre deux requêtes.

## 4. Scénarios de validation

### S-001 — Santé

GIVEN le service démarré
WHEN un client appelle `GET /health`
THEN la réponse est `200`
EOF
}

# new_case <name>: fresh stub state, prints its dir. add_repo <dir> <owner/name> [branch]
# makes a readable repository branch; put_spec <dir> <owner/name> [branch] < content.
new_case() { local dir="$work/$1"; mkdir -p "$dir/repos"; : > "$dir/gh.log"; echo "$dir"; }
add_repo() { mkdir -p "$1/repos/$2/${3:-main}"; }
put_spec() { add_repo "$1" "$2" "${3:-main}"; cat > "$1/repos/$2/${3:-main}/SPEC.md"; }
run() { # dir, repository, [branch], [extra env...]
  local dir="$1" repo="$2" ref="${3:-main}"
  shift 3 2>/dev/null || shift $#
  : > "$dir/github_output"; : > "$dir/summary"
  set +e
  env PATH="$work/bin:$PATH" FAKE_STATE="$dir" FAKE_HELPER="$helper" GH_TOKEN=ghs_secret_value_for_test \
    GITHUB_REPOSITORY="$repo" BASE_BRANCH="$ref" GITHUB_OUTPUT="$dir/github_output" \
    GITHUB_STEP_SUMMARY="$dir/summary" FLOWFORGE_REPOSITORY=TiPunchLabs/flowforge FLOWFORGE_SHA=0123abc \
    "$@" bash --noprofile --norc -eo pipefail "$work/spec.sh" > "$dir/log" 2>&1
  echo $? > "$dir/exit"
  set -e
}
result() { printf '%s/%s' "$(cat "$1/exit")" "$(sed -n 's/^result=//p' "$1/github_output")"; }
logged() { grep -cF -- "$2" "$1/log" || true; }
# failed <name> <dir> <reason text>: non-conformity with that reason, as annotation and diagnostic.
failed() {
  expect "$1" "$(result "$2")/$(logged "$2" "::error title=SPEC contract failed::")/$(logged "$2" "$3")" "1/FAILED/1/2"
}

# --- T1 / T10: valid SPEC.md ---------------------------------------------------------------
c="$(new_case valid)"; valid_spec | put_spec "$c" owner/target-a
run "$c" owner/target-a
expect "T1 valid SPEC.md: PASS, step succeeds" "$(result "$c")" "0/PASS"
expect "T1 valid SPEC.md: summary line" "$(grep -c 'SPEC contract: \*\*PASS\*\*' "$c/summary")" 1
expect "T1 SPEC.md read on the base branch of the calling repository" \
  "$(grep -c '^api -H Accept: application/vnd.github.raw+json repos/owner/target-a/contents/SPEC.md?ref=main$' "$c/gh.log")" 1

c="$(new_case english)"
valid_spec | sed -e 's/^## 1\..*/##   objective AND scope/' -e 's/^## 2\..*/## Features ##/' \
  -e 's/^## 3\..*/## 3) Rules and Constraints/' -e 's/^## 4\..*/## 4. Validation scenarios/' \
  | put_spec "$c" owner/target-a
run "$c" owner/target-a
expect "English titles, case, numbering and spacing tolerated" "$(result "$c")" "0/PASS"

c="$(new_case no-accents)"
valid_spec | sed -e 's/^## 1\..*/## 🎯 1. OBJECTIF ET PERIMETRE/' -e 's/^## 2\..*/## Fonctionnalites/' \
  -e 's/^## 3\..*/## Regles  et  contraintes/' -e 's/^## 4\..*/## 4 - Scenarios de validation/' \
  | put_spec "$c" owner/target-a
run "$c" owner/target-a
expect "missing accents and emoji prefix tolerated" "$(result "$c")" "0/PASS"
run "$c" owner/target-a main LC_ALL=C LANG=C
expect "result independent of the runner locale" "$(result "$c")" "0/PASS"

c="$(new_case branch)"; valid_spec | put_spec "$c" owner/target-a develop; add_repo "$c" owner/target-a
run "$c" owner/target-a develop
expect "base branch input is the ref read (develop: PASS)" "$(result "$c")" "0/PASS"
run "$c" owner/target-a main
failed "base branch input is the ref read (main without SPEC.md: FAILED)" "$c" "Missing SPEC.md at repository root (branch 'main')"

# --- T2 / T3: absent or empty --------------------------------------------------------------
c="$(new_case absent)"; add_repo "$c" owner/target-a
run "$c" owner/target-a
failed "T2 SPEC.md absent: FAILED" "$c" "Missing SPEC.md at repository root"
expect "T2 diagnostic names the repository and the action" \
  "$(logged "$c" "Repository: owner/target-a")/$(logged "$c" "Create and validate SPEC.md on 'main' before starting an autonomous development task.")" "1/1"
expect "T2 diagnostic in the job summary" "$(grep -c '^SPEC CONTRACT FAILED$' "$c/summary")" 1

c="$(new_case empty)"; printf '' | put_spec "$c" owner/target-a
run "$c" owner/target-a
failed "T3 SPEC.md empty: FAILED" "$c" "SPEC.md is empty."
c="$(new_case blank)"; printf '\n   \n\t\n' | put_spec "$c" owner/target-a
run "$c" owner/target-a
failed "T3 SPEC.md blank (whitespace only): FAILED" "$c" "SPEC.md is empty."

# --- T4: section missing -------------------------------------------------------------------
c="$(new_case no-rules)"; valid_spec | sed '/^## 3\./d' | put_spec "$c" owner/target-a
run "$c" owner/target-a
failed "T4 section 'Règles et contraintes' missing: FAILED" "$c" "Missing section '## 3. Règles et contraintes'."

c="$(new_case h3-section)"; valid_spec | sed 's/^## 1\./### 1./' | put_spec "$c" owner/target-a
run "$c" owner/target-a
failed "T4 section at heading level 3 does not count" "$c" "Missing section '## 1. Objectif et périmètre'."

# Only the titles of the contract are accepted: a free translation is not (Prompt 37.1 audit).
c="$(new_case unlisted-title)"; valid_spec | sed 's/^## 1\..*/## 1. Purpose and scope/' | put_spec "$c" owner/target-a
run "$c" owner/target-a
failed "T4 unlisted title 'Purpose and scope' does not count" "$c" "Missing section '## 1. Objectif et périmètre'."

c="$(new_case fenced-heading)"
# shellcheck disable=SC2016 # literal Markdown fences
{ valid_spec | sed '/^## 3\./d'; printf '\n```markdown\n## 3. Règles et contraintes\n```\n'; } | put_spec "$c" owner/target-a
run "$c" owner/target-a
failed "T4 heading inside fenced code does not count" "$c" "Missing section '## 3. Règles et contraintes'."

c="$(new_case all-missing)"; printf '# Project\n\nSome text.\n' | put_spec "$c" owner/target-a
run "$c" owner/target-a
expect "T4 every missing section reported in one run" \
  "$(result "$c")/$(logged "$c" "::error title=SPEC contract failed::owner/target-a: Missing section")" "1/FAILED/4"

# --- T5: no behaviour ----------------------------------------------------------------------
c="$(new_case no-feature)"
valid_spec | awk '/^## 2\./{print; skip=1; next} /^## 3\./{skip=0} !skip' | put_spec "$c" owner/target-a
run "$c" owner/target-a
failed "T5 empty 'Fonctionnalités' section: FAILED" "$c" "describes no behaviour."

c="$(new_case feature-placeholder)"
valid_spec | awk '/^## 2\./{print "## 2. Fonctionnalités\n\n### F-001 — À définir\n\n<!--\nDescribe the behaviour.\n-->\n<!-- TODO -->"; skip=1; next} /^## 3\./{skip=0} !skip' \
  | put_spec "$c" owner/target-a
run "$c" owner/target-a
failed "T5 headings and HTML comments only are not a behaviour" "$c" "describes no behaviour."

# --- T6: no scenario -----------------------------------------------------------------------
c="$(new_case no-scenario)"; valid_spec | sed '/^## 4\./q' | put_spec "$c" owner/target-a
run "$c" owner/target-a
failed "T6 empty 'Scénarios de validation' section: FAILED" "$c" "holds no validation scenario."

c="$(new_case fenced-scenario)"
# shellcheck disable=SC2016 # literal Markdown fences
{ valid_spec | sed '/^## 4\./q'; printf '\n```gherkin\nGIVEN a\nWHEN b\nTHEN c\n```\n'; } | put_spec "$c" owner/target-a
run "$c" owner/target-a
expect "T6 scenario inside fenced code counts" "$(result "$c")" "0/PASS"

c="$(new_case reordered)"
valid_spec | awk '/^## 4\./{s=1} s{tail=tail $0 "\n"; next} {print} END{printf "%s", tail}' > "$work/r.md"
{ sed -n '/^## 4\./,$p' "$work/r.md"; sed '/^## 4\./,$d' "$work/r.md"; } | put_spec "$c" owner/target-a
run "$c" owner/target-a
expect "sections in another order: no order imposed" "$(result "$c")" "0/PASS"

# --- T7: two targets, each its own SPEC.md -------------------------------------------------
c="$(new_case two-targets)"
valid_spec | put_spec "$c" owner/target-a
valid_spec | sed '/^## 2\./,$d' | put_spec "$c" other-org/target-b
run "$c" owner/target-a
expect "T7 target A (valid SPEC.md): PASS" "$(result "$c")" "0/PASS"
expect "T7 target A run reads no other repository" "$(grep -c 'target-b' "$c/gh.log" || true)" 0
: > "$c/gh.log"
run "$c" other-org/target-b
expect "T7 target B (incomplete SPEC.md): FAILED despite A's valid one" \
  "$(result "$c")/$(logged "$c" "other-org/target-b: Missing section")" "1/FAILED/3"
expect "T7 target B run reads no other repository" "$(grep -c 'target-a' "$c/gh.log" || true)" 0

# --- T8: technical errors are not "absent" -------------------------------------------------
c="$(new_case unreadable)"
run "$c" owner/hidden
expect "T8 repository not readable (404 everywhere): ERROR, not FAILED" \
  "$(result "$c")/$(logged "$c" "::error title=SPEC contract error::")/$(logged "$c" "Missing SPEC.md")" "2/ERROR/1/0"
expect "T8 diagnostic explains the technical cause" \
  "$(logged "$c" "repository 'owner/hidden' or branch 'main' is not readable")/$(logged "$c" "SPEC.md was not found absent")" "2/1"

c="$(new_case no-branch)"; add_repo "$c" owner/target-a
run "$c" owner/target-a missing-branch
expect "T8 base branch missing: ERROR" "$(result "$c")" "2/ERROR"

for code in 502 403; do
  c="$(new_case "http-$code")"; add_repo "$c" owner/target-a
  run "$c" owner/target-a main FAKE_HTTP="$code"
  expect "T8 GitHub API HTTP $code: ERROR with the API reason" \
    "$(result "$c")/$(logged "$c" "GitHub API error while reading SPEC.md: gh: Server Error (HTTP $code)")" "2/ERROR/2"
done

# --- No secret in any diagnostic -------------------------------------------------------------
expect "token never printed (log or summary)" \
  "$(cat "$work"/*/log "$work"/*/summary | grep -c ghs_secret_value_for_test || true)" 0

# --- T9 / T10: the Developer cannot start when the gate fails ------------------------------
dev="$wf/agent-develop.yml"
idx() { yq "[.jobs.develop.steps[].name] | to_entries[] | select(.value == \"$1\") | .key" "$dev"; }
gate="$(idx "Check SPEC contract")"
expect "T9 gate runs after the Issue context, before any state change, checkout or Claude" \
  "$(( $(idx "Resolve issue context") < gate && gate < $(idx "Mark issue as running") \
    && gate < $(idx "Check out target repository") && gate < $(idx "Run Claude Code") ))" 1
expect "T9 gate is never skipped nor tolerated (no if, no continue-on-error)" \
  "$(yq '.jobs.develop.steps[] | select(.name == "Check SPEC contract") | [has("if"), has("continue-on-error")] | any' "$dev")" false
expect "T9 state change and Claude Code run only if every earlier step succeeded" \
  "$(yq '[.jobs.develop.steps[] | select(.name == "Mark issue as running" or .name == "Run Claude Code") | has("if")] | any' "$dev")" false
# Steps that may run after a failure (always / failure / !cancelled) must depend on the
# running state having been set, or on a token minted by a step that does not run then.
overrides="$(yq -r ".jobs.develop.steps | .[$gate:] | .[] | select((.if // \"\") | test(\"always|failure|cancelled\")) | .if" "$dev")"
expect "T9 every status-override step after the gate needs 'running' (or its skipped token)" \
  "$(grep -c . <<<"$overrides")/$(grep -vcE "steps\.running\.outcome == 'success'|steps\.project_token_start\.outputs\.token != ''" <<<"$overrides" || true)" "5/0"
expect "T9 the Project start token is minted only on success" \
  "$(yq '.jobs.develop.steps[] | select(.id == "project_token_start") | .if | test("always|failure|cancelled")' "$dev")" false
c="$(new_case gate-no-write)"; add_repo "$c" owner/target-a
run "$c" owner/target-a
expect "T9 failing gate makes only read calls (no label, comment nor Issue write)" \
  "$(result "$c")/$(grep -cvE '^api (-H Accept: application/vnd\.github\.raw\+json )?repos/[^ ]+( --silent)?$' "$c/gh.log" || true)" "1/FAILED/0"

# --- T11: preparing SPEC.md and other agents are not gated ---------------------------------
expect "T11 only the Developer workflow runs the gate (Refiner, Reviewer, Iterator, cycle, lifecycle, Notion: none)" \
  "$(grep -lE 'flowforge-spec\.sh|flowforge_spec_' "$wf"/*.yml | xargs -n1 basename | paste -sd, -)" "agent-develop.yml"
expect "T11 gate and helper hold no target-specific name" \
  "$(cat "$helper" "$work/spec.sh" | grep -ciE 'demo-api|tipunchlabs' || true)" 0

echo
if (( failures > 0 )); then
  echo "$failures SPEC contract test(s) failed."
  exit 1
fi
echo "All SPEC contract tests passed."
