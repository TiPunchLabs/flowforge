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
| Branch protection on the default branch | 📝 Planned | `github_repository_ruleset` |
| Actions permissions / allowed actions | 📝 Planned | `github_actions_repository_permissions` |
| Deployment environments | 📝 Planned, only if needed | `github_repository_environment` |
| Actions secrets (`CLAUDE_CODE_OAUTH_TOKEN`, …) | 🚫 Out of Terraform | organization secret (Selected repositories), set manually or via `gh secret set --org` |

> ⚠️ **Warning**: secrets are deliberately kept out of Terraform. Anything passed to a
> `github_actions_secret` resource ends up in plain text in the Terraform state.

------

## 🏷️ Labels

| Label | Phase | Meaning |
|---|---|---|
| `agent:ready` | **1** | Issue is refined; adding this label triggers the Developer agent |
| `agent:running` | 2+ | An agent is currently working on the issue |
| `agent:review` | 2+ | A Draft PR is waiting for human review |
| `agent:blocked` | 2+ | The agent cannot proceed and needs human input |

Only `agent:ready` is used by the Phase 1 workflow. The others are created now so
that the label set is stable when later phases start using them.

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
}
```

### Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `repository` | `string` | — | Bare name of the existing repository |
| `labels` | `map(object({color, description}))` | the 4 `agent:*` labels | Labels to manage |
| `actions_variables` | `map(string)` | `{}` | Non-secret Actions variables |

### Outputs

| Name | Description |
|---|---|
| `repository_full_name` | `owner/name` |
| `default_branch` | Default branch of the repository |
| `labels` | Managed label names |

------

## 🔐 Required token permissions

Fine-grained personal access token (or GitHub App) scoped to the target repositories only:

| Permission | Access | Why |
|---|---|---|
| Metadata | Read | Read the repository |
| Issues | Read & write | Manage labels |
| Variables | Read & write | Manage Actions variables |
| Administration | Read & write | Rulesets (only once implemented) |

------

## 📝 Planned: default-branch ruleset

To be decided with the first real target. Intended shape:

- target: default branch (`~DEFAULT_BRANCH`);
- block deletion and force pushes;
- require a pull request with at least one human approval;
- require the target repo's CI status checks;
- no bypass actor for the agent identity.

This is what technically enforces "agents never push to `main`" and "a human merges".
