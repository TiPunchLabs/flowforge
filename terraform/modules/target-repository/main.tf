# Onboards an EXISTING repository into FlowForge.
# This module never creates or deletes the repository itself.

# Fails the plan early if the repository does not exist or is not readable.
data "github_repository" "this" {
  name = var.repository
}

resource "github_issue_label" "flowforge" {
  for_each = var.labels

  repository  = data.github_repository.this.name
  name        = each.key
  color       = each.value.color
  description = each.value.description
}

resource "github_actions_variable" "this" {
  for_each = var.actions_variables

  repository    = data.github_repository.this.name
  variable_name = each.key
  value         = each.value
}

# Deliberately not implemented yet (see README.md, "Planned"):
# - branch ruleset on the default branch (github_repository_ruleset)
# - Actions permissions / allowed actions (github_actions_repository_permissions)
# - deployment environments (github_repository_environment), only if needed
# - Actions secrets: provisioned out of band, never through Terraform state
