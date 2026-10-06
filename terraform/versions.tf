terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }

  # No remote backend yet: state stays local and is gitignored.
  # A remote backend will be chosen before the first real `terraform apply`.
}
