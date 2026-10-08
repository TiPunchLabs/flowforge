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

# Human merge gate (see README.md, "Default-branch ruleset"). Targets the default branch by
# reference, so it follows a rename. Agent branches (agent/*) are not matched.
resource "github_repository_ruleset" "default_branch" {
  count = var.default_branch_ruleset_enabled ? 1 : 0

  name        = "flowforge-default-branch"
  repository  = data.github_repository.target.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  # Never an agent identity: the workflow GITHUB_TOKEN is not a repository admin, and
  # bypass_mode "pull_request" never allows a direct push.
  dynamic "bypass_actors" {
    for_each = var.admin_pull_request_bypass ? [1] : []
    content {
      actor_id    = 5 # built-in "admin" repository role
      actor_type  = "RepositoryRole"
      bypass_mode = "pull_request"
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      required_approving_review_count   = var.required_approving_review_count
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }
  }
}

# Deliberately not implemented yet (see README.md, "Planned"):
# - required status checks on the default branch (no stable target check yet)
# - Actions permissions / allowed actions (github_actions_repository_permissions)
# - deployment environments (github_repository_environment), only if needed
# - Actions secrets: provisioned out of band, never through Terraform state
