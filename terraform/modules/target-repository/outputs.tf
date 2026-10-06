output "repository_full_name" {
  description = "owner/name of the onboarded repository."
  value       = data.github_repository.this.full_name
}

output "default_branch" {
  description = "Default branch of the onboarded repository."
  value       = data.github_repository.this.default_branch
}

output "labels" {
  description = "Names of the FlowForge labels managed on the repository."
  value       = sort(keys(github_issue_label.flowforge))
}
