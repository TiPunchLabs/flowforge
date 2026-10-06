# Authentication is never configured here.
# The provider reads the token from the GITHUB_TOKEN environment variable
# (or from `gh auth token` when GITHUB_TOKEN is unset).
provider "github" {
  owner = var.github_owner
}
