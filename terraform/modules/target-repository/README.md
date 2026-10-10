# 🧩 Module `target-repository`

Onboards an **existing** GitHub repository as a FlowForge target.
The module never creates, renames, archives or deletes the repository itself.

------

## 🎯 Scope

| Concern | Status | Resource |
|---|---|---|
| Existence check of the target repo | ✅ Implemented | `data.github_repository` |
| FlowForge labels | ✅ Implemented | `github_issue_label` |
| Non-secret Actions variables | ✅ Implemented (empty by default) | `github_actions_variable` |
| Workflow token permissions (`GITHUB_TOKEN` default `write`, Actions may create PRs) | ✅ Implemented | `github_workflow_repository_permissions` |
| Default-branch ruleset (human merge gate) | ✅ Implemented (enabled by default) | `github_repository_ruleset` |
| Required status checks on the default branch | 📝 Planned, once targets have a stable CI check | `github_repository_ruleset` |
| Actions permissions / allowed actions | 📝 Planned | `github_actions_repository_permissions` |
| Deployment environments | 📝 Planned, only if needed | `github_repository_environment` |
| Actions secrets (`CLAUDE_CODE_OAUTH_TOKEN`, …) | 🚫 Out of Terraform | organization secret (Selected repositories), set manually or via `gh secret set --org` |

> ⚠️ **Warning**: secrets are deliberately kept out of Terraform. Anything passed to a
> `github_actions_secret` resource ends up in plain text in the Terraform state.

------

## 🏷️ Labels

| Label | Phase | Meaning |
|---|---|---|
| `agent:needs-clarification` | **5** | The Refiner returned `NEEDS_CLARIFICATION`: blocking questions wait for the requester |
| `agent:ready` | **1** | Issue is refined; adding this label triggers the Developer agent |
| `agent:running` | **1** | An agent is currently working on the issue |
| `agent:review` | **1** | A Draft PR is waiting for human review |
| `agent:blocked` | **1** | The agent cannot proceed and needs human input |
| `agent:done` | **4.1** | The agent PR was merged by a human; terminal state |

An Issue carries at most one of these state labels (lifecycle: `docs/architecture.md` §2.6).
`agent:ready` is set by a human; the Refiner, Developer, review-cycle and lifecycle workflows
switch the others.

> 💡 **Note**: adding a label to the module does not create it on targets already onboarded:
> the next `terraform plan` / `apply` of each target's own state does. Until then the
> workflows skip a missing state label with a warning.

------

## 📝 Usage

```hcl
module "demo_api" {
  source = "./modules/target-repository"

  repository = "demo-api"

  # Optional, non-secret only
  actions_variables = {
    FLOWFORGE_ENABLED = "true"
  }

  # Only if the target has a single human writer (see "Default-branch ruleset")
  admin_pull_request_bypass = true
}
```

### Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `repository` | `string` | — | Bare name of the existing repository |
| `labels` | `map(object({color, description}))` | the 6 `agent:*` state labels | Labels to manage |
| `actions_variables` | `map(string)` | `{}` | Non-secret Actions variables |
| `default_branch_ruleset_enabled` | `bool` | `true` | Manage the default-branch ruleset |
| `required_approving_review_count` | `number` | `1` | Approvals required to merge (1–10) |
| `admin_pull_request_bypass` | `bool` | `false` | Repository admins may bypass the ruleset **through a PR merge only** |

### Outputs

| Name | Description |
|---|---|
| `repository_full_name` | `owner/name` |
| `default_branch` | Default branch of the repository |
| `labels` | Managed label names |
| `default_branch_ruleset_id` | ID of the default-branch ruleset (`null` when disabled) |

------

## 🔐 Required token permissions

Fine-grained personal access token (or GitHub App) scoped to the target repositories only:

| Permission | Access | Why |
|---|---|---|
| Metadata | Read | Read the repository |
| Issues | Read & write | Manage labels |
| Variables | Read & write | Manage Actions variables |
| Administration | Read & write | Workflow token permissions; default-branch ruleset |

------

## 🛡️ Default-branch ruleset (human merge gate)

The FlowForge rule "agents never push to `main`, a human merges" is a convention in the agent
rules and workflows; this ruleset makes GitHub enforce it.

```text
agent/* branch ──push──► allowed (not matched by the ruleset)
       │
       ▼
Draft PR ─► Reviewer ↔ Iterator ─► FlowForge result APPROVED
       │                              (a PR comment, not a GitHub review)
       ▼
human GitHub approval (≥ 1) ─► human merge ─► default branch
```

| Setting | Value | Why |
|---|---|---|
| Name | `flowforge-default-branch` | One ruleset per target, owned by the target's state |
| Target | `~DEFAULT_BRANCH` | Follows the repository's default branch; `agent/*` branches are never matched |
| Enforcement | `active` | |
| Pull request required | yes | No direct push to the default branch, for anyone |
| Required approving reviews | `1` (`required_approving_review_count`) | At least one explicit human approval |
| Dismiss stale approvals on push | yes | An Iterator (or any) push after an approval requires a new one |
| Last-push approval, code owners, thread resolution | no | Kept simple for the POC; the Reviewer posts a comment, not review threads |
| Force push (`non_fast_forward`) | blocked | |
| Deletion | blocked | |
| Required status checks | none | No stable target check yet; a missing check would block every merge |
| Bypass actors | none by default | FlowForge never gets a bypass |

**Why agents cannot satisfy the gate.**

- The FlowForge Reviewer posts a PR **comment** with its verdict, never a GitHub review:
  Reviewer `APPROVE` ≠ GitHub approval.
- Agent PRs are opened with the workflow `GITHUB_TOKEN` (author `github-actions[bot]`);
  GitHub forbids a PR author from approving its own PR, and no FlowForge workflow calls
  `gh pr review --approve`, `gh pr merge` or enables auto-merge.
- Only approvals from accounts with **write** access count.

**`admin_pull_request_bypass` (opt-in).** On a solo-maintainer target, the only writer
cannot approve their own PRs. With this flag the built-in *admin* repository role may bypass
the ruleset with `bypass_mode = "pull_request"`: an admin can merge a PR without approval
(GitHub shows an explicit bypass checkbox), but **never push directly** to the default
branch. The workflow `GITHUB_TOKEN` is not a repository admin, so agents still cannot
bypass. Keep it `false` when the target has at least two human writers.

> ⚠️ **Warning**: without the bypass, nobody bypasses the ruleset, including organization
> owners; they can still edit or disable it in the repository settings (or through this
> module), which is visible in the audit log.
>
> 💡 **Note**: a Draft PR cannot be merged anyway; promoting it to *Ready for review* stays a
> human action (the Developer workflow only ever forces PRs back to draft).

------

## 🔑 Workflow token permissions

`can_approve_pull_request_reviews = true` is required: the Developer agent opens its Draft
PR with the workflow `GITHUB_TOKEN`, which GitHub otherwise forbids from creating PRs.

> ⚠️ **Warning**: the same setting also lets workflows **approve** PRs. The default-branch
> ruleset requires an approval that the agent identity cannot provide (it authors agent PRs,
> and an author cannot approve its own PR); no FlowForge workflow submits approvals.

### 🚨 Point of attention: `default_workflow_permissions = "write"`

Kept deliberately (2026-10-06), but it **fails open**: any workflow of the target without a
`permissions:` block gets a `GITHUB_TOKEN` with write access (contents, issues, PRs,
packages…).

| Today | Later |
|---|---|
| No effect: FlowForge workflows and the caller declare explicit permissions | A workflow added without `permissions:` (e.g. a template `ci.yml`) can push branches, edit releases or issues if compromised (third-party action, script injection) — not the default branch, which the ruleset protects |

Mitigations in place: fork PRs always get a read-only token; `GITHUB_TOKEN` can never modify
`.github/workflows/`; the default-branch ruleset blocks direct pushes to the default branch.
The rest (other branches, issues, releases) stays writable, so **every new workflow in a
target must still declare `permissions:`** — or switch this default to `"read"` (FlowForge
does not depend on `"write"`).
