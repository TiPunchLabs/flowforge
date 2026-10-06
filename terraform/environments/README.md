# 🌍 Environments

Reserved for per-environment inputs once FlowForge manages more than one owner or context
(e.g. a personal account and an organization).

Not used in Phase 1: a single owner, declared through `TF_VAR_github_owner`.

## Intended convention

```text
environments/
├── personal.tfvars.example   # committed, placeholders only
└── personal.tfvars           # local, gitignored
```

```bash
terraform -chdir=terraform plan -var-file=environments/personal.tfvars
```

> 💡 **Note**: whether environments become separate root modules (separate states) or
> `-var-file` variants of one root module will be decided when a second owner appears.
> Do not anticipate it before that.
