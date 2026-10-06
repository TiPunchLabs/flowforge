terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  # Required in every module using this provider, otherwise Terraform may
  # resolve the deprecated hashicorp/github source.
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}
