variable "repository" {
  description = "Name of an EXISTING repository to onboard (without the owner prefix)."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+$", var.repository))
    error_message = "repository must be a bare repository name, e.g. \"demo-api\"."
  }
}

variable "labels" {
  description = "FlowForge issue labels managed on the repository, keyed by label name."
  type = map(object({
    color       = string
    description = string
  }))

  default = {
    "agent:needs-clarification" = {
      color       = "D876E3"
      description = "FlowForge: the Refiner needs answers before the issue can be ready"
    }
    "agent:ready" = {
      color       = "0E8A16"
      description = "FlowForge: issue is refined and can be picked up by the Developer agent"
    }
    "agent:running" = {
      color       = "1D76DB"
      description = "FlowForge: an agent is currently working on this issue"
    }
    "agent:review" = {
      color       = "FBCA04"
      description = "FlowForge: a Draft PR is waiting for human review"
    }
    "agent:blocked" = {
      color       = "B60205"
      description = "FlowForge: the agent cannot proceed and needs human input"
    }
    "agent:done" = {
      color       = "8250DF"
      description = "FlowForge: the agent PR was merged by a human; the work is done"
    }
    # Control label, not a state label: forces human validation (no automatic start).
    "agent:manual" = {
      color       = "5319E7"
      description = "FlowForge: never start the Developer automatically; a human applies agent:ready"
    }
  }

  validation {
    condition     = alltrue([for l in values(var.labels) : can(regex("^[0-9A-Fa-f]{6}$", l.color))])
    error_message = "Label colors must be 6-character hex codes without the leading '#'."
  }
}

variable "actions_variables" {
  description = "Non-secret GitHub Actions repository variables, keyed by variable name. Never put secrets here. The autonomy variables are set through autonomy_mode / autonomy_owner only."
  type        = map(string)
  default     = {}

  validation {
    condition     = !contains(keys(var.actions_variables), "FLOWFORGE_AUTONOMY_MODE") && !contains(keys(var.actions_variables), "FLOWFORGE_AUTONOMY_OWNER")
    error_message = "Set FLOWFORGE_AUTONOMY_MODE / FLOWFORGE_AUTONOMY_OWNER with autonomy_mode / autonomy_owner, not actions_variables."
  }
}

variable "autonomy_mode" {
  description = "FlowForge autonomy mode (docs/autonomy-contract.md): null (default, no variable, SUPERVISED), \"SUPERVISED\" or \"SEMI_AUTO\" (LOW-risk requests of autonomy_owner may start the Developer without a human agent:ready). SEMI_AUTO requires autonomy_owner."
  type        = string
  default     = null

  validation {
    condition     = var.autonomy_mode == null || contains(["SUPERVISED", "SEMI_AUTO"], coalesce(var.autonomy_mode, "SUPERVISED"))
    error_message = "autonomy_mode must be null, \"SUPERVISED\" or \"SEMI_AUTO\"."
  }
}

variable "autonomy_owner" {
  description = "GitHub login of the repository's human owner, the only person whose own Issues, refined on their own dispatch, may start automatically in SEMI_AUTO. null: no variable."
  type        = string
  default     = null

  validation {
    condition     = var.autonomy_owner == null || can(regex("^[A-Za-z0-9](-?[A-Za-z0-9]){0,38}$", coalesce(var.autonomy_owner, "x")))
    error_message = "autonomy_owner must be a GitHub user login (letters, digits, single hyphens, at most 39 characters)."
  }
}

variable "default_branch_ruleset_enabled" {
  description = "Manage the FlowForge ruleset on the default branch (pull request + human approval, no force push, no deletion). Disable only if the target protects its default branch elsewhere."
  type        = bool
  default     = true
}

variable "required_approving_review_count" {
  description = "Approving reviews required to merge into the default branch. At least 1: FlowForge agents never provide it."
  type        = number
  default     = 1

  validation {
    condition     = var.required_approving_review_count >= 1 && var.required_approving_review_count <= 10 && floor(var.required_approving_review_count) == var.required_approving_review_count
    error_message = "required_approving_review_count must be a whole number between 1 and 10."
  }
}

variable "admin_pull_request_bypass" {
  description = "Let repository admins bypass the default-branch ruleset when merging a pull request (never for direct pushes). For solo-maintainer targets; agent identities are never admins."
  type        = bool
  default     = false
}

variable "required_status_checks" {
  description = "Status checks (check run names, e.g. the target CI job name) that must pass before merging into the default branch. integration_id pins the source app (15368 = GitHub Actions). Empty: none. Set only when the FlowForge GitHub App delivers agent PRs, otherwise their CI never runs on its own."
  type = list(object({
    context        = string
    integration_id = optional(number)
  }))
  default = []

  validation {
    condition     = alltrue([for c in var.required_status_checks : trimspace(c.context) != ""])
    error_message = "Every required status check needs a non-empty context."
  }
}
