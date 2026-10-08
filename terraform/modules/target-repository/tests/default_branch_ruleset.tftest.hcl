# Offline: mocked provider, no GitHub API call. Run with `terraform test` from the module dir.

mock_provider "github" {
  mock_data "github_repository" {
    defaults = {
      name           = "demo-api"
      full_name      = "example/demo-api"
      default_branch = "main"
    }
  }
}

variables {
  repository = "demo-api"
}

run "enabled_by_default" {
  command = plan

  assert {
    condition     = length(github_repository_ruleset.default_branch) == 1
    error_message = "The default-branch ruleset must be created by default."
  }

  assert {
    condition     = github_repository_ruleset.default_branch[0].target == "branch" && github_repository_ruleset.default_branch[0].enforcement == "active"
    error_message = "The ruleset must be an active branch ruleset."
  }

  assert {
    condition     = github_repository_ruleset.default_branch[0].conditions[0].ref_name[0].include == tolist(["~DEFAULT_BRANCH"])
    error_message = "The ruleset must target the default branch only (agent/* branches stay free)."
  }

  assert {
    condition     = github_repository_ruleset.default_branch[0].rules[0].deletion && github_repository_ruleset.default_branch[0].rules[0].non_fast_forward
    error_message = "Deletion and force pushes must be blocked."
  }

  assert {
    condition     = github_repository_ruleset.default_branch[0].rules[0].pull_request[0].required_approving_review_count == 1
    error_message = "One approving review must be required by default."
  }

  assert {
    condition     = github_repository_ruleset.default_branch[0].rules[0].pull_request[0].dismiss_stale_reviews_on_push
    error_message = "A push after an approval (e.g. an Iterator commit) must dismiss it."
  }

  assert {
    condition     = length(github_repository_ruleset.default_branch[0].bypass_actors) == 0
    error_message = "No bypass actor by default."
  }
}

run "admin_pull_request_bypass" {
  command = plan

  variables {
    admin_pull_request_bypass = true
  }

  assert {
    condition = (
      length(github_repository_ruleset.default_branch[0].bypass_actors) == 1 &&
      github_repository_ruleset.default_branch[0].bypass_actors[0].actor_type == "RepositoryRole" &&
      github_repository_ruleset.default_branch[0].bypass_actors[0].actor_id == 5 &&
      github_repository_ruleset.default_branch[0].bypass_actors[0].bypass_mode == "pull_request"
    )
    error_message = "The opt-in bypass must be the admin role, through pull requests only."
  }
}

run "disabled" {
  command = plan

  variables {
    default_branch_ruleset_enabled = false
  }

  assert {
    condition     = length(github_repository_ruleset.default_branch) == 0
    error_message = "No ruleset when disabled."
  }
}

run "zero_approvals_rejected" {
  command = plan

  variables {
    required_approving_review_count = 0
  }

  expect_failures = [var.required_approving_review_count]
}
