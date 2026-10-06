# 🏗️ Terraform

Declarative GitHub configuration for the repositories onboarded into FlowForge.

```text
terraform/
├── versions.tf            # Terraform + integrations/github version constraints
├── providers.tf           # GitHub provider (owner only, no credentials)
├── variables.tf           # Root inputs
├── modules/
│   └── target-repository/ # Onboarding of ONE existing repository
└── environments/          # Per-environment inputs (reserved, see README)
```

The root module declares the targets that have **no Terraform of their own**, one
`module "<repo>"` block per target. Targets that already manage their repository with
Terraform embed `modules/target-repository` in their own IaC instead
(see [architecture.md §2.1](../docs/architecture.md#21-configuration-flow-terraform)).
A target is declared in exactly one of the two places. **No target is declared here yet.**

------

## 🔐 Authentication

No credential lives in this directory. The provider reads, in order:

1. `GITHUB_TOKEN` environment variable;
2. otherwise the token of the GitHub CLI (`gh auth token`).

```bash
# Fine-grained PAT read from your secret store, exported for the current shell only
read -rs GITHUB_TOKEN && export GITHUB_TOKEN
export TF_VAR_github_owner="<owner>"
```

> ⚠️ **Warning**: never write a token in a `.tf` or `.tfvars` file. `*.tfvars` is gitignored;
> commit `*.tfvars.example` with placeholders instead.

------

## 🛠️ Local validation (no external effect on GitHub)

```bash
terraform -chdir=terraform fmt -recursive -check
terraform -chdir=terraform init -backend=false   # downloads the provider only
terraform -chdir=terraform validate
```

`terraform plan` reads GitHub and needs a token; `terraform apply` **is not to be run in Phase 1 step 1**.

------

## 📝 State

- No remote backend for now: state is local and gitignored (`*.tfstate`).
- A remote backend (with locking and encryption) must be chosen **before** the first real `apply`.
- `.terraform.lock.hcl` is committed to pin provider versions.
