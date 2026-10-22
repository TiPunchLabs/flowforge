# 🧩 Onboarding a target repository

> **Objective**: connect a GitHub repository (a *target*), existing or new, to FlowForge, so
> that its Issues can be refined, implemented as Draft PRs, reviewed and iterated on by the
> FlowForge agents, with the target's CI running on every agent PR.
> **Prerequisites**: admin access to the target repository; an organization owner for the
> one-time organization setup (§1) and for adding the target to existing lists (§2.3, §2.4);
> the target has its own CI (`pull_request` workflows).
> **Reference installation**: `TiPunchLabs/demo-api` (§8). This is the single, detailed
> onboarding reference. The step-by-step guide [GETTING_STARTED.md](../GETTING_STARTED.md) is
> derived from it; when they differ, this document is right.

------

## 🧠 Mental Model

Three levels, configured by different people, at different times. Never mix them.

```text
  A. ORGANIZATION (once, shared)          B. REPOSITORY (per target)           C. FUNCTIONAL (per target)
  ──────────────────────────────          ──────────────────────────           ──────────────────────────
  FlowForge repo (public, reusable        Terraform module target-repository   CLAUDE.md  (stack, commands)
    workflows + agents/ rules)              in ONE state: labels agent:*,      SPEC.md    (functional contract,
  GitHub App "FlowForge"                    ruleset, workflow token settings              validated by the owner)
  org secrets  CLAUDE_CODE_OAUTH_TOKEN    + target added to: App installation,
               FLOWFORGE_APP_PRIVATE_KEY    secret/variable visibility lists
  org vars     FLOWFORGE_APP_CLIENT_ID    + 5 thin callers .github/workflows/
               FLOWFORGE_PROJECT_NUMBER     flowforge-*.yml (from examples/)
  org Project  "FlowForge Development"    + the target's own CI
        │                                          │                                │
        └──────────── B and C are the only per-target work: a new target creates ──┘
                      no App, no key, no secret, no Project — it joins existing lists.
```

| Responsibility | FlowForge (this repository) | Target (repository or its IaC) |
|---|---|---|
| Agent rules, reusable workflows, step scripts | ✅ owns | ❌ never copies them |
| Terraform module `target-repository` | ✅ provides | ✅ instantiates it, in **one** state, and owns the resources |
| Labels, ruleset, token settings | ❌ | ✅ through its module block |
| Secrets and variables | ❌ (organization owner, out of Terraform) | joins the visibility lists |
| Callers `flowforge-*.yml`, CI | templates in [`examples/target-repository/`](../examples/target-repository/) | ✅ copies and adapts them |
| `CLAUDE.md`, `SPEC.md` | contract ([spec-contract.md](spec-contract.md)) and checker | ✅ writes and validates them |

------

## 📋 Table of contents

1. Organization prerequisites (level A)
2. Repository prerequisites (level B)
3. Functional preparation (level C)
4. Readiness checks (`PASS` / `FAIL` / `NOT_VERIFIED`)
5. First request
6. Validation after the first run
7. Common errors
8. Reference installation: `demo-api`
9. Notion intake (optional)
10. Versions and updates

------

## 🏢 1. Organization prerequisites (level A)

Done **once** for the organization. If they already exist, a new target only checks them (§4).

| Item | Value | Where it is described |
|---|---|---|
| FlowForge repository | `TiPunchLabs/flowforge`, **public**: any repository can call its reusable workflows | — |
| FlowForge GitHub App | `tipunchlabs-flowforge`, owned by the organization (§1.1) | [architecture.md §2.10](architecture.md) |
| Secret `CLAUDE_CODE_OAUTH_TOKEN` | `claude setup-token`; every agent | §1.2 |
| Secret `FLOWFORGE_APP_PRIVATE_KEY` | the App's private key; delivery and Project sync | §1.2 |
| Variable `FLOWFORGE_APP_CLIENT_ID` | the App's client ID | §1.2 |
| Variable `FLOWFORGE_PROJECT_NUMBER` | `1` = organization Project `FlowForge Development`; unset = no Project sync | [synchronization.md §4](github-projects/synchronization.md) |
| Organization Project | `FlowForge Development` (#1), provisioned by `scripts/github-projects/bootstrap.sh` | [provisioning.md](github-projects/provisioning.md) |
| Organization Actions policy | must allow the target to run actions from other repositories (`allowed_actions: all`, or a selected list covering `TiPunchLabs/flowforge` and the pinned actions) | — |

### 1.1 🤖 FlowForge GitHub App (delivery identity)

**Why an App.** Workflows that push or open a PR with `GITHUB_TOKEN` create the target's
`pull_request` runs in an **approval-required** state ("Approve workflows to run"): agent PRs
get no CI unless a human approves every run. With a GitHub App installation token, the push
and the PR are made by `<app-slug>[bot]` and the target's CI runs normally (FlowForge Issue #34).

The App is used for **delivery** (the Developer's branch push + Draft PR, the Iterator's
fast-forward push) and for the **Project sync**. Claude never receives a delivery token: it
commits locally, the workflow verifies the commits and delivers. Project tokens are revoked
before any agent runs. Labels and comments always use `GITHUB_TOKEN`.

There is **one** FlowForge App. A new target is added to its installation; no new App, no new
key. Each run mints a short-lived token (about 1 h) restricted to the **calling repository**,
so a run on one target can never write to another.

| App setting | Value |
|---|---|
| Owner | the organization (TiPunchLabs) |
| Webhook | inactive |
| Repository permissions | Contents: read & write, Pull requests: read & write, Metadata: read |
| Organization permissions | Projects: read & write (Project sync only, [provisioning.md §6.2](github-projects/provisioning.md)) |
| Issues permission | **none** (anti-loop rule 1, §1.3) |
| Where can it be installed | Only on this account |
| Installation | *Only select repositories*: every onboarded target, nothing else |

> ⚠️ **Warning**: "Only on this account" means only repositories of this organization. A
> target owned by another account needs either a second App owned by that account, or the
> App made installable on any account.

> ⚠️ **Warning**: the App has no `workflows` permission. An agent commit that changes
> `.github/workflows/` is rejected at push time; such changes stay human work.

**Without the App.** If `FLOWFORGE_APP_CLIENT_ID` is empty, FlowForge delivers with
`GITHUB_TOKEN`: everything works, but agent PRs show "Approve workflows to run", their CI
needs a manual approval, and there is no Project sync. The module's
`can_approve_pull_request_reviews = true` is what lets `GITHUB_TOKEN` create PRs in that mode.

### 1.2 🔐 Secrets and variables

Stored **once, at organization level**, with *Selected repositories* visibility. Never copy
them per repository unless the target is outside the organization: a repository-level value
overrides the organization one.

| Name | Kind | Used by | Required |
|---|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | secret | every agent | **yes** |
| `FLOWFORGE_APP_PRIVATE_KEY` | secret | Developer / Iterator delivery; Project sync | recommended |
| `FLOWFORGE_APP_CLIENT_ID` | variable | Developer / Iterator delivery; Project sync | recommended |
| `FLOWFORGE_PROJECT_NUMBER` | variable | Project sync opt-in (needs the App) | optional |

```bash
# First target only: create them (organization owner). The .pem never goes into Git.
gh secret set CLAUDE_CODE_OAUTH_TOKEN --org TiPunchLabs --visibility selected --repos demo-api
gh secret set FLOWFORGE_APP_PRIVATE_KEY --org TiPunchLabs --visibility selected --repos demo-api < flowforge.pem
gh variable set FLOWFORGE_APP_CLIENT_ID --org TiPunchLabs --visibility selected --repos demo-api --body "Iv23..."
gh variable set FLOWFORGE_PROJECT_NUMBER --org TiPunchLabs --visibility selected --repos demo-api --body 1
```

Terraform never manages them: a `github_actions_secret` lands in plain text in the state.

### 1.3 🔁 Anti-loop rules (must hold on every target)

With an App token, `pull_request` events start workflows again. These rules keep agents from
triggering each other without a human:

1. **The App never touches labels or Issues** (no `issues` permission). Otherwise it could
   apply `agent:ready` and restart the Developer.
2. **The review caller ignores every bot actor** (`!endsWith(github.actor, '[bot]')` in
   `flowforge-review.yml`). Otherwise each Iterator push starts a Reviewer outside the cycle.
3. **The review cycle stays human-started** (`workflow_dispatch` only). An automatic start on
   push would give Iterator → push → cycle → Iterator.

------

## 📦 2. Repository prerequisites (level B)

### 2.1 🏗️ Terraform: one target = one IaC owner = one state

The module [`terraform/modules/target-repository`](../terraform/modules/target-repository/README.md)
manages the six `agent:*` labels, the default-branch ruleset (human merge gate) and the workflow
token settings. It **reads** the repository (data source) and never creates or deletes it, so it
works the same for an existing and a new repository. Instantiate it in **exactly one** state
([architecture.md §2.1](architecture.md)):

| Target situation | Where the `module` block lives |
|---|---|
| Already managed by its own Terraform (**preferred**, e.g. `demo-api`) | the target's IaC, next to its `github_repository`, with `repository = github_repository.<x>.name` |
| No Terraform of its own | FlowForge `terraform/` root, one `module "<name>"` block |

Never both: two states would rewrite each other's labels and ruleset on every `apply`.

**Existing repository: adopt, never recreate.** Before the first `plan`, list what the module
would manage and already exists:

```bash
R=TiPunchLabs/<target>
gh api "repos/$R/labels" --paginate --jq '.[] | select(.name | startswith("agent:")) | .name'
gh api "repos/$R/rulesets" --jq '.[] | [.id, .name] | @tsv'
```

Adopt each existing object with a standard Terraform `import` block, in the **root** module of
the owning state (Terraform ≥ 1.5; the module requires ≥ 1.6), then delete the block after the
apply:

```hcl
# In the state that owns the target; module name "flowforge" as in demo-api.
import {
  to = module.flowforge.github_issue_label.flowforge_labels["agent:ready"] # one per existing label
  id = "<target>:agent:ready"                                              # repository:label
}
import {
  to = module.flowforge.github_repository_ruleset.default_branch[0]
  id = "<target>:<ruleset id>"                                             # repository:ruleset_id
}
import {
  to = module.flowforge.github_workflow_repository_permissions.workflow_permissions
  id = "<target>"                                                          # repository name
}
```

The `plan` must then show `import` (plus in-place updates where the existing values differ
from the module) and **no `create`** for an object that already exists. A ruleset protecting
the default branch under another name is not adopted: either remove it by hand, or keep it and
set `default_branch_ruleset_enabled = false` (then the human merge gate is that ruleset's job).

**New repository.** Create it in the same state as its module block (`github_repository` +
`module`, as `demo-api` does). The module reads the repository through a data source and its
ruleset forbids the initial direct push, so: first `terraform apply -target=<repository
resource>`, then push `main`, then the full `apply`. Same module, no second mechanism.

> ⚠️ **Warning**: `terraform apply` changes a real repository; run it only after reviewing the
> plan, with a token scoped to the target (module README, *Required token permissions*).

**Required status check.** Once the App delivers agent PRs and the first agent PR shows its CI
check, set `required_status_checks` (context = the CI **job name**, `integration_id = 15368`).
Not before: with `GITHUB_TOKEN` delivery the check would wait for an approval and block the merge.

**Repository visibility.** Rulesets on private repositories need a paid organization plan;
`TiPunchLabs` is on the free plan, which is why `demo-api` is public.

### 2.2 📝 Caller workflows

Copy the five callers from [`examples/target-repository/`](../examples/target-repository/) into
the target's `.github/workflows/`, replace `OWNER`, and set only the project-specific inputs
(`setup_uv`, `allowed_tools`, `review_allowed_tools`, `iterate_allowed_tools`). Every caller
passes `project_number` and `app_client_id` from the organization variables; secrets are passed
explicitly, never with `secrets: inherit`.

| File | Trigger | Reusable workflow | App key used for | Project event |
|---|---|---|---|---|
| `flowforge-refine.yml` | `workflow_dispatch` (`issue_number`) | `agent-refine.yml` | Project sync only (token revoked before Claude) | `Refining` → `Ready` / `Backlog` |
| `flowforge-agent.yml` | `issues: labeled` (`agent:ready`) | `agent-develop.yml` | delivery + Project sync | `Developing` → `Review` |
| `flowforge-review.yml` | `workflow_dispatch` + human `pull_request` activity on `agent/*` | `agent-review.yml` | Project sync job only, never the Reviewer | `APPROVE` only: `Review` → `Human validation` (Prompt 38.1, A4) |
| `flowforge-review-cycle.yml` | `workflow_dispatch` (`pull_request_number`) | `review-cycle.yml` | Iterator push + Project sync | `Review` ⇄ `Iteration` → `Human validation` / Attention |
| `flowforge-lifecycle.yml` | `pull_request: closed` on `agent/*` | `agent-lifecycle.yml` | Project sync only | `Done` on merge |

The callers' `permissions:` blocks are the union of what the called jobs request: keep them as
in the examples (a caller can only narrow, never widen). The Project sync is opt-in and
best-effort: without `FLOWFORGE_PROJECT_NUMBER` (or without the App) every workflow runs with
labels only. Callers pin a FlowForge version by full commit SHA, the same in all five (§10).

### 2.3 🔑 Join the organization lists (organization owner)

- Add the repository to the visibility list of the two secrets and two variables (Organization
  settings → Secrets and variables → Actions → the entry → *Repository access*).
- Add the repository to the App installation (Organization settings → GitHub Apps → FlowForge →
  **Configure** → *Repository access*).

### 2.4 🧪 The target's CI

A `pull_request` workflow on the default branch, without `paths:` filter (a required check on a
skipped workflow blocks the merge), with explicit `permissions:` (the module keeps
`default_workflow_permissions = "write"`, which fails open for workflows without them).

------

## 📖 3. Functional preparation (level C)

| File | Content | Who validates |
|---|---|---|
| `CLAUDE.md` (root) | stack, test / lint / format commands, conventions. Agents read it first; FlowForge's own rules (`agents/`) stay generic | the target owner |
| `SPEC.md` (root, default branch) | the functional contract: four sections, at least one behaviour and one scenario ([spec-contract.md](spec-contract.md)). **Required**: otherwise the Developer refuses to start (`SPEC contract: FAILED`), and the Refiner, which reads the default branch only, classifies every request `NO_SPEC` | the target owner (content); FlowForge checks the structure only |

For an existing project, run the target preparation mission
([preparation-projet-existant-pour-flowforge.md](preparation-projet-existant-pour-flowforge.md))
inside the target: it writes `SPEC.md` with the contract's exact titles, in the target's
language, and `docs/flowforge-spec-review.md` (sources, contradictions, owner questions,
scenario → test coverage). For a new project, write `SPEC.md` directly from the contract. In
both cases check the structure locally before merging it:

```bash
# From the target checkout; <flowforge> = a local FlowForge checkout. No gh, no network.
bash <flowforge>/.github/scripts/flowforge-spec.sh SPEC.md   # last line: SPEC contract: PASS|FAILED|ERROR
```

The agent commands listed in `allowed_tools` must be the ones `CLAUDE.md` documents (e.g.
`uv run pytest`), otherwise the agents cannot run the checks they are told to run.

------

## ✅ 4. Readiness checks

Run them before the first request. Each check is **read-only**: it uses an existing script or a
`gh api` read and never prints a secret value.

### 4.1 🧠 Results and evidence

| Result | Meaning |
|---|---|
| `PASS` | the check was run and the evidence covers its claim **now** |
| `FAIL` | a mandatory item is absent or wrong: fix it before the first request |
| `NOT_VERIFIED` | the available permissions or data cannot settle it. Never read it as `PASS` |

| Evidence | What it proves | What it does not prove |
|---|---|---|
| `DIRECT` | the current configuration, read from the object itself (ruleset, labels, App **installation**) | — |
| `REPO-SIDE` | what the target's workflows receive (secrets / variables visible to the repository) | the organization-level *Selected repositories* list itself |
| `DECLARED` | what the App **asks** for (`apps/<slug>`) | that the installation accepted it ([provisioning.md §6.2](github-projects/provisioning.md)) |
| `FUNCTIONAL` (dated) | a run used the item successfully at that date (log line, App-authored PR) | that it is unchanged since |

Rules:

- `DECLARED` alone is never a `PASS`.
- `FUNCTIONAL` alone gives a `PASS` only for the **validity of a value nobody can read** (a
  secret, the App key), and only if the run is **newer than the item's `updated_at`**. For
  anything that can be read directly (permissions, installation, lists), a `FUNCTIONAL` proof
  is cited in the evidence but the result stays `NOT_VERIFIED` until a direct read is done.
- A missing permission gives `NOT_VERIFIED`, never `PASS` and never `FAIL`.
- The Project sync steps are `continue-on-error` (best effort): a green step is no proof.
  The proof is the step's log line `Project sync <repo>#<n> [<event>]: update — Status A → B`.

### 4.2 📋 Checks R1–R19

```bash
R=TiPunchLabs/<target>   # owner/name
APP=tipunchlabs-flowforge
```

Permissions column: *public* = any token; *repo read* / *repo admin* = access to the target
(`repo` scope); *org owner* = organization owner role **and** `read:org`; *`admin:org`* = that
token scope, which the default `gh` login does not carry (§4.3).

| # | Lvl | Claim | Method | Permission | Evidence | `PASS` when | `FAIL` when |
|---|---|---|---|---|---|---|---|
| R1 | A | FlowForge is callable | `gh api repos/TiPunchLabs/flowforge --jq .visibility` | public | `DIRECT` | `public` | — (`private`: `NOT_VERIFIED`, check its Actions access settings) |
| R2 | A | App permissions **granted** | `gh api orgs/TiPunchLabs/installations --jq '.installations[] \| select(.app_slug=="'$APP'") \| {permissions, suspended_at, repository_selection}'` | org owner | `DIRECT` (installation) | contents / pull_requests / organization_projects `write`, **no** `issues`, `suspended_at: null` | `issues` granted, a required permission missing, or suspended |
| R3 | A | Project exists, has the model's statuses and fields | `scripts/github-projects/bootstrap.sh --check` | `read:project` | `DIRECT` | `Check: Project conforms to the model.` | drift reported (only if the sync is wanted) |
| R4 | B | Repository readable, Issues on | `gh api repos/$R --jq '[.visibility,.default_branch,.has_issues]'` | repo read | `DIRECT` | readable, `has_issues: true` | 404, Issues disabled |
| R5 | B | Actions allowed | `gh api repos/$R/actions/permissions` | repo admin | `DIRECT` | `enabled: true`, `allowed_actions: all` | disabled or `local_only` (`selected`: `NOT_VERIFIED`, inspect the list) |
| R6 | B | One IaC owner | `grep -rn 'target-repository' <target IaC>/*.tf terraform/*.tf`; `jq -r '.resources[] \| "\(.module) \(.type)"' <owning IaC>/terraform.tfstate` (local file, no API) | local files | `DIRECT` | exactly one state holds the module, its 6 labels, ruleset and token settings | module in two places, or none |
| R7 | B | Labels | `gh api repos/$R/labels --paginate --jq '.[].name' \| grep -c '^agent:'` | repo read | `DIRECT` | `7` from module `v0.2.0` (6 states + `agent:manual`); `6` with `v0.1.0` | fewer (workflows then skip the state with a warning; without `agent:manual` no automatic start, `D-MANUAL-MISSING`) |
| R8 | B | Merge gate | `gh api repos/$R/rulesets --jq '.[] \| [.name,.enforcement]'` | repo read | `DIRECT` | `flowforge-default-branch` `active` (or the documented replacement) | absent or not `active` |
| R9 | B | Token settings | `gh api repos/$R/actions/permissions/workflow` | repo admin | `DIRECT` | `can_approve_pull_request_reviews: true` | `false` (blocks `GITHUB_TOKEN` delivery) |
| R10 | B | Secrets reach the target | `gh api repos/$R/actions/organization-secrets --jq '.secrets[] \| [.name,.updated_at]'` (names and dates only, never values) | repo admin | `REPO-SIDE`; value validity `FUNCTIONAL` | `CLAUDE_CODE_OAUTH_TOKEN` and, with the App, `FLOWFORGE_APP_PRIVATE_KEY` visible | `CLAUDE_CODE_OAUTH_TOKEN` not visible |
| R11 | B | Variables reach the target and match | `gh api repos/$R/actions/organization-variables --jq '.variables[].name'`, then the two comparisons below | repo admin; public | `REPO-SIDE` + `DIRECT` | both visible; client ID = the App's; Project number = `config/github-project.json` | client ID without key (or the reverse), or a mismatch |
| R12 | B | No repository override | `gh api repos/$R/actions/secrets --jq .total_count`; same with `variables` | repo admin | `DIRECT` | none of the four names at repository level; only `FLOWFORGE_AUTONOMY_MODE` / `FLOWFORGE_AUTONOMY_OWNER` allowed there, when in the target's state (R19) | any of the four at repository level |
| R13 | B | Callers installed and pinned | `gh workflow list -R $R`; per caller `yq '.jobs[] \| [.uses, (.with \| has("project_number")), (.with \| has("app_client_id"))]'` on the default branch | repo read | `DIRECT` | 5 callers `active`, same full SHA of a published tag (§10), Project inputs present, no `secrets: inherit` | a caller missing, `@main`, mixed SHAs, `secrets: inherit` |
| R14 | B | App installed **on the target** | §4.3 A-2 (organization owner, UI) | org owner (UI) | `DIRECT`; otherwise `FUNCTIONAL` | the target is in the installation's repository list | the target is absent while `FLOWFORGE_APP_CLIENT_ID` is visible |
| R15 | B | Required check name | ruleset `required_status_checks[].context` vs the CI job `name:` | repo read | `DIRECT` | identical, or no required check yet | different (every merge blocked) |
| R16 | C | `SPEC.md` contract | `bash <flowforge>/.github/scripts/flowforge-spec.sh SPEC.md` on the default branch | local file | `DIRECT` | `SPEC contract: PASS` | `FAILED` (`ERROR` = `NOT_VERIFIED`) |
| R17 | C | `CLAUDE.md` present | `gh api repos/$R/contents/CLAUDE.md --jq .name` | repo read | `DIRECT` | found | absent |
| R18 | C | `SPEC.md` validated by the owner | documentary: the owner answered `docs/flowforge-spec-review.md` and merged `SPEC.md` | — | documentary | owner confirms | — (otherwise `NOT_VERIFIED`) |
| R19 | B | Autonomy configuration (`v0.2.0`) | `gh api repos/$R/actions/variables --jq '.variables[] \| select(.name \| startswith("FLOWFORGE_AUTONOMY_")) \| [.name,.value]'`; `gh api orgs/TiPunchLabs/actions/variables --jq '[.variables[].name \| select(startswith("FLOWFORGE_AUTONOMY_"))]'`; owning state holds `autonomy_*` inputs | repo admin; `admin:org` | `DIRECT` | none (`SUPERVISED`), or `SEMI_AUTO` with an owner = the repository's human owner, both in the target's Terraform state, none at organization level | autonomy variable at organization level, `SEMI_AUTO` without owner, or set outside the target's state |

R11 comparisons (they print only `MATCH` / `MISMATCH`, never a value):

```bash
vars() { gh api "repos/$R/actions/organization-variables" --jq ".variables[] | select(.name==\"$1\") | .value"; }
[ "$(gh api apps/$APP --jq .client_id)" = "$(vars FLOWFORGE_APP_CLIENT_ID)" ] && echo MATCH || echo MISMATCH
[ "$(jq .number config/github-project.json)" = "$(vars FLOWFORGE_PROJECT_NUMBER)" ] && echo MATCH || echo MISMATCH
```

**Value validity (R10, `FUNCTIONAL`).** No API can read a secret. The proof is a run, newer
than the secret's `updated_at`, in which the secret was used:

- `FLOWFORGE_APP_PRIVATE_KEY`: a step *Create App delivery token* or *Create Project token* succeeded.
- `CLAUDE_CODE_OAUTH_TOKEN`: an agent produced a result (a verdict or a Draft PR).

Read a run's log lines with the job-log endpoint:

```bash
gh api "repos/$R/actions/runs/<run id>/jobs" --jq '.jobs[] | [.id, .name] | @tsv'
gh api "repos/$R/actions/jobs/<job id>/logs" | grep -E 'Project sync |permission-'
```

Without such a run (a new target), the validity is `NOT_VERIFIED` until the first run.

**App capabilities.** The App can *create PRs* and *move Project cards* on a target when R2
(granted permissions) and R14 (installed on the target) both `PASS`. A dated `FUNCTIONAL` proof
(an App-authored PR, a `Project sync … update` line) confirms that the chain works. It does not
replace R2 or R14.

### 4.3 🔑 Checks that need an organization owner

These checks cannot be run with the default `gh` login (`repo`, `read:org`, `project`). They are
done **once**, by an organization owner, and never by widening a stored token:

| Id | Covers | Procedure (read-only) |
|---|---|---|
| A-1 | org secrets and variables: *Selected repositories* list (complements R10 / R11) | UI: Organization settings → Secrets and variables → Actions → each of the four entries → *Repository access*. CLI: needs the `admin:org` scope: `gh api orgs/TiPunchLabs/actions/secrets/<name>/repositories --jq '.repositories[].full_name'` (`variables/<name>/repositories` likewise) |
| A-2 | App installation: repository list (R14) | UI: Organization settings → GitHub Apps → FlowForge → **Configure** → *Repository access*. The `user/installations/<id>/repositories` API needs a GitHub App user token or a PAT |
| A-3 | App permissions, for an operator who is not an owner (replaces R2) | UI: the same page, *Permissions* |

If a CLI check is wanted, it is a **human decision** that uses a short-lived token: a
fine-grained token with an expiry of one day, *Organization permissions* → Secrets: read-only,
Variables: read-only, exported in the current shell only (`GH_TOKEN=… gh api …`), then revoked.
Never store it, and never run `gh auth refresh -s admin:org` on the everyday login: that makes
the scope permanent. Until A-1 / A-2 are done, the matching results stay as R10 / R11
(`REPO-SIDE`) and R14 `NOT_VERIFIED`.

**Ready to receive a first request** = no `FAIL`. `NOT_VERIFIED` is accepted only on:

- R14 until A-2 is done (the first App-authored PR then confirms it functionally, §6);
- R10 value validity on a new target, until the first run;
- R18, if the owner accepts it.

------

## 🚀 5. First request

**Before it**: readiness checks without `FAIL` (§4), and both target PRs **merged** on the
default branch: `SPEC.md` (R16, R18) and the pinned callers (R13). A `SPEC.md` still in an open PR
is invisible to the agents: the Refiner answers `NO_SPEC`, the Developer `SPEC contract: FAILED`.

1. Open an Issue in the target describing the need (or submit it from Notion, §9).
2. Refine it (human-started, never automatic):
   `gh workflow run flowforge-refine.yml -R $R -f issue_number=<n>`.
   `READY` rewrites the Issue; `NEEDS_CLARIFICATION` asks questions (answer in the Issue, re-run);
   `BLOCKED` comments. The Refiner never applies `agent:ready`.
3. A human reads the refined Issue and applies `agent:ready`: the Developer starts, checks
   `SPEC.md`, and opens a Draft PR on `agent/<issue>-<slug>`.
4. Review: `gh workflow run flowforge-review-cycle.yml -R $R -f pull_request_number=<pr>`
   (or `flowforge-review.yml` for a single review).
5. A human approves and merges; the lifecycle moves the Issue to `agent:done` and the card to `Done`.

------

## 🔍 6. Validation after the first run

| Check | Expected |
|---|---|
| Developer run summary | `SPEC contract: PASS` block; *Delivered by: `<app-slug>[bot] (GitHub App)`* |
| Draft PR author | `app/tipunchlabs-flowforge`: dated `FUNCTIONAL` confirmation of R14 (R14 itself needs A-2, §4.3) |
| Target CI on that PR | starts without the "Approve workflows to run" banner |
| `flowforge-review.yml` on that PR | skipped (bot actor) until a human acts or dispatches it |
| Review cycle with `REQUEST_CHANGES` | Iterator push starts CI, no extra `FlowForge review` run |
| Issue timeline | the App appears in no label event |
| Project card | `scripts/github-projects/sync-issue.sh $R <issue> --show` shows the expected Status |
| Merge | by a human, after an approval (ruleset); the required check, if set, is green |

------

## 🔧 7. Common errors

| Symptom | Cause | Fix |
|---|---|---|
| Developer stops with `SPEC contract: FAILED` | `SPEC.md` absent or incomplete on the base branch | fix `SPEC.md` (R16); the Issue keeps `agent:ready`, remove and re-apply it |
| Agent PR shows "Approve workflows to run" | `GITHUB_TOKEN` delivery: App variable/key not visible, or App not installed | R10, R11, R14 |
| Workflow fails at token creation | `FLOWFORGE_APP_CLIENT_ID` visible but the key is not (or the reverse), or a repository-level override, or the installation has not accepted a permission the token requests | R2, R10–R12 |
| Card never moves | `FLOWFORGE_PROJECT_NUMBER` unset/not visible, App lacks organization Projects permission | R2, R11; the job log has no `Project sync … update` line (a green step proves nothing, §4.1); sync warnings in the run summary ([synchronization.md §6](github-projects/synchronization.md)) |
| State label skipped with a warning | module not applied on the target | R7, `terraform apply` in the owning state |
| `terraform plan` wants to create existing labels / ruleset | existing objects not adopted | `import` blocks (§2.1) |
| Every `apply` changes the same labels back | the target is declared in two states | R6: keep one module block |
| Merge blocked forever | required check name ≠ CI job name, or CI has a `paths:` filter | R15, §2.4 |
| Agent push rejected | the change touches `.github/workflows/` (App has no `workflows` permission) | human change |
| Callers fail with `startup_failure` | Actions policy forbids external actions/reusable workflows | R5 |

------

## 📌 8. Reference installation: `demo-api`

Audited read-only on 2026-10-21 (Prompt 39.2): FlowForge `main` `3eba913`, `v0.1.0` = `afa60c5`;
`demo-api` `main` `d684829`. The account used is an organization owner with the default `gh`
scopes (`repo`, `read:org`, `project`, no `admin:org`). Nothing was modified.

| Check | Result | Evidence | Limitation |
|---|---|---|---|
| R1 | `PASS` | FlowForge `public` (`DIRECT`) | — |
| R2 | `PASS` | installation `tipunchlabs-flowforge`: contents / pull_requests / organization_projects `write`, metadata `read`, no `issues`, `suspended_at: null`, `repository_selection: selected` (`DIRECT`) | — |
| R3 | `PASS` | `bootstrap.sh --check`: *Project conforms to the model* (`DIRECT`) | read with the maintainer's token. The App's access is R2 plus the `FUNCTIONAL` lines below |
| R4 | `PASS` | `public`, `main`, Issues on (`DIRECT`) | — |
| R5 | `PASS` | `enabled: true`, `allowed_actions: all` (`DIRECT`) | — |
| R6 | `PASS` | module `flowforge` only in `02-infrastructure/demo-api/github-terraform`, source `…?ref=v0.1.0` (installed: same); its state holds 6 labels, ruleset, token settings; no module block in FlowForge root (`DIRECT`) | the IaC folder is not under Git |
| R7 | `PASS` | 6 `agent:*` labels (`DIRECT`) | — |
| R8 | `PASS` | `flowforge-default-branch` `active`, admin bypass `pull_request` mode (`DIRECT`) | — |
| R9 | `PASS` | `write`, `can_approve_pull_request_reviews: true` (`DIRECT`) | — |
| R10 | `PASS` | `CLAUDE_CODE_OAUTH_TOKEN` (updated 2026-10-15 22:33Z) and `FLOWFORGE_APP_PRIVATE_KEY` (2026-10-15 22:28Z) visible (`REPO-SIDE`). Validity `FUNCTIONAL`, newer than both dates: App tokens minted and an `APPROVE` produced on 2026-10-20 (runs below) | organization *Selected repositories* list not read (A-1). Validity holds as of 2026-10-20 |
| R11 | `PASS` | `FLOWFORGE_APP_CLIENT_ID` visible, `MATCH` with the App; `FLOWFORGE_PROJECT_NUMBER` visible, `1` = `config/github-project.json` (`REPO-SIDE` + `DIRECT`) | organization list not read (A-1) |
| R12 | `PASS` | 0 repository secrets, 0 repository variables (`DIRECT`) | — |
| R13 | `PASS` | 5 callers + CI `active`; all at `afa60c599fa47643bba45e26dad0e836b0375b69` (`v0.1.0`), with `project_number` and `app_client_id`, explicit secrets (`DIRECT`) | — |
| R14 | `NOT_VERIFIED` | `FUNCTIONAL` only: the App minted delivery and Project tokens for `demo-api` on 2026-10-20 (run `39356037326`) and authored PR #60 (2026-10-20 01:56Z) | repository list of the installation not read (A-2): needs the owner UI |
| R15 | `PASS` | required `Tests, lint and format` (15368) = CI job `name:` (`DIRECT`) | — |
| R16 | `PASS` | `flowforge-spec.sh` on `main`'s `SPEC.md`: `SPEC contract: PASS` (`DIRECT`) | structure only |
| R17 | `PASS` | `CLAUDE.md` present (`DIRECT`) | content not judged |
| R18 | `PASS` | `docs/flowforge-spec-review.md` present, `SPEC.md` merged by the owner (PR #56) | documentary |

**Project transitions, `FUNCTIONAL` (2026-10-20, Issue #58).** Read from the job logs. Every
line is `update`, with no warning:

| Run | Log label | Transition |
|---|---|---|
| `39356037326` Developer | `[Developer started]`, `[Draft PR delivered]` | `Status Ready → Developing`, then `Developing → Review` |
| `39452791058` stand-alone Reviewer (A4) | `[Reviewer APPROVE]` | `Status Review → Human validation` |
| `39454789555` lifecycle | `[Pull request merged]` | `Status Human validation → Done` |

Today `sync-issue.sh TiPunchLabs/demo-api 58 --show` gives `Done`, no Attention. The App's Project
tokens requested `organization-projects: write` and were granted (R2).

**Differences with the theory, all intentional (target choices, not drift):**

| Item | `demo-api` | Theory / examples | Status |
|---|---|---|---|
| Module source | `git::…?ref=v0.1.0` | Git source `?ref=vX.Y.Z` (§10) | aligned |
| Provider token | `token = var.github_token` (`TF_VAR_github_token` from `pass` via direnv) | FlowForge root: `GITHUB_TOKEN` env only | target's own IaC, never in a file: acceptable |
| `flowforge-review.yml` | `pull_request.branches: [main]` | no branch filter | stricter filter, compatible |
| `setup_uv`, `allowed_tools`, `review_/iterate_allowed_tools` | set (uv / pytest / ruff / pre-commit) | commented placeholders | project-specific by design |
| Callers' ref | full SHA of `v0.1.0` | full SHA of a tag (§10) | aligned (`demo-api` PR #62) |
| Organization Project linked to the repository | not linked (`projectsV2` empty) | not required: cards are added by the sync | aligned |

------

## 📥 9. Notion intake (optional)

Only if the target should receive Needs from Notion (Phase 7). The target itself gets **nothing**:
no Notion secret, no Notion workflow, no extra caller. Three central steps, all required
([notion/submission.md §8.4](notion/submission.md)):

1. add `owner/name` to `config/notion-allowlist.json` in FlowForge (pull request);
2. add the repository to the **FlowForge Notion Bridge** App installation;
3. add its row in Notion `FlowForge Repositories` (`FlowForge enabled` ✔, exactly one `Project`).

Validated with `demo-api-2` (Prompt 35, [milestone](milestones/phase7-notion-multiproject-e2e.md)).

------

## 🏷️ 10. Versions and updates

> ⚠️ **Warning**: `v0.1.0` is an **experimental POC version**. It has no production stability
> guarantee, and a later `0.x` version may change inputs, labels or behaviour. Read the changes
> before every update.

### 10.1 🧠 One version, two references, one commit

A FlowForge version is an annotated Git tag `vX.Y.Z` on a `main` commit whose PR is merged and
whose CI is green. There is no release automation and no GitHub Release is required.

| Consumer | Reference | Why |
|---|---|---|
| Terraform module (target IaC) | `git::https://github.com/TiPunchLabs/flowforge.git//terraform/modules/target-repository?ref=v0.1.0` | Terraform resolves Git tags natively, the version is readable in the IaC, and `terraform init` fetches exactly that tree. A local path would follow whatever branch the maintainer's FlowForge checkout is on |
| Caller workflows (target `.github/workflows/`) | `uses: TiPunchLabs/flowforge/.github/workflows/<file>.yml@<40-char SHA> # v0.1.0` | For Actions, branches and tags can be moved; a full commit SHA cannot. This is the rule FlowForge applies to third-party actions. The reusable workflows fetch their scripts at `job.workflow_sha`, so the SHA also pins the scripts |

Rules:

- The five callers use **the same SHA**, and it is the commit of the module tag. Short SHAs,
  branches or mixed versions are not allowed.
- A published tag is **never moved or deleted**. A fix ships as a new version (`v0.1.1`).
- The code that consumes the module stays in the target's IaC (one target = one state, §2.1).
  Never edit `.terraform/` by hand.

### 10.2 🔍 Identify the version in use

```bash
# Callers: one line per caller, all with the same SHA
grep -h "uses: TiPunchLabs/flowforge/" .github/workflows/flowforge-*.yml
# Commit behind a tag (annotated tag: ^{} dereferences to the commit)
git ls-remote https://github.com/TiPunchLabs/flowforge.git 'refs/tags/v0.1.0^{}'
# Module: declared source, then what init actually installed
grep -n 'target-repository' <iac>/*.tf
jq -r '.Modules[] | select(.Key != "") | .Source' <iac>/.terraform/modules/modules.json
```

### 10.3 📦 Publish a version (FlowForge maintainer)

```bash
# After the PR is merged and CI is green on main; only with the maintainer's explicit go-ahead.
git fetch origin && git rev-parse origin/main               # the candidate commit
git tag -a v0.1.0 <full-sha> -m "FlowForge v0.1.0 (experimental POC)"
git push origin v0.1.0
git ls-remote origin 'refs/tags/v0.1.0^{}'                  # must print <full-sha>
```

### 10.4 🔄 Update a target

1. **Read the changes**:
   `git log --oneline vOLD..vNEW` and
   `git diff vOLD vNEW -- .github/workflows/ examples/ terraform/modules/`.
   Changes to `workflow_call` inputs or secrets, or to the job `permissions:`, require the same
   change in the callers.
2. **Callers** (PR in the target): replace the SHA and the `# vX.Y.Z` comment in all five files.
   Adapt inputs only if the interface changed. New **optional** inputs are not reported by any
   tool: compare each caller with `examples/target-repository/` (e.g. callers copied before
   v0.1.0 lack the stand-alone Reviewer's Project inputs). Check the keys against the version:
   ```bash
   # Per caller: unknown with/secrets keys and missing required ones; all four lists must be empty.
   SHA=<full sha>; f=.github/workflows/flowforge-review.yml
   j=$(yq -o=json '.jobs[]' "$f" | jq -c '{uses, with:(.with//{}|keys), secrets:(.secrets//{}|keys)}')
   wf=$(jq -r '.uses|split("@")[0]|split("/")[-1]' <<<"$j")
   def=$(gh api "repos/TiPunchLabs/flowforge/contents/.github/workflows/$wf?ref=$SHA" --jq .content | base64 -d | yq -o=json '.on.workflow_call')
   jq -c --argjson d "$def" '($d.inputs//{}) as $I | ($d.secrets//{}) as $S | {
     unknown_inputs: [.with[] as $k | select($I|has($k)|not) | $k],
     unknown_secrets: [.secrets[] as $k | select($S|has($k)|not) | $k],
     missing_inputs: ([$I|to_entries[]|select(.value.required)|.key] - .with),
     missing_secrets: ([$S|to_entries[]|select(.value.required)|.key] - .secrets)}' <<<"$j"
   ```
3. **Terraform** (the owning IaC): set `?ref=vNEW`, then `terraform init`. It re-installs the
   module when its source changes; `-upgrade` is not needed and would also upgrade providers.
   Then `terraform validate` and `terraform plan`.
4. **Verify before merging and applying**:
   - the plan shows no destroy, no replace and no unexpected update;
   - the callers pass `actionlint` and their SHA exists:
     `gh api "repos/TiPunchLabs/flowforge/contents/.github/workflows/<file>.yml?ref=<sha>"`;
   - after the merge, readiness checks R7–R13 (§4) still `PASS`, and the next real run starts
     normally.
   No agent is started only to validate an update.

### 10.5 ⏪ Roll back

Versions are immutable, so the previous one is always available. Revert the callers PR (the
SHA goes back), set `?ref=vOLD` in the IaC, then `terraform init` and `terraform plan`, and
apply only after review. Never roll back by moving a tag.

> 💡 **Note**: to try an **unmerged** FlowForge branch on a target, use a temporary caller
> branch with `@<branch>`, started by `gh workflow run --ref` (dispatch callers only), and
> delete it afterwards, as done for Phase 8.2
> ([milestone](milestones/phase8-spec-refinement.md) §2). Pinned callers on the default branch
> are never changed for a test.

------

> **Document created on**: 2026-10-11
> **Author**: FlowForge maintainers (Issue #34, Phase 8 Prompts 39, 39.1, 39.2, 40)
> **Version**: 2.4 — header links the practical guide `GETTING_STARTED.md` (Prompt 41); 2.3: §3 / §5 `SPEC.md` and callers merged before the first refinement, §10.4 interface check and optional inputs (Prompt 40)
