# 🧩 Onboarding a target repository

> **Objective**: connect a GitHub repository (a *target*), existing or new, to FlowForge, so
> that its Issues can be refined, implemented as Draft PRs, reviewed and iterated on by the
> FlowForge agents, with the target's CI running on every agent PR.
> **Prerequisites**: admin access to the target repository; an organization owner for the
> one-time organization setup (§1) and for adding the target to existing lists (§2.3, §2.4);
> the target has its own CI (`pull_request` workflows).
> **Reference installation**: `TiPunchLabs/demo-api` (§8). This is the single onboarding
> reference; the future `GETTING_STARTED.md` will be derived from it.

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
| `SPEC.md` (root, default branch) | the functional contract: four sections, at least one behaviour and one scenario ([spec-contract.md](spec-contract.md)). **Required**: otherwise the Developer refuses to start (`SPEC contract: FAILED`) | the target owner (content); FlowForge checks the structure only |

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

Run before the first request. Each check is **read-only** and reuses an existing script or a
`gh api` read; none needs an organization-admin token unless stated.

| Result | Meaning |
|---|---|
| `PASS` | the check was actually run and the expected value observed |
| `FAIL` | a mandatory item is missing or wrong: fix before the first request |
| `NOT_VERIFIED` | the check could not be run (token scope, no run yet): never read as `PASS` |

```bash
R=TiPunchLabs/<target>   # owner/name
```

| # | Level | Check | Command | `PASS` when | `FAIL` when |
|---|---|---|---|---|---|
| R1 | A | FlowForge callable | `gh api repos/TiPunchLabs/flowforge --jq .visibility` | `public` | — (`private`: `NOT_VERIFIED`, check its Actions access settings) |
| R2 | A | App permissions | `gh api apps/tipunchlabs-flowforge --jq .permissions` | contents/pull_requests `write`, organization_projects `write`, **no** `issues` | `issues` present, or contents/pull_requests missing |
| R3 | A | Project conforms | `scripts/github-projects/bootstrap.sh --check` (scope `read:project`) | `Check: Project conforms to the model.` | any reported drift (only if `FLOWFORGE_PROJECT_NUMBER` is set) |
| R4 | B | Repository readable | `gh api repos/$R --jq '[.visibility,.default_branch,.has_issues]'` | readable, Issues enabled | 404, Issues disabled |
| R5 | B | Actions allowed | `gh api repos/$R/actions/permissions` | `enabled: true`, `allowed_actions: all` | disabled or `local_only` (`selected`: `NOT_VERIFIED`, inspect the list) |
| R6 | B | One IaC owner | `grep -rn 'target-repository' <target IaC> terraform/*.tf` and `terraform -chdir=<owning IaC> state list \| grep github_issue_label` (local state, no API) | exactly one state holds the module and its 6 labels | module in two places / none |
| R7 | B | Labels | `gh api repos/$R/labels --paginate --jq '.[].name' \| grep -c '^agent:'` | `6` | fewer (workflows then skip the state with a warning) |
| R8 | B | Merge gate | `gh api repos/$R/rulesets --jq '.[] \| [.name,.enforcement]'` | `flowforge-default-branch` `active` (or the documented replacement) | absent or not `active` |
| R9 | B | Token settings | `gh api repos/$R/actions/permissions/workflow` | `can_approve_pull_request_reviews: true` | `false` (blocks `GITHUB_TOKEN` delivery) |
| R10 | B | Secrets visible | `gh api repos/$R/actions/organization-secrets --jq '.secrets[].name'` | `CLAUDE_CODE_OAUTH_TOKEN` (+ `FLOWFORGE_APP_PRIVATE_KEY` with the App) | `CLAUDE_CODE_OAUTH_TOKEN` missing |
| R11 | B | Variables visible | `gh api repos/$R/actions/organization-variables --jq '.variables[] \| [.name,.value]'` | `FLOWFORGE_APP_CLIENT_ID` set; `FLOWFORGE_PROJECT_NUMBER` = `1` if the sync is wanted | client ID visible without the private key, or the reverse |
| R12 | B | No repository override | `gh api repos/$R/actions/secrets --jq '.secrets[].name'`; same with `variables` | none of the four names | any of them at repository level |
| R13 | B | Callers installed | `gh workflow list -R $R`, then per caller `yq '.jobs[].with \| keys' .github/workflows/flowforge-<x>.yml` on the default branch | 5 callers `active`, each with `project_number` and `app_client_id` (lifecycle: no agent inputs) | a caller missing, or a `secrets: inherit` |
| R14 | B | App installed on the target | not readable with a user token (`repos/$R/installation` needs an App JWT) | after the first run: Draft PR author `app/tipunchlabs-flowforge` (§6) | PR author `github-actions[bot]` while `FLOWFORGE_APP_CLIENT_ID` is set |
| R15 | B | Required check name | ruleset `required_status_checks[].context` (R8 detail) vs the CI job `name:` | identical, or no required check yet | different names (every merge blocked) |
| R16 | C | `SPEC.md` contract | `bash <flowforge>/.github/scripts/flowforge-spec.sh SPEC.md` on the default branch | `SPEC contract: PASS` | `FAILED` (`ERROR` = `NOT_VERIFIED`) |
| R17 | C | `CLAUDE.md` present | `gh api repos/$R/contents/CLAUDE.md --jq .name` | found | absent |
| R18 | C | `SPEC.md` validated by the owner | documentary: the owner answered `docs/flowforge-spec-review.md` and merged `SPEC.md` | owner confirms | — (otherwise `NOT_VERIFIED`) |

The organization-level lists themselves (`gh api orgs/<org>/actions/secrets/<name>/repositories`)
need the `admin:org` scope; R10–R12 read the same facts from the repository side and are enough.

**Ready to receive a first request** = no `FAIL`; `NOT_VERIFIED` only on R14 (resolved by the
first run) and, if accepted by the owner, R18.

------

## 🚀 5. First request

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
| Draft PR author | `app/tipunchlabs-flowforge` (closes R14) |
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
| Workflow fails at token creation | `FLOWFORGE_APP_CLIENT_ID` visible but the key is not (or the reverse), or a repository-level override | R10–R12 |
| Card never moves | `FLOWFORGE_PROJECT_NUMBER` unset/not visible, App lacks organization Projects permission | R2, R11; sync warnings in the run summary ([synchronization.md §6](github-projects/synchronization.md)) |
| State label skipped with a warning | module not applied on the target | R7, `terraform apply` in the owning state |
| `terraform plan` wants to create existing labels / ruleset | existing objects not adopted | `import` blocks (§2.1) |
| Every `apply` changes the same labels back | the target is declared in two states | R6: keep one module block |
| Merge blocked forever | required check name ≠ CI job name, or CI has a `paths:` filter | R15, §2.4 |
| Agent push rejected | the change touches `.github/workflows/` (App has no `workflows` permission) | human change |
| Callers fail with `startup_failure` | Actions policy forbids external actions/reusable workflows | R5 |

------

## 📌 8. Reference installation: `demo-api`

Audited read-only on 2026-10-20 (FlowForge `main` `3306d88`, `demo-api` `main` `aee9a87`). Not
modified.

| Check | Observed | Result |
|---|---|---|
| R1 | FlowForge `public` | `PASS` |
| R2 | contents / pull_requests / organization_projects `write`, metadata `read`, no `issues` | `PASS` |
| R3 | `Check: Project conforms to the model.` | `PASS` |
| R4 | `public`, default branch `main` | `PASS` |
| R5 | `enabled: true`, `allowed_actions: all` | `PASS` |
| R6 | module `flowforge` in `02-infrastructure/demo-api/github-terraform` only (same state as `github_repository.this`); FlowForge root declares no target; state holds the 6 labels, ruleset, token settings | `PASS` |
| R7 | 6 `agent:*` labels, colours as the module | `PASS` |
| R8 | `flowforge-default-branch` `active`, admin bypass `pull_request` mode (`admin_pull_request_bypass = true`) | `PASS` |
| R9 | `default_workflow_permissions: write`, `can_approve_pull_request_reviews: true` | `PASS` |
| R10 | `CLAUDE_CODE_OAUTH_TOKEN`, `FLOWFORGE_APP_PRIVATE_KEY` (organization) | `PASS` |
| R11 | `FLOWFORGE_APP_CLIENT_ID` set, `FLOWFORGE_PROJECT_NUMBER = 1` (organization) | `PASS` |
| R12 | no repository secret or variable | `PASS` |
| R13 | 5 callers + CI `active`; all pass `project_number` and `app_client_id`, including `flowforge-review.yml` (A4) | `PASS` |
| R14 | PRs #50, #53, #60 authored by `app/tipunchlabs-flowforge` | `PASS` (from runs) |
| R15 | required `Tests, lint and format` (15368) = CI job `name:` | `PASS` |
| R16 | `flowforge-spec.sh` on `main`'s `SPEC.md`: `SPEC contract: PASS` | `PASS` |
| R17 | `CLAUDE.md` present | `PASS` |
| R18 | `docs/flowforge-spec-review.md` present, `SPEC.md` merged by the owner (PR #56) | `PASS` (documentary) |
| Org-level visibility lists | `gh api orgs/TiPunchLabs/actions/...` → 403 without `admin:org` | `NOT_VERIFIED` (covered by R10–R12) |

**Differences with the theory, all intentional (target choices, not drift):**

| Item | `demo-api` | Theory / examples | Status |
|---|---|---|---|
| Module source | local path to the FlowForge working tree | Git source `?ref=v0.1.0` (§10) | change prepared (Prompt 39.1), applied by the maintainer after the tag: the IaC folder is not under Git |
| Provider token | `token = var.github_token` (`TF_VAR_github_token` from `pass` via direnv) | FlowForge root: `GITHUB_TOKEN` env only | target's own IaC, never in a file: acceptable |
| `flowforge-review.yml` | `pull_request.branches: [main]` | no branch filter | stricter filter, compatible |
| `setup_uv`, `allowed_tools`, `review_/iterate_allowed_tools` | set (uv / pytest / ruff / pre-commit) | commented placeholders | project-specific by design |
| Callers' ref | `@main` on `main` | full SHA of v0.1.0 (§10) | pinned by `demo-api` PR #62 (Prompt 39.1), to merge after the tag |
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
   Adapt inputs only if the interface changed.
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
> **Author**: FlowForge maintainers (Issue #34, Phase 8 Prompts 39, 39.1)
> **Version**: 2.1 — §10 versions and updates: module by tag, callers by full SHA, update and rollback (Prompt 39.1)
