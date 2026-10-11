# 🧩 Onboarding a target repository

> **Objective**: connect an existing GitHub repository (a *target*) to FlowForge, so that its
> Issues can be refined, implemented as Draft PRs, reviewed and iterated on by the FlowForge
> agents, with the target's CI running on every agent PR.
> **Prerequisites**: admin access to the target repository and to the GitHub organization
> that owns it; the target has its own CI (`pull_request` workflows).
> Reference target: `TiPunchLabs/demo-api`.

------

## 🧠 Mental Model

```text
  Organization (TiPunchLabs)                       Target repository (×N)
  ──────────────────────────                       ──────────────────────
  GitHub App "FlowForge" (ONE for all targets) ──► installed on: target-1, target-2, …
  org secret   CLAUDE_CODE_OAUTH_TOKEN      ──┐
  org secret   FLOWFORGE_APP_PRIVATE_KEY    ──┼──► visible to: Selected repositories
  org variable FLOWFORGE_APP_CLIENT_ID      ──┘
                                                   Terraform module target-repository
                                                     labels agent:*, ruleset, token settings
                                                   CLAUDE.md          (project rules)
                                                   .github/workflows/flowforge-*.yml
                                                     thin callers copied from examples/
```

Adding a target never creates a new App, key or secret: the target is **added to existing
lists** (App installation, secret/variable visibility) and receives its own thin callers.

------

## 📋 Table of contents

1. Terraform: labels, ruleset, token settings
2. Secrets and variables
3. FlowForge GitHub App (delivery identity)
4. Caller workflows
5. Project rules: CLAUDE.md
6. Validation

------

## 🏗️ 1. Terraform: labels, ruleset, token settings

Onboard the repository with the `target-repository` module, either in the target's own IaC
or in FlowForge's `terraform/` root (one module block per target, never both). It creates the
`agent:*` state labels, the default-branch ruleset (human merge gate) and the workflow token
settings. Details and inputs: [`terraform/modules/target-repository/README.md`](../terraform/modules/target-repository/README.md).

> ⚠️ **Warning**: `terraform apply` changes a real repository; run it only after reviewing
> the plan. Terraform never manages Actions secrets (they would land in plain-text state).

------

## 🔐 2. Secrets and variables

Store them **once, at organization level**, with *Selected repositories* visibility, and add
each new target to the list. Never copy them per repository unless the target is outside the
organization.

| Name | Kind | Used by | Required |
|---|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | secret | every agent (`claude setup-token`) | yes |
| `FLOWFORGE_APP_PRIVATE_KEY` | secret | Developer and Iterator delivery (§3) | recommended |
| `FLOWFORGE_APP_CLIENT_ID` | variable | Developer and Iterator delivery (§3) | recommended |

```bash
# First target: create them (org admin). The .pem never goes into Git.
gh secret set CLAUDE_CODE_OAUTH_TOKEN --org TiPunchLabs --visibility selected --repos demo-api
gh secret set FLOWFORGE_APP_PRIVATE_KEY --org TiPunchLabs --visibility selected --repos demo-api < flowforge.pem
gh variable set FLOWFORGE_APP_CLIENT_ID --org TiPunchLabs --visibility selected --repos demo-api --body "Iv23..."

# Next targets: add the repository to the visibility list of each secret/variable
# (Organization settings → Secrets and variables → Actions → the entry → Repository access).
```

> 💡 **Note**: `demo-api` currently holds `FLOWFORGE_APP_PRIVATE_KEY` and
> `FLOWFORGE_APP_CLIENT_ID` as **repository** secret/variable. It works the same way; move
> them to the organization when a second target is onboarded.

------

## 🤖 3. FlowForge GitHub App (delivery identity)

### 3.1 Why an App

Workflows that push or open a PR with `GITHUB_TOKEN` create the target's `pull_request` runs
in an **approval-required** state ("Approve workflows to run"): agent PRs get no CI unless a
human approves every run. With a GitHub App installation token, the push and the PR are made
by `<app-slug>[bot]` and the target's CI runs normally (FlowForge Issue #34).

Only **delivery** uses the App: the Developer's branch push + Draft PR creation, and the
Iterator's fast-forward push. Claude never receives the App token: it commits locally, the
workflow verifies the commits and delivers. Labels and comments always use `GITHUB_TOKEN`.

### 3.2 One App for all targets

There is **one** FlowForge App, owned by the organization. A new target is added to its
installation; no new App, no new key. Each run mints a short-lived token (about 1 h)
restricted to the **calling repository** and to the delivery permissions only, so a run on
one target can never write to another.

| App setting | Value |
|---|---|
| Owner | the organization (TiPunchLabs) |
| Webhook | inactive |
| Repository permissions | Contents: read & write, Pull requests: read & write, Metadata: read |
| Issues permission | **none** (anti-loop rule 1, §3.3) |
| Where can it be installed | Only on this account |
| Installation | *Only select repositories*: every onboarded target, nothing else |

To add a target: Organization settings → GitHub Apps → the FlowForge App → **Configure** →
*Repository access* → add the repository.

> ⚠️ **Warning**: "Only on this account" means only repositories of this organization. A
> target owned by another account needs either a second App owned by that account, or the
> App made installable on any account.

> ⚠️ **Warning**: the App has no `workflows` permission. An agent commit that changes
> `.github/workflows/` is rejected at push time; such changes stay human work.

### 3.3 Anti-loop rules (must hold on every target)

With an App token, `pull_request` events start workflows again. These rules keep agents
from triggering each other without a human:

1. **The App never touches labels or Issues** (no `issues` permission). Otherwise it could
   apply `agent:ready` and restart the Developer.
2. **The review caller ignores every bot actor** (`!endsWith(github.actor, '[bot]')` in
   `flowforge-review.yml`). Otherwise each Iterator push starts a Reviewer outside the cycle.
3. **The review cycle stays human-started** (`workflow_dispatch` only). An automatic start on
   push would give Iterator → push → cycle → Iterator.

### 3.4 Without the App

The App is optional: if `FLOWFORGE_APP_CLIENT_ID` is empty, FlowForge delivers with
`GITHUB_TOKEN` as before. Everything works, but agent PRs show "Approve workflows to run"
and their CI needs a manual approval. The module's `can_approve_pull_request_reviews = true`
remains needed for that mode (GITHUB_TOKEN may then create PRs).

------

## 📝 4. Caller workflows

Copy the five callers from [`examples/target-repository/`](../examples/target-repository/)
into the target's `.github/workflows/`, replace `OWNER`, and set the project-specific inputs
(`setup_uv`, `allowed_tools`).

| File | Trigger | Passes the App |
|---|---|---|
| `flowforge-agent.yml` | `issues: labeled` (`agent:ready`) | yes (`app_client_id`, `app_private_key`) |
| `flowforge-review-cycle.yml` | `workflow_dispatch` | yes, for the Iterator push |
| `flowforge-review.yml` | `workflow_dispatch` + human `pull_request` activity | no (read-only Reviewer) |
| `flowforge-refine.yml` | `workflow_dispatch` | no (Refiner never pushes) |
| `flowforge-lifecycle.yml` | `pull_request: closed` | no |

Secrets are always passed explicitly, never with `secrets: inherit`.

------

## 📖 5. Project rules: CLAUDE.md

Add a `CLAUDE.md` at the target's root: stack, test/lint/format commands, conventions. The
agents read it first; FlowForge's own rules (`agents/`) stay generic.

------

## ✅ 6. Validation

| Check | Expected |
|---|---|
| `agent:ready` on a refined Issue | one Developer run; Draft PR authored by `<app-slug>[bot]` |
| Target CI on that PR | starts without the "Approve workflows to run" banner |
| `flowforge-review.yml` on that PR | skipped (bot actor) until a human acts or dispatches it |
| Review cycle with `REQUEST_CHANGES` | Iterator push starts CI, no extra `FlowForge review` run |
| Issue timeline | the App appears in no label event |
| Merge | by a human, after an approval (ruleset) |

> 💡 **Note**: the Developer run summary shows *Delivered by: `<app-slug>[bot] (GitHub App)`*
> or *`GITHUB_TOKEN`*, which tells at a glance whether the App was used.

------

> **Document created on**: 2026-10-11
> **Author**: FlowForge maintainers (Issue #34)
> **Version**: 1.0
