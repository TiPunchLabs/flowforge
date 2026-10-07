# 🏗️ FlowForge — Architecture

> **Status**: Phases 1–3 done (Foundation, Developer E2E, Reviewer E2E); Phase 4 Iterator in progress — specification defined, workflow and loop not implemented. Describes the target design; see [phase-1.md](phase-1.md) for what exists today.

------

## 🧠 Mental Model

```text
           ┌──────────────────────── FlowForge (central) ────────────────────────┐
           │  terraform/            .github/workflows/        agents/            │
           │  target-repository     agent-develop.yml         developer.md       │
           │  module                agent-review.yml          reviewer.md        │
           │                        (workflow_call)           (generic rules)    │
           └──────┬───────────────────────────┬───────────────────────────────────┘
                  │ configures                │ is called by
                  ▼                           │
           ┌───────────── target repository (×N) ──────────────┐
           │  labels, variables, rulesets ◄── Terraform        │
           │  CLAUDE.md                     (project rules)    │
           │  .github/workflows/flowforge-agent.yml  ──────────┘ (≈ 20 lines, no logic)
           └───────────────────────────────────────────────────┘
```

**One FlowForge → N target repositories.** A target never holds a copy of FlowForge:
it holds only its code, its `CLAUDE.md` and a thin caller workflow.

------

## 1. 🧩 Components

| Component | Location | Responsibility |
|---|---|---|
| Terraform module | `terraform/modules/target-repository` | Onboard an existing repo: labels, Actions variables, later rulesets / permissions / environments |
| Terraform root | `terraform/` | Onboards targets that have **no** Terraform of their own (one module block per target) |
| Reusable workflow | `.github/workflows/agent-develop.yml` | Resolve the issue context, run Claude Code, produce branch + Draft PR |
| Reusable workflow | `.github/workflows/agent-review.yml` | Resolve the PR + Issue context, run Claude Code read-only, publish one review comment + JSON artifact |
| Agent rules | `agents/*.md` | Generic, project-independent behavior of each agent: `developer.md`, `reviewer.md`, `iterator.md` (defined, not run yet) |
| Caller templates | `examples/target-repository/` | What a target repository copies (`flowforge-agent.yml`, `flowforge-review.yml`) |
| Target `CLAUDE.md` | in each target | Project-specific conventions (stack, commands, layout) |

------

## 2. 🔀 Flows

### 2.1 Configuration flow (Terraform)

```text
FlowForge central
        │  terraform plan / apply (human, with a scoped token)
        ▼
Terraform  ── module "target-repository" per target
        │
        ▼
GitHub configuration of the target repo
   (agent:* labels, Actions variables, rulesets later)
```

A target is onboarded in **exactly one** Terraform state, in one of two modes:

| Mode | When | Where the `module` block lives |
|---|---|---|
| **Embedded** (preferred) | The target already manages its repository with Terraform | The target's own IaC, next to its `github_repository`, with `repository = github_repository.<x>.name` |
| **Central** | The target has no Terraform of its own | FlowForge `terraform/` root |

> ⚠️ **Warning**: declaring the same target in both places makes two states manage the
> same labels and rulesets; every `apply` would undo the other one.
>
> 💡 **Note**: in embedded mode the module is consumed by path or Git source
> (`git::…//terraform/modules/target-repository?ref=vX.Y.Z`); the repository creation and
> its onboarding then share one dependency graph, one token and one `apply`.

### 2.2 Development flow (Phase 1 target)

```text
Target repo
        │  human writes an Issue, then adds label agent:ready
        ▼
Issue + agent:ready
        │  `issues: labeled` event
        ▼
Minimal local workflow   (.github/workflows/flowforge-agent.yml)
        │  uses: OWNER/flowforge/.github/workflows/agent-develop.yml@<ref>
        ▼
FlowForge reusable workflow   (runs in the TARGET repo context)
        │  validate issue, compute branch, checkout base branch
        ▼
Claude Code   ◄── agents/developer.md + target CLAUDE.md + issue
        │
        ▼
Branch agent/<issue>-<slug>  + commits  + Draft PR
        │
        ▼
Human review → merge (never by the agent)
```

> 💡 **Note**: a reusable workflow runs in the **caller's** context: `github.repository`,
> `github.token` and the checkout all refer to the target repository. FlowForge itself is
> only the source of the workflow definition.

### 2.3 Review flow (Phase 3 target)

> **Status**: Reviewer specification ✅ ([`agents/reviewer.md`](../agents/reviewer.md)) ·
> Reviewer workflow ✅ (`.github/workflows/agent-review.yml`) · Reviewer E2E ✅ (2026-10-06:
> `demo-api` Issue #5 → Developer Draft PR #7 → `APPROVE`, comment updated in place on re-run).

```text
Issue
  ↓
Developer
  ↓
Draft PR
  ↓
Reviewer workflow
  ↓
APPROVE / REQUEST_CHANGES / BLOCKED
```

Inside `agent-review.yml`:

```text
target caller (pull_request_number)
  │
  ▼
job review   (contents/issues/pull-requests/checks/statuses: read)
  │  resolve PR via GraphQL: base, head SHA, linked Issue (closing keyword), CI snapshot
  │  checkout PR head SHA · pin CLAUDE.md/.claude/.mcp.json to the base branch
  │  Claude Code: Read/Glob/Grep + read-only git (+ target checks), Edit/Write disallowed
  │  structured output (--json-schema) → validated by jq → review.json + review.md
  ▼
artifact flowforge-review-pr-<n>
  │
  ▼
job publish  (pull-requests: write only, no checkout, no agent)
     create or update the single <!-- flowforge-review --> comment on the PR
```

```text
Issue
  ↓
Developer
  ↓
Draft PR
  ↓
Reviewer   ◄── agents/reviewer.md + target CLAUDE.md (base) + issue + diff + CI results
  ↓            (read-only: findings + verdict, never commits nor merges)
  ├── APPROVE          → human review → merge (never by an agent)
  ├── REQUEST_CHANGES  → structured findings
  └── BLOCKED          → reliable review impossible, missing information stated
```

### 2.4 Iteration flow (Phase 4 target)

> **Status**: Iterator specification ✅ ([`agents/iterator.md`](../agents/iterator.md)) ·
> Iterator workflow ❌ (`agent-iterate.yml` not created) · `Reviewer ↔ Iterator` loop ❌.

```text
Issue
  ↓
Developer
  ↓
Draft PR
  ↓
Reviewer
  ↓
REQUEST_CHANGES
  ↓
Iterator   ◄── agents/iterator.md + target CLAUDE.md (base) + issue + diff + review.json
  ↓            (same PR branch, minimal fix, one commit, never merges nor approves)
Reviewer
```

| Role | Does | Never |
|---|---|---|
| Developer | Produces the change (new branch, Draft PR) | Pushes to `main`, merges |
| Reviewer | Produces findings + verdict | Modifies code |
| Iterator | Fixes the findings on the existing PR branch | Creates a branch, force-pushes, approves itself |

The loop is **bounded** (target `max_iterations = 3`), stops on Reviewer `APPROVE` or
`BLOCKED` and on Iterator `BLOCKED`, and hands over to a human once the limit is exceeded
(see [`iterator.md` §12](../agents/iterator.md#12-reviewer--iterator-loop-future)).

------

## 3. 📐 Contract between FlowForge and a target

| Item | Provided by | Notes |
|---|---|---|
| `agent:*` labels | FlowForge (Terraform) | Created by the module |
| `flowforge-agent.yml` | target (copied from `examples/`) | Only trigger + `uses:` + inputs |
| `issue_number`, `base_branch` | target → FlowForge | `workflow_call` inputs |
| `setup_uv`, `allowed_tools` | target → FlowForge | Optional inputs: target tooling and the exact commands the agent may run |
| `claude_code_oauth_token` | `CLAUDE_CODE_OAUTH_TOKEN` secret → FlowForge | Org secret (Selected repositories) or repo secret; passed explicitly, never `secrets: inherit` |
| Job permissions | target caller | `contents: write`, `issues: write`, `pull-requests: write` (a called workflow can only narrow) |
| `branch`, `pull_request` | FlowForge → target | `workflow_call` outputs |
| `flowforge-review.yml` | target (copied from `examples/`) | Calls `agent-review.yml` |
| `pull_request_number` | target → FlowForge (Reviewer) | Only required input; base, head, Issue and CI are resolved from it |
| Reviewer job permissions | target caller | `contents`, `issues`, `checks`, `statuses: read`; `pull-requests: write` (the comment only) |
| `verdict`, `result_artifact` | FlowForge → target (Reviewer) | `workflow_call` outputs |
| `CLAUDE.md` | target | Optional but strongly recommended |
| CI | target | FlowForge never replaces the target's CI |

### 3.1 Versioning

Targets reference `agent-develop.yml@main` during Phase 1. Once the workflow is stable,
FlowForge will publish tags and targets will pin a tag or commit SHA.

------

## 4. 🔐 Security model

| Principle | How |
|---|---|
| No secret in Git | `.gitignore` (tfstate, tfvars, .env, keys), `detect-private-key` hook, token only via env |
| No secret in Terraform state | Actions secrets are provisioned outside Terraform |
| Least privilege (Actions) | `permissions: {}` at workflow level; the Developer job gets `contents`/`issues`/`pull-requests: write` only, no `id-token` |
| Bounded agent | `--max-turns 40` + 30-min job timeout; Bash denied except an explicit allowlist (git read/commit, push of `HEAD` to its own `agent/*` ref only, `gh pr create --draft`, target commands) |
| Least privilege (Terraform) | Fine-grained token limited to onboarded repositories |
| Untrusted issue content | Read via `env` + `jq`, never `${{ }}`-interpolated into scripts; treated as data by the agent |
| No direct push to `main` | Only `git push origin HEAD:refs/heads/<agent branch>` is allowed + agent rules + default-branch ruleset (planned in the module) |
| Human merge | Agent opens **Draft** PRs only (forced back to draft by the workflow if needed); ruleset requires a human approval |
| Pinned actions | Third-party actions pinned by commit SHA |
| Read-only Reviewer | Review job has no write permission; publish job has `pull-requests: write` only and never runs PR code; Edit/Write tools disallowed; `persist-credentials: false` |
| Reviewer configuration not controlled by the PR | `CLAUDE.md`, `CLAUDE.local.md`, `.claude/`, `.mcp.json` reset to the base branch in the local workspace before Claude runs; fork PRs rejected |
| No silent approval | Missing, invalid or inconsistent Reviewer output becomes a workflow-set `BLOCKED` and fails the run |

------

## 5. ✅ Decisions taken (Phase 1, step 5)

| Topic | Decision |
|---|---|
| How Claude Code runs | `anthropics/claude-code-action` (pinned SHA), automation mode (`prompt` set): no tracking comment, no branch/PR created by the action |
| Authentication | `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`) only — no API key, no Anthropic WIF |
| Delivery of `agents/developer.md` | Fetched at `job.workflow_sha` from `job.workflow_repository` and embedded in the prompt |
| Branch | Created by the workflow (`git switch -c`) before Claude runs; Claude only commits and pushes it |
| Identity used to push and open PRs | Workflow `GITHUB_TOKEN` passed as `github_token` (no Claude GitHub App, no OIDC) |

> ⚠️ **Warning**: with `GITHUB_TOKEN`, the target must allow *"GitHub Actions to create and
> approve pull requests"*, and PRs it opens do **not** run `pull_request` workflows on their
> own: the run is created but stays `action_required` until a maintainer approves it
> (target CI must then be approved or re-run by a human, or a GitHub App identity adopted later).

### 5.1 Reviewer decisions (Phase 3)

| Topic | Decision |
|---|---|
| Contract | Only `pull_request_number` (+ optional `setup_uv`, `allowed_tools`); base/head/SHA from the PR, Issue from `closingIssuesReferences` (exactly one, never guessed) |
| Delivery of `agents/reviewer.md` | Same as the Developer: fetched at `job.workflow_sha`, embedded in the prompt |
| Target `CLAUDE.md` | Base-branch version, enforced by resetting agent configuration files in the workspace |
| Result | Claude structured output (`--json-schema`), validated and rendered by the workflow — the comment format does not depend on the model |
| Publication | One PR **comment** (not a GitHub review: no merge-state side effect, no "approve" by `GITHUB_TOKEN`), updated in place on re-runs |
| Failure | Before Claude: the job fails. Claude failed or output rejected: `BLOCKED` published, job failed |
| Trigger (target caller) | `workflow_dispatch` (`pull_request_number`) for Developer PRs, plus `pull_request` (`opened`, `reopened`, `synchronize`, `ready_for_review`) restricted to same-repo `agent/*` branches and to non-bot actors (`claude-code-action` refuses `github-actions[bot]`, so approving a bot-opened PR's waiting run cannot work). `workflow_dispatch` numbers reach `inputs` as strings: callers pass `fromJSON(...)` |

### 5.2 Review result contract (`review.json`, `schema_version: 1`)

Artifact `flowforge-review-pr-<n>` holds `review.json` (below), `review.md` (the comment)
and, when the output was rejected, `rejected-output.json`. Intended consumer: the future
Iterator.

```json
{
  "schema_version": 1,
  "produced_by": "reviewer",
  "repository": "owner/name",
  "pull_request": 4,
  "issue": 3,
  "base_branch": "main",
  "head_branch": "agent/3-add-get-version",
  "head_sha": "<reviewed commit>",
  "run_url": "https://github.com/...",
  "verdict": "REQUEST_CHANGES",
  "summary": "...",
  "blocked_reason": "",
  "acceptance_criteria": [
    { "criterion": "...", "status": "PASS", "evidence": "..." }
  ],
  "findings": [
    { "severity": "MAJOR", "title": "...", "file": "...", "line_or_range": "N/A",
      "description": "...", "reason": "...", "expected_fix": "..." }
  ],
  "counts": { "BLOCKER": 0, "MAJOR": 1, "MINOR": 0, "NOTE": 0 }
}
```

- `produced_by`: `reviewer`, or `workflow` when the verdict is a technical `BLOCKED`.
- `issue`: `null` when no single Issue is linked.
- `verdict` ∈ `APPROVE | REQUEST_CHANGES | BLOCKED`; `status` ∈ `PASS | FAIL | NOT_VERIFIED`;
  `severity` ∈ `BLOCKER | MAJOR | MINOR | NOTE`. Findings are sorted by severity.
- Consistency enforced (agents/reviewer.md §8): `APPROVE` ⇒ no `BLOCKER`/`MAJOR` and every
  criterion `PASS`; `REQUEST_CHANGES` ⇒ a `BLOCKER`/`MAJOR` or a `FAIL`; `BLOCKED` ⇒
  non-empty `blocked_reason`.

## 6. 🚧 Open design decisions

| Topic | To decide at |
|---|---|
| Remote Terraform backend | Before the first `apply` |
| Exact default-branch ruleset | Phase 1, step 3 |
| Iterator workflow contract (`workflow_call` inputs, `iteration.json` schema) | Phase 4, Iterator workflow |
| Loop orchestration (trigger, iteration counter storage, `agent:*` label transitions) | Phase 4, Iterator workflow |
