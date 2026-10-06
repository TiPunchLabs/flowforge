# Onboards an EXISTING repository into FlowForge.
# This module never creates or deletes the repository itself.

# Fails the plan early if the target repository does not exist or is not readable.
data "github_repository" "target" {
  name = var.repository
}

resource "github_issue_label" "flowforge_labels" {
  for_each = var.labels

  repository  = data.github_repository.target.name
  name        = each.key
  color       = each.value.color
  description = each.value.description
}

resource "github_actions_variable" "flowforge_variables" {
  for_each = var.actions_variables

  repository    = data.github_repository.target.name
  variable_name = each.key
  value         = each.value
}

resource "github_workflow_repository_permissions" "workflow_permissions" {
  repository = data.github_repository.target.name

  # Fails open for workflows without `permissions:` — see README, "Point of attention".
  default_workflow_permissions     = "write"
  can_approve_pull_request_reviews = true
}

# Deliberately not implemented yet (see README.md, "Planned"):
# - branch ruleset on the default branch (github_repository_ruleset)
# - Actions permissions / allowed actions (github_actions_repository_permissions)
# - deployment environments (github_repository_environment), only if needed
# - Actions secrets: provisioned out of band, never through Terraform state
