# 🚀 Phase 1 — From Issue to Draft PR

> **Goal**: one real target repository (`demo-api`) where adding `agent:ready` to an Issue
> produces a Draft Pull Request, validated by a human.

------

## 🎯 Definition of done

- An Issue *"Add GET /health"* in `demo-api`, labeled `agent:ready`;
- a branch `agent/<n>-add-get-health` created automatically;
- code **and** tests, CI green;
- a **Draft** PR linked to the Issue;
- reviewed and merged by a human.

------

## 🗺️ Steps

| # | Step | Where | Status |
|---|---|---|---|
| 1 | Initialize FlowForge (structure, Terraform skeleton, reusable workflow skeleton, agent rules, docs, quality tooling) | `flowforge` | ✅ Done |
| 2 | Create the POC `demo-api` (Python, FastAPI, pytest, CI, `CLAUDE.md`) — `GET /health` deliberately absent | `demo-api` | ⏭️ Next |
| 3 | Onboard `demo-api` with Terraform (embedded `module "flowforge"`, labels; ruleset decided here) | `demo-api` IaC | 🔄 Integrated, not applied |
| 4 | Add the minimal caller workflow `flowforge-agent.yml` in `demo-api` | `demo-api` | ⏳ |
| 5 | Integrate Claude Code in `agent-develop.yml` (runner choice, secret, write permissions, agent rules loading) | `flowforge` | ⏳ |
| 6 | First real end-to-end run | both | ⏳ |
| 7 | Create the Issue *"Add GET /health"* | `demo-api` | ⏳ |
| 8 | Add the `agent:ready` label | `demo-api` | ⏳ |
| 9 | Draft PR created automatically | `demo-api` | ⏳ |
| 10 | Human validation (review, CI, merge) | `demo-api` | ⏳ |

------

## 📝 Step details

### Step 2 — `demo-api`

```text
demo-api/
├── src/demo_api/      # FastAPI app: CRUD /tasks (in-memory or SQLite)
├── tests/             # pytest
├── CLAUDE.md          # stack, commands, conventions
├── pyproject.toml     # uv, ruff, pytest
└── .github/workflows/ci.yml
```

`GET /health` is left out on purpose: it is the first feature the agent will implement.

### Step 3 — Terraform onboarding

- **Embedded mode**: `demo-api` already manages its repository with Terraform
  (`~/Workspace/02-infrastructure/demo-api/github-terraform`), so the module is declared
  there, in the same state, not in the FlowForge root.
- Requires a token able to manage labels on `demo-api` (see `terraform/modules/target-repository/README.md`).
- State: local in the `demo-api` IaC (same as its repository resource).
- First `apply` of the project: reviewed `plan` first (expected: 4 labels to add).

### Step 5 — Claude Code integration

Decisions to take (see [architecture.md §5](architecture.md#5--open-design-decisions)):

- execution mechanism for Claude Code;
- credentials (`ANTHROPIC_API_KEY` or equivalent) stored as a target secret;
- job permissions raised to `contents: write`, `pull-requests: write`, `issues: write`;
- how `agents/developer.md` is delivered to the run.

------

## 🚫 Out of scope for Phase 1

Reviewer agent · Iterator agent · Refiner agent · GitHub Project · Notion integration ·
multi-owner environments · release/tagging of FlowForge.
