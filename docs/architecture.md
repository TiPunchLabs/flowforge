# 🏗️ FlowForge — Architecture

> **Status**: Phases 1–4 done (Foundation, Developer E2E, Reviewer E2E, Iterator E2E — with reservations, see [milestone](milestones/phase4-iterator-e2e.md)). Describes the target design; see [phase-1.md](phase-1.md) for what exists today.

------

## 🧠 Mental Model

```text
           ┌──────────────────────── FlowForge (central) ────────────────────────┐
           │  terraform/            .github/workflows/        agents/            │
           │  target-repository     agent-develop.yml         developer.md       │
           │  module                agent-review.yml          reviewer.md        │
           │                        agent-iterate.yml         iterator.md        │
           │                        review-cycle.yml          (generic rules)    │
           │                        (workflow_call)                              │
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
| Reusable workflow | `.github/workflows/agent-iterate.yml` | Check the iteration bound and the review, run Claude Code on the existing PR branch, verify and fast-forward push one commit, produce a JSON result |
| Reusable workflow | `.github/workflows/review-cycle.yml` | Bounded `Reviewer ↔ Iterator` loop: decides who runs and when, computes the cycle result; no agent logic |
| Agent rules | `agents/*.md` | Generic, project-independent behavior of each agent: `developer.md`, `reviewer.md`, `iterator.md` |
| Caller templates | `examples/target-repository/` | What a target repository copies (`flowforge-agent.yml`, `flowforge-review.yml`, `flowforge-review-cycle.yml`) |
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
  │  resolve PR via GraphQL: state, base, head SHA, linked Issue (closing keyword), CI snapshot
  │    state CLOSED | MERGED → NO_OP: stop here, nothing reviewed or published, run succeeds
  │  checkout PR head SHA · pin CLAUDE.md/.claude/.mcp.json to the base branch
  │  re-check PR state right before Claude (CLOSED | MERGED → NO_OP)
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

> **Status**:
>
> ```text
> Phase 4 — Iterator
>
> Iterator definition     DONE      agents/iterator.md
> Iterator workflow       DONE      .github/workflows/agent-iterate.yml (one iteration per call)
> Reviewer/Iterator loop  DONE      .github/workflows/review-cycle.yml (§2.5)
> Full E2E                DONE      demo-api, see docs/milestones/phase4-iterator-e2e.md
> ```

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

Inside `agent-iterate.yml` (one iteration; it never starts the Reviewer):

```text
target caller (pull_request_number, iteration_number, max_iterations, review_json)
  │
  ▼
job iterate  (contents/issues/pull-requests: read)
  │  guards, before any checkout or Claude run — failure = BLOCKED, nothing pushed:
  │    iteration_number <= max_iterations (<= 3) · review verdict REQUEST_CHANGES
  │    PR open, same repo · head branch ≠ base / default / main · PR head == reviewed head_sha
  │  checkout the PR head branch · branch, HEAD and clean tree verified
  │  pin CLAUDE.md/.claude/.mcp.json to the base branch (working tree only)
  │  Claude Code: edit + target checks + git add/commit; push, branch, reset… denied
  │  structured output (--json-schema) → validated by jq; commit contract checked
  │    (exactly one commit iff a finding is FIXED, files == files of FIXED findings)
  ▼
artifact flowforge-iteration-pr-<n>-<iteration>  (iteration.json + commit bundle)
  │
  ▼
job publish  (contents: write only, no Claude, no PR code run)
     bundle = one commit on top of the reviewed head · remote branch unchanged
     git push origin <sha>:refs/heads/<head_branch>   (fast-forward, never forced)
     iteration.json (pushed) + iteration.md → artifact + job summary
```

The loop is **bounded** (target `max_iterations = 3`), stops on Reviewer `APPROVE` or
`BLOCKED` and on Iterator `BLOCKED`, and hands over to a human once the limit is reached
(see [`iterator.md` §12](../agents/iterator.md#12-reviewer--iterator-loop)). It is run by
`review-cycle.yml` (§2.5).

### 2.5 Review cycle (Phase 4)

```text
review-cycle.yml  = decides WHO runs and WHEN   (no code read, no judgment, no edit)
agent-review.yml  = reviews                     (authority of validation)
agent-iterate.yml = fixes                       (authority of correction)
```

GitHub Actions cannot loop over reusable workflows, so the loop is **unrolled** into a fixed
chain of jobs, each gated by an `if:` on the previous job's output. The chain has exactly
three Iterator jobs: a fourth Iterator pass cannot exist.

```text
target caller (pull_request_number, max_iterations = 3)
  │
check            max_iterations ∈ 1..3, PR number valid — before any agent
  │
Reviewer #1      iteration_number = 0
  ├── (PR CLOSED | MERGED, not reviewed) ──► NO_OP      same for every Reviewer #k
  ├── APPROVE ─────────────────────────────► APPROVED
  ├── BLOCKED ─────────────────────────────► BLOCKED
  └── REQUEST_CHANGES  (and 1 <= max_iterations)
        ▼
Iterator #1      iteration_number = 1, review_json = Reviewer #1 review.json
  ├── BLOCKED ─────────────────────────────► BLOCKED
  └── COMPLETED | PARTIAL
        ▼
Reviewer #2 ── same branching ──► Iterator #2 ──► Reviewer #3 ──► Iterator #3
                                                                       │
                                                       Reviewer #4 (final)
                                                         ├── APPROVE          → APPROVED
                                                         ├── BLOCKED          → BLOCKED
                                                         └── REQUEST_CHANGES  → MAX_ITERATIONS_REACHED
  │
summary (always)  cycle.json + cycle.md → outputs, job summary, artifact
```

| Job | Runs when |
|---|---|
| `review_1` | `check` succeeded |
| `iterate_k` | `review_k` **succeeded** with `verdict == REQUEST_CHANGES` and `k <= max_iterations` |
| `review_k+1` | `iterate_k` **succeeded** with `result ∈ {COMPLETED, PARTIAL}` |
| `summary` | always |

Any other outcome skips every later job: the chain stops exactly where the decision was
made. With `max_iterations < 3`, the Reviewer after the last allowed Iterator is the final
one (e.g. `max_iterations = 1`: Reviewer #1 → Iterator #1 → Reviewer #2 final).

**Iteration semantics.** `iteration_number` = number of Iterator passes engaged so far.
Reviewer #1 runs at `0`, Iterator #k runs with `iteration_number = k`. `max_iterations = 3`
means at most three Iterator passes, followed by one final review.

**Findings transport.** Reviewer output `review_json` (the full `review.json`, compact JSON)
→ Iterator input `review_json`, unchanged. No comment parsing: the Iterator receives
`severity`, `title`, `file`, `line_or_range`, `description`, `reason`, `expected_fix`, the
acceptance criteria and the reviewed `head_sha` (freshness check), exactly as validated by
the Reviewer workflow.

**`PARTIAL`** goes back to the Reviewer like `COMPLETED`: the Reviewer stays the only
authority able to say the PR is acceptable. Neither Iterator result is an approval. A
`PARTIAL` iteration has pushed its safe fixes; the remaining findings are in its result, and
the next review decides again (typically `REQUEST_CHANGES`, or `BLOCKED` when only a human
can act).

#### 2.5.1 Final result

| Result | When | Run | Human |
|---|---|---|---|
| `APPROVED` | Last Reviewer returned `APPROVE` | ✅ success | Reviews and merges (FlowForge never merges, never marks the PR ready, never deletes the branch) |
| `BLOCKED` | A Reviewer or an Iterator returned `BLOCKED` (agent result) | ✅ success | Required: read the blocked reason |
| `MAX_ITERATIONS_REACHED` | Last Reviewer returned `REQUEST_CHANGES` and `max_iterations` Iterator passes were used | ✅ success | Required: budget spent, changes still requested |
| `NO_OP` | A Reviewer found the PR already `CLOSED` or `MERGED`: the PR no longer requires or allows review-cycle processing | ✅ success | None: nothing was reviewed, published or iterated |
| `FAILED` | A called workflow failed or was cancelled, or the inputs were rejected | ❌ failure | Required: technical failure, see the failed job |

**Agent verdict vs technical failure.** A `BLOCKED` returned by an agent is a result. A
`BLOCKED` *set by a workflow* (Claude step failed, output rejected, guard failed, push
rejected — `produced_by: workflow`) always fails its called workflow; the cycle sees a
failed job and reports `FAILED`, with the workflow-set verdict kept in the timeline. It is
never turned into a business `BLOCKED`. Nothing resumes automatically after `BLOCKED`,
`MAX_ITERATIONS_REACHED` or `FAILED`.

**`NO_OP` — pull request no longer open.** Runs are asynchronous: a human may merge or
close the PR while a review is queued. That is a normal outcome, not an error.

| PR state (read at runtime) | Reviewer | Iterator | Result |
|---|---|---|---|
| `OPEN` | runs normally | per the gates above | `APPROVED` / `BLOCKED` / `MAX_ITERATIONS_REACHED` / `FAILED` |
| `CLOSED` | not executed, nothing published | not executed | `NO_OP` (`PR_ALREADY_CLOSED`) |
| `MERGED` | not executed, nothing published | not executed | `NO_OP` (`PR_ALREADY_MERGED`) |

- `NO_OP` ≠ `BLOCKED`: no agent ran, nobody has anything to fix or decide.
- `NO_OP` ≠ `FAILED`: nothing broke. A GitHub API error, missing permissions, a PR not
  found or an unknown state while reading the PR remain technical failures (`FAILED`), never
  `NO_OP`.
- `NO_OP` is an orchestration result, **not a Reviewer verdict**: the verdicts stay
  `APPROVE | REQUEST_CHANGES | BLOCKED`, and a no-op Reviewer has an empty `verdict`.
- The state is read twice by `agent-review.yml`: with the PR context (before any checkout)
  and again right before Claude starts. A merge or close *during* the review cannot be
  prevented: its verdict is published on the already merged or closed PR.
- **Known limit — closed during the Iterator.** `agent-iterate.yml` keeps its precondition
  "PR is `OPEN`": a PR closed or merged after `REQUEST_CHANGES` and before the Iterator
  starts makes the Iterator fail with a workflow-set `BLOCKED`, so the cycle reports
  `FAILED`. Turning that case into `NO_OP` too (Issue #18, Iterator criterion) is a planned
  improvement. Nothing is pushed in that case.

#### 2.5.2 One cycle per pull request

```text
Iterator push ──► pull_request synchronize ──► second cycle? ──► two writers on one branch
```

| Layer | Protection |
|---|---|
| Trigger | The Iterator pushes with `GITHUB_TOKEN`: GitHub does not start `pull_request` / `push` workflows for it |
| Caller | The example caller is `workflow_dispatch` only: a cycle is started by a human, never by a push |
| Concurrency | `flowforge-review-cycle-<repository>-<pr>`, `cancel-in-progress: false`: a second cycle on the same PR waits for the running one; a newer pending cycle replaces an older pending one, never the running one |
| Freshness | Each Iterator refuses a review whose `head_sha` is no longer the PR head, and pushes only if the remote branch is still at the reviewed commit: an outside push makes the iteration fail (`FAILED`), never overwrites |

`cancel-in-progress: true` is rejected on purpose: cancelling a cycle can interrupt an
Iterator between its verification and its push, and the newer cycle would then review a
half-known state. Waiting is safe, since each step re-reads the PR.

> ⚠️ **Warning**: the called workflows keep their own groups (`flowforge-review-…`,
> `flowforge-iterate-…`), shared with stand-alone runs on the same PR. GitHub keeps one
> pending run per group, so a stand-alone `flowforge-review.yml` run started *during* a cycle
> can replace the cycle's pending Reviewer, which then ends `cancelled` → `FAILED`. Do not
> run stand-alone reviews on a PR whose cycle is running. A caller must not reuse the
> cycle's group name either: caller and called workflow in one group deadlock.

> 💡 **To check during the E2E**: the next Reviewer reads the PR head through the API a few
> seconds after the Iterator push. If the API still served the old head, the Iterator's
> freshness guard would stop the following iteration (`FAILED`), never act on stale findings.

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
| `pull_request_number`, `iteration_number`, `max_iterations`, `review_json` | target → FlowForge (Iterator) | `review_json` = the Reviewer's `review.json`; base, head, Issue resolved from the PR |
| Iterator job permissions | target caller | `contents: write` (the push job only), `issues: read`, `pull-requests: read` |
| `verdict`, `result_artifact`, `review_json`, `no_op_json` | FlowForge → target (Reviewer) | `review_json`: full `review.json`, compact JSON; `no_op_json`: set only on `NO_OP` (§5.2) |
| `result`, `commit_sha`, `result_artifact`, `iteration_json` | FlowForge → target (Iterator) | `iteration_json`: final `iteration.json` (per-finding statuses), compact JSON |
| `flowforge-review-cycle.yml` | target (copied from `examples/`) | Calls `review-cycle.yml`, `workflow_dispatch` only |
| `pull_request_number`, `max_iterations` (+ `setup_uv`, `review_allowed_tools`, `iterate_allowed_tools`) | target → FlowForge (cycle) | Base/head branches resolved from the PR by each agent workflow, never passed in |
| Cycle job permissions | target caller | Union of both agents: `contents: write`, `pull-requests: write`, `issues`/`checks`/`statuses: read`; each called job narrows it |
| `result`, `iterations_used`, `final_reviewer_verdict`, `cycle_json` | FlowForge → target (cycle) | `workflow_call` outputs |
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
| Human merge | Agent opens **Draft** PRs only (forced back to draft by the workflow if needed); a default-branch ruleset requiring a human approval is planned in the module but **not enforced yet**: until then, merging only after a human review is a convention |
| Pinned actions | Third-party actions pinned by commit SHA |
| Read-only Reviewer | Review job has no write permission; publish job has `pull-requests: write` only and never runs PR code; Edit/Write tools disallowed; `persist-credentials: false` |
| Reviewer configuration not controlled by the PR | `CLAUDE.md`, `CLAUDE.local.md`, `.claude/`, `.mcp.json` reset to the base branch in the local workspace before Claude runs; fork PRs rejected |
| No silent approval | Missing, invalid or inconsistent Reviewer output becomes a workflow-set `BLOCKED` and fails the run |
| Iterator push is not in the agent's hands | Claude runs with a read-only token and no push permission; a separate job, which runs no PR code, verifies the commit and fast-forward pushes it to the PR head branch only |
| Bounded Iterator | `iteration_number <= max_iterations`, ceiling 3, checked before any checkout; stale review (`head_sha` ≠ PR head) refused |
| Bounded review cycle | Static chain with exactly three Iterator jobs (no 4th pass can exist), `max_iterations` checked before any agent, one active cycle per PR (concurrency group); the cycle never merges, never marks a PR ready, never deletes a branch |

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
| PR no longer open | `CLOSED` or `MERGED` when read (context, then right before Claude): `NO_OP`, job succeeds, no Claude run, no comment, no artifact; result in the step summary and `no_op_json` (§2.5.1) |
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

**No-op result (`no_op_json` output, `schema_version: 1`).** When the PR is no longer open,
no `review.json` exists: `verdict` and `review_json` are empty and `no_op_json` carries

```json
{
  "schema_version": 1,
  "result": "NO_OP",
  "reason": "PR_ALREADY_MERGED",
  "repository": "owner/name",
  "pull_request": 42,
  "state": "MERGED",
  "run_url": "https://github.com/..."
}
```

- `reason` ∈ `PR_ALREADY_CLOSED | PR_ALREADY_MERGED`; `state` ∈ `CLOSED | MERGED` (GraphQL
  `PullRequestState`, which reports a merged PR as `MERGED`, not `CLOSED`).
- `no_op_json` is empty whenever a review ran or the run failed.

### 5.3 Iterator decisions (Phase 4)

| Topic | Decision |
|---|---|
| Contract | `pull_request_number`, `iteration_number`, `max_iterations` (default and ceiling `3`), `review_json` (+ optional `setup_uv`, `allowed_tools`). Base/head branches, head SHA and Issue are resolved from the PR, never passed in |
| Findings transport | The full Reviewer `review.json` as a JSON string input: one value carries verdict, findings, criteria and the reviewed `head_sha` (freshness check), independently of where the caller got it |
| Work list | Review findings + one implicit `MAJOR` per acceptance criterion marked `FAIL` (`iterator.md` §4.2), numbered `id` 1..n |
| Delivery of `agents/iterator.md` | Same as the other agents: fetched at `job.workflow_sha`, embedded in the prompt; target `CLAUDE.md` from the base branch |
| Commit | Made by Claude locally (one commit, explicit `git add`); moved to the push job as a git bundle so the commit SHA is preserved |
| Push | Workflow, not agent: `git push origin <sha>:refs/heads/<head_branch>`, no force, only if the remote branch is still at the reviewed commit |
| Result | Claude structured output validated by jq (statuses, `iterator.md` §10 rules, commit contract); violation → workflow `BLOCKED`, nothing pushed, run failed |
| Partial delivery | Finding status ≠ global result. A `BLOCKED` or `NOT_ACTIONABLE` finding does not, by itself, block independent safe fixes: they are validated, committed, pushed, and the result is `PARTIAL` (`iterator.md` §10). Global `BLOCKED` is kept for unsafe or impossible situations: failed preconditions or validations, prompt injection, nothing `FIXED`, fixes that depend on a remaining finding |
| Protected paths | `CLAUDE.md`, `CLAUDE.local.md`, `.claude/`, `.mcp.json`, `.github/workflows/`: never committed (commit rejected by the workflow). A finding that needs one is `NOT_ACTIONABLE`, "Human required: protected file `<path>`", not `BLOCKED` (`iterator.md` §6.3) |
| Tests | `tests/iterator-partial-delivery.sh` runs the real step scripts (result rules, Git contract, render, cycle gates) on throwaway repositories; pre-commit hook, so also in CI |
| No auto-review | The workflow stops after the push. Pushing with `GITHUB_TOKEN` does not start the target's `pull_request` workflows either |

### 5.4 Iteration result contract (`iteration.json`, `schema_version: 1`)

Artifact `flowforge-iteration-pr-<n>-<iteration>` holds `iteration.json` (below),
`iteration.md` (human summary, also written to the job summary), `iteration.bundle` when a
commit was produced and, when the output was rejected, `rejected-output.json`. The final
version (after the push) is also the `iteration_json` output, consumed by `review-cycle.yml`.

```json
{
  "schema_version": 1,
  "produced_by": "iterator",
  "repository": "owner/name",
  "pull_request": 7,
  "issue": 5,
  "base_branch": "main",
  "head_branch": "agent/5-add-get-version",
  "reviewed_sha": "<commit the findings describe>",
  "run_url": "https://github.com/...",
  "iteration_number": 1,
  "max_iterations": 3,
  "result": "COMPLETED",
  "summary": "...",
  "blocked_reason": "",
  "findings": [
    { "id": 1, "source": "review", "severity": "MAJOR", "title": "Missing error-path test",
      "file": "tests/test_tasks.py", "line_or_range": "N/A",
      "status": "FIXED", "files": ["tests/test_tasks.py"], "explanation": "..." }
  ],
  "validations": [ { "command": "uv run pytest", "outcome": "PASS", "details": "..." } ],
  "diff": { "files": [ { "path": "tests/test_tasks.py", "added": 12, "removed": 0 } ],
            "files_changed": 1, "lines_added": 12, "lines_removed": 0, "assessment": "..." },
  "commit": { "sha": "<pushed commit>", "pushed": true },
  "counts": { "FIXED": 1, "ALREADY_RESOLVED": 0, "NOT_ACTIONABLE": 0, "BLOCKED": 0 }
}
```

- `produced_by`: `iterator`, or `workflow` when a guard, a technical failure, a rejected
  output or a failed push set `BLOCKED` (every work-list item is then `BLOCKED`, "not processed").
- `result` ∈ `COMPLETED | PARTIAL | BLOCKED`; `status` ∈ `FIXED | ALREADY_RESOLVED |
  NOT_ACTIONABLE | BLOCKED`; `source` ∈ `review | acceptance_criterion`.
- Consistency enforced (agents/iterator.md §5, §10). A finding is *remaining* when it is
  `BLOCKED` (any severity) or a `BLOCKER`/`MAJOR` `NOT_ACTIONABLE`. `COMPLETED` ⇒ no remaining
  finding, at least one validation and all `PASS`; `PARTIAL` ⇒ at least one `FIXED`, at least
  one remaining, at least one validation and all `PASS`; `BLOCKED` ⇒ non-empty `blocked_reason`;
  `NOTE` ⇒ `NOT_ACTIONABLE`; `FIXED` ⇒ non-empty `files`; non-`FIXED` ⇒ non-empty `explanation`
  (the reason). The commit contract applies to `PARTIAL` as to `COMPLETED`: one commit holding
  exactly the files of the `FIXED` findings, nothing left uncommitted, no protected path.
- `findings` always lists every work-list item; `iteration.md` renders them as **Delivered**
  (`FIXED`, `ALREADY_RESOLVED`) and **Remaining** (`NOT_ACTIONABLE`, `BLOCKED`, with the reason).
- `commit`: `null` when nothing was committed or the result is `BLOCKED` (never pushed).

### 5.5 Review cycle decisions (Phase 4)

| Topic | Decision |
|---|---|
| Location | Dedicated reusable workflow `review-cycle.yml`; `agent-review.yml` and `agent-iterate.yml` stay specialized, gained only a JSON output each |
| Loop | Unrolled, static chain `review_1 … review_4` with `if:` gates — deterministic, visible in the run graph, no dynamic dispatch, no counter storage: the job *is* the counter |
| Nested calls | `uses: ./.github/workflows/<agent>.yml`: same FlowForge commit as `review-cycle.yml`, so the three workflows and the agent rules always match (to confirm in the E2E) |
| Contract | `pull_request_number`, `max_iterations` (default 3, 1–3); no `base_branch`: each agent resolves it from the PR, a passed value could only disagree |
| Secret | `claude_code_oauth_token` declared once, forwarded explicitly to every call |
| Permissions | `permissions: {}` at workflow level; each call job gets what its called workflow requests, which narrows it per job: `contents: write` only reaches the Iterator push job, `pull-requests: write` only the Reviewer publish job; `summary` has none |
| Result | `summary` job (always) reads `needs` only: result, timeline, `cycle.json` + `cycle.md`; only `FAILED` fails the run |
| No auto-review outside the cycle | Iterator pushes do not trigger workflows; one active cycle per PR (§2.5.2) |

### 5.6 Cycle result contract (`cycle.json`, `schema_version: 1`)

Artifact `flowforge-review-cycle-pr-<n>` holds `cycle.json` (below, also the `cycle_json`
output), `cycle.md` (also the job summary), and the full result of every step in
`reviews/review_<k>.json` and `iterations/iterate_<k>.json` — the Reviewer artifact is
overwritten by each review of the run, these copies keep the history.

```json
{
  "schema_version": 1,
  "repository": "owner/name",
  "pull_request": 7,
  "run_url": "https://github.com/...",
  "result": "APPROVED",
  "reason": "Reviewer #3 returned APPROVE.",
  "iterations_used": 2,
  "max_iterations": 3,
  "final_reviewer_verdict": "APPROVE",
  "timeline": [
    { "step": "review", "round": 1, "job": "review_1", "job_result": "success",
      "verdict": "REQUEST_CHANGES", "head_sha": "…", "produced_by": "reviewer",
      "counts": { "BLOCKER": 0, "MAJOR": 1, "MINOR": 0, "NOTE": 0 } },
    { "step": "iterate", "iteration_number": 1, "job": "iterate_1", "job_result": "success",
      "result": "COMPLETED", "commit_sha": "…", "produced_by": "iterator",
      "counts": { "FIXED": 1, "ALREADY_RESOLVED": 0, "NOT_ACTIONABLE": 0, "BLOCKED": 0 } }
  ]
}
```

- `result` ∈ `APPROVED | BLOCKED | MAX_ITERATIONS_REACHED | NO_OP | FAILED` (§2.5.1).
- Review entries carry `no_op_reason`: `PR_ALREADY_CLOSED` or `PR_ALREADY_MERGED` for a
  no-op Reviewer (then `verdict` is empty), `null` otherwise.
- `timeline`: only the jobs that ran, in order; `job_result` ∈ `success | failure | cancelled`.
- `iterations_used`: Iterator jobs engaged (succeeded or not). `final_reviewer_verdict`: the
  last verdict produced, empty when no Reviewer produced one.

## 6. 🚧 Open design decisions

| Topic | To decide at |
|---|---|
| Remote Terraform backend | Before the first `apply` |
| Exact default-branch ruleset | Phase 1, step 3 |
| `agent:*` label transitions during the review cycle | After the review cycle E2E |
| Automatic start of the review cycle after the Developer (today: `workflow_dispatch`) | After the review cycle E2E |
