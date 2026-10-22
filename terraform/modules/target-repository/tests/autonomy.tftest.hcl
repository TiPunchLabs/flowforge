# Offline: mocked provider, no GitHub API call. Autonomy configuration (docs/autonomy-contract.md §2.1).

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

run "supervised_by_default" {
  command = plan

  assert {
    condition     = length(github_actions_variable.autonomy_mode) == 0 && length(github_actions_variable.autonomy_owner) == 0
    error_message = "No autonomy variable when the inputs are null: the target stays SUPERVISED."
  }

  assert {
    condition     = output.autonomy_mode == "SUPERVISED"
    error_message = "The default mode is SUPERVISED."
  }

  assert {
    condition     = contains(keys(github_issue_label.flowforge_labels), "agent:manual")
    error_message = "The agent:manual opt-out label is created by default."
  }
}

run "semi_auto_with_owner" {
  command = plan

  variables {
    autonomy_mode  = "SEMI_AUTO"
    autonomy_owner = "repo-owner"
  }

  assert {
    condition = (
      github_actions_variable.autonomy_mode[0].variable_name == "FLOWFORGE_AUTONOMY_MODE" &&
      github_actions_variable.autonomy_mode[0].value == "SEMI_AUTO" &&
      github_actions_variable.autonomy_owner[0].variable_name == "FLOWFORGE_AUTONOMY_OWNER" &&
      github_actions_variable.autonomy_owner[0].value == "repo-owner"
    )
    error_message = "SEMI_AUTO creates both repository variables."
  }

  assert {
    condition     = output.autonomy_mode == "SEMI_AUTO"
    error_message = "The effective mode is SEMI_AUTO."
  }
}

run "semi_auto_without_owner_rejected" {
  command = plan

  variables {
    autonomy_mode = "SEMI_AUTO"
  }

  expect_failures = [github_actions_variable.autonomy_mode]
}

run "explicit_supervised" {
  command = plan

  variables {
    autonomy_mode = "SUPERVISED"
  }

  assert {
    condition     = github_actions_variable.autonomy_mode[0].value == "SUPERVISED" && length(github_actions_variable.autonomy_owner) == 0
    error_message = "An explicit SUPERVISED is written as is, without an owner."
  }
}

run "unknown_mode_rejected" {
  command = plan

  variables {
    autonomy_mode = "AUTO"
  }

  expect_failures = [var.autonomy_mode]
}

run "invalid_owner_rejected" {
  command = plan

  variables {
    autonomy_owner = "not a login"
  }

  expect_failures = [var.autonomy_owner]
}

run "autonomy_through_actions_variables_rejected" {
  command = plan

  variables {
    actions_variables = { FLOWFORGE_AUTONOMY_MODE = "SEMI_AUTO" }
  }

  expect_failures = [var.actions_variables]
}
