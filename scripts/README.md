# 🛠️ Scripts

Helper scripts for FlowForge maintainers (Bash, `set -euo pipefail`).

Empty in Phase 1. Candidates, to add only when a manual procedure is repeated:

- onboarding helper (copy the caller workflow into a target, check its `CLAUDE.md`);
- secret provisioning helper wrapping `gh secret set` (secrets never go through Terraform).

> 💡 **Note**: a script must never contain a token. Read credentials from the environment.
