# 🛠️ Scripts

Helper scripts for FlowForge maintainers (Bash, `set -euo pipefail`).

| Script | Does |
|---|---|
| `github-projects/bootstrap.sh` | Creates or converges the GitHub Project `FlowForge Development`; `--check` reports drift (see `docs/github-projects/provisioning.md`) |

Candidates, to add only when a manual procedure is repeated:

- onboarding helper (copy the caller workflow into a target, check its `CLAUDE.md`);
- secret provisioning helper wrapping `gh secret set` (secrets never go through Terraform).

> 💡 **Note**: a script must never contain a token. Read credentials from the environment.
