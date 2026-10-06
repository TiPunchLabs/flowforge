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
  }

  validation {
    condition     = alltrue([for l in values(var.labels) : can(regex("^[0-9A-Fa-f]{6}$", l.color))])
    error_message = "Label colors must be 6-character hex codes without the leading '#'."
  }
}

variable "actions_variables" {
  description = "Non-secret GitHub Actions repository variables, keyed by variable name. Never put secrets here."
  type        = map(string)
  default     = {}
}
