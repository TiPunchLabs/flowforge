# 🏗️ FlowForge — Architecture

> **Status**: Phases 1–4 done (Foundation, Developer E2E, Reviewer E2E, Iterator E2E — with reservations, see [milestone](milestones/phase4-iterator-e2e.md)). Phase 4.1 (hardening & lifecycle) done: validated E2E with one reservation and frozen as tag `flowforge-phase4.1-hardening-e2e` (§2.8, [milestone](milestones/phase41-hardening-e2e.md)). Phase 5 (Refiner) done: validated end to end with reservations and frozen as tag `flowforge-phase5-refiner-e2e` (§2.9, [milestone](milestones/phase5-refiner-e2e.md)). Phase 6 — GitHub Projects / Kanban done: validated end to end with reservations and frozen as tag `flowforge-phase6-github-projects-e2e` ([milestone](milestones/phase6-github-projects-e2e.md) §19); model defined in [github-projects/kanban-model.md](github-projects/kanban-model.md) (Prompt 26), Project provisioned ([github-projects/provisioning.md](github-projects/provisioning.md), Prompt 27), synchronised one way from the workflows ([github-projects/synchronization.md](github-projects/synchronization.md), Prompt 28, §2.11); Phase 7 — Notion done: validated end to end with reservations ([milestone](milestones/phase7-notion-complete.md)); Notion Need → Issue submission and GitHub → Notion feedback, both central in FlowForge (§2.12, §5.9). Describes the target design; see [phase-1.md](phase-1.md) for what exists today.

------

## 🧠 Mental Model

```text
           ┌──────────────────────── FlowForge (central) ────────────────────────┐
           │  terraform/            .github/workflows/        agents/            │
           │  target-repository     agent-develop.yml         developer.md       │
           │  module                agent-review.yml          reviewer.md        │
           │                        agent-iterate.yml         iterator.md        │
           │                        review-cycle.yml          (generic rules)    │
           │                        agent-lifecycle.yml       refiner.md         │
           │                        agent-refine.yml                             │
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
| Terraform module | `terraform/modules/target-repository` | Onboard an existing repo: labels, Actions variables, workflow token permissions, default-branch ruleset (human merge gate); later Actions permissions / environments |
| Terraform root | `terraform/` | Onboards targets that have **no** Terraform of their own (one module block per target) |
| Reusable workflow | `.github/workflows/agent-develop.yml` | Resolve the issue context, run Claude Code, produce branch + Draft PR |
| Reusable workflow | `.github/workflows/agent-review.yml` | Resolve the PR + Issue context, run Claude Code read-only, publish one review comment + JSON artifact |
| Reusable workflow | `.github/workflows/agent-iterate.yml` | Check the iteration bound and the review, run Claude Code on the existing PR branch, verify and fast-forward push one commit, produce a JSON result |
| Reusable workflow | `.github/workflows/review-cycle.yml` | Bounded `Reviewer ↔ Iterator` loop: decides who runs and when, computes the cycle result; no agent logic |
| Reusable workflow | `.github/workflows/agent-lifecycle.yml` | Terminal Issue state when an agent PR is closed: `agent:done` on merge, no state otherwise; no agent |
| Reusable workflow | `.github/workflows/agent-refine.yml` | Run Claude Code read-only on one Issue and the default branch, validate the refinement, rewrite the Issue, map the verdict to a state label, one comment (§2.9.1) |
| Refiner helper | `.github/scripts/flowforge-refine.sh` | Preconditions, result validation, deterministic rendering of the refined body (Original request, Refinement record) and of the comment |
| SPEC helper | `.github/scripts/flowforge-spec.sh` | `SPEC.md` contract check run by the Developer before any state change: `PASS` / `FAILED` / `ERROR` (§2.13) |
| State helper | `.github/scripts/flowforge-state.sh` | The one implementation of Issue state label transitions (§2.6), fetched by the workflows at their own commit |
| Agent rules | `agents/*.md` | Generic, project-independent behavior of each agent: `developer.md`, `reviewer.md`, `iterator.md`, `refiner.md` |
| SPEC.md contract | `docs/spec-contract.md` | Minimal structure of the target's `SPEC.md`, what the gate checks and does not (Phase 8.1) |
| Refined Issue contract | `docs/issue-contract.md` | Format of an executable Issue, `Ready` definition, `agent:needs-clarification` (Phase 5) |
| Caller templates | `examples/target-repository/` | What a target repository copies (`flowforge-agent.yml`, `flowforge-review.yml`, `flowforge-review-cycle.yml`, `flowforge-lifecycle.yml`, `flowforge-refine.yml`) |
| Target `CLAUDE.md` | in each target | Project-specific conventions (stack, commands, layout) |
| FlowForge-only workflow | `.github/workflows/notion-submit.yml` | Notion Need → one GitHub Issue, through the Notion Bridge App; runs in FlowForge only, environment `notion-bridge` (§2.12) |
| FlowForge-only workflow | `.github/workflows/notion-sync.yml` | Central reconciler: GitHub Project / Issue / PR → Need status in Notion, one way (§2.12) |
| Notion helpers | `.github/scripts/flowforge-notion.sh`, `flowforge-notion-sync.sh` | Submission validation and idempotence; feedback correlation, mapping and write-back |
| Notion allowlist | `config/notion-allowlist.json` | The repositories a Notion submission may target; hand-edited, reviewed by PR |

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
   (agent:* labels, Actions variables, default-branch ruleset)
```

A target is onboarded in **exactly one** Terraform state, in one of two modes:

| Mode | When | Where the `module` block lives |
|---|---|---|
| **Embedded** (preferred) | The target already manages its repository with Terraform | The target's own IaC, next to its `github_repository`, with `repository = github_repository.<x>.name` |
| **Central** | The target has no Terraform of its own | FlowForge `terraform/` root |

> ⚠️ **Warning**: declaring the same target in both places makes two states manage the
> same labels and rulesets; every `apply` would undo the other one.
>
> 💡 **Note**: for an existing repository, labels or a ruleset that already exist are adopted
> into the owning state with standard `import` blocks, never recreated nor managed by a second
> state ([target-onboarding.md §2.1](target-onboarding.md)).
>
> 💡 **Note**: in embedded mode the module is consumed by a Git source pinned to a tag
> (`git::https://github.com/TiPunchLabs/flowforge.git//terraform/modules/target-repository?ref=vX.Y.Z`,
> §3.1); a local path is for FlowForge development only. The repository creation and
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
        │  validate issue, check SPEC.md contract (§2.13), compute branch, checkout base branch
        ▼
Claude Code   ◄── agents/developer.md + target CLAUDE.md + issue
        │
        ▼
Branch agent/<issue>-<slug>  + commits  + Draft PR
        │
        ▼
Human review → GitHub approval → merge (never by the agent; enforced by the ruleset, §2.7)
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
  ├── APPROVE          → human review + GitHub approval → merge (never by an agent, §2.7)
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
  │    PR same repo · head branch ≠ base / default / main · PR head == reviewed head_sha
  │    PR CLOSED | MERGED → NO_OP: stop here, nothing checked out, no Claude run, run succeeds
  │  checkout the PR head branch · branch, HEAD and clean tree verified
  │  pin CLAUDE.md/.claude/.mcp.json to the base branch (working tree only)
  │  Claude Code: edit + target checks + git add/commit; push, branch, reset… denied
  │  structured output (--json-schema) → validated by jq; commit contract checked
  │    (exactly one commit iff a finding is FIXED, files == files of FIXED findings)
  ▼
artifact flowforge-iteration-pr-<n>-<iteration>  (iteration.json + commit bundle)
  │
  ▼
job publish  (contents: write + pull-requests: read, no Claude, no PR code run)
     re-check PR state first: CLOSED | MERGED → NO_OP, no checkout, nothing pushed
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
  ├── (PR CLOSED | MERGED, nothing pushed) ► NO_OP      same for every Iterator #k
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
| `NO_OP` | A Reviewer or an Iterator found the PR already `CLOSED` or `MERGED`: the PR no longer requires or allows review-cycle processing | ✅ success | None: nothing more was reviewed, published or pushed |
| `FAILED` | A called workflow failed or was cancelled, or the inputs were rejected | ❌ failure | Required: technical failure, see the failed job |

**Agent verdict vs technical failure.** A `BLOCKED` returned by an agent is a result. A
`BLOCKED` *set by a workflow* (Claude step failed, output rejected, guard failed, push
rejected — `produced_by: workflow`) always fails its called workflow; the cycle sees a
failed job and reports `FAILED`, with the workflow-set verdict kept in the timeline. It is
never turned into a business `BLOCKED`. Nothing resumes automatically after `BLOCKED`,
`MAX_ITERATIONS_REACHED` or `FAILED`.

**`NO_OP` — pull request no longer open.** Runs are asynchronous: a human may merge or
close the PR while a review or an iteration is queued or running. That is a normal outcome,
not an error.

| PR state (read at runtime) | Reviewer | Iterator | Result |
|---|---|---|---|
| `OPEN` | runs normally | per the gates above | `APPROVED` / `BLOCKED` / `MAX_ITERATIONS_REACHED` / `FAILED` |
| `CLOSED` | not executed, nothing published | not executed, or its commit not pushed | `NO_OP` (`PR_ALREADY_CLOSED`) |
| `MERGED` | not executed, nothing published | not executed, or its commit not pushed | `NO_OP` (`PR_ALREADY_MERGED`) |

- `NO_OP` ≠ `BLOCKED`: nothing was delivered, nobody has anything to fix or decide.
- `NO_OP` ≠ `FAILED`: nothing broke. A GitHub API error, missing permissions, a PR not
  found or an unknown state while reading the PR remain technical failures (`FAILED`), never
  `NO_OP`.
- `NO_OP` is an orchestration result, **not a Reviewer verdict nor an Iterator result**: the
  verdicts stay `APPROVE | REQUEST_CHANGES | BLOCKED` and the Iterator results `COMPLETED |
  PARTIAL | BLOCKED`; a no-op Reviewer has an empty `verdict`, a no-op Iterator an empty
  `result`. Both explain themselves in `no_op_json`.
- The state is read twice by `agent-review.yml`: with the PR context (before any checkout)
  and again right before Claude starts. A merge or close *during* the review cannot be
  prevented: its verdict is published on the already merged or closed PR.
- The state is read twice by `agent-iterate.yml` (Issue #22): in the preconditions (before
  any checkout or Claude run, `stage: preconditions`) and again by the publish job before
  its checkout and push (`stage: before_push`). A PR closed or merged while Claude runs gets
  no push; its `iteration.json` is kept in the artifact with `commit.pushed: false`. The
  first read comes after the `review_json` checks: an invalid review stays a failure.

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

### 2.6 Issue label lifecycle (Phase 4.1)

> **Status**: implemented for Issue #19 — helper `.github/scripts/flowforge-state.sh`,
> Developer transitions in `agent-develop.yml`, `issue_state` job in `review-cycle.yml`,
> terminal transitions in `agent-lifecycle.yml`; tested by `tests/label-lifecycle.sh`.

**Labels = current state. GitHub timeline = history.** An `agent:*` state label says where
the Issue is *now* in FlowForge; what happened before lives in the Issue timeline, the
Actions runs, the commits, the PR and its reviews. An Issue carries **at most one** FlowForge
state label.

```text
(none) ──human──► agent:ready ──Developer starts──► agent:running
                                                        │
                              ┌── Draft PR delivered ───┴── agent stopped, ┐
                              │                             no Draft PR    │
                              ▼                                            ▼
                        agent:review ──── cycle BLOCKED or ────────► agent:blocked
                        (Reviewer ↔ Iterator;  MAX_ITERATIONS_REACHED      │
                         APPROVE stays here)                               │
                              │                                            │
                              ├── PR merged by a human ──► agent:done ◄────┤
                              └── PR closed unmerged ────► (none)     ◄────┘

agent:running ── technical failure (Claude Code failed / cancelled / not run), no Draft PR ──► (none)
```

| State | Label | Set by | Event | Removed labels |
|---|---|---|---|---|
| Backlog | *(none)* | human, `agent-develop.yml` or `agent-lifecycle.yml` | Issue written; Developer technical failure without a Draft PR; PR closed without merge | every FlowForge state |
| Needs clarification | `agent:needs-clarification` | `agent-refine.yml` | Refiner verdict `NEEDS_CLARIFICATION` (§2.9.1) | every other state |
| Backlog | *(none)* | `agent-refine.yml` | Refiner verdict `READY`: refined, waiting for a human to apply `agent:ready` | every other state (`agent:needs-clarification`) |
| Ready | `agent:ready` | human | Issue refined | — (trigger of the Developer) |
| Running | `agent:running` | `agent-develop.yml` | Developer starts (preconditions passed) | every other state, and `ready_label` |
| Review | `agent:review` | `agent-develop.yml` | A Draft PR exists at the end of the Developer run (even if Claude Code then failed: the review judges it) | every other state |
| Blocked | `agent:blocked` | `agent-develop.yml` | Claude Code ended normally without a Draft PR: the agent stopped and commented (rules §8) | every other state |
| Blocked | `agent:blocked` | `review-cycle.yml` (`issue_state`) | cycle result `BLOCKED` or `MAX_ITERATIONS_REACHED`, PR still open, Issue in `agent:review` | every other state |
| Done | `agent:done` | `agent-lifecycle.yml` | PR **merged** (by a human), Issue in `agent:review` or `agent:blocked` | every other state |

The Refiner only runs on an Issue with no state or `agent:needs-clarification`, and never
sets `agent:ready`. `agent:needs-clarification` is part of the state set since Prompt 22: the
Developer's `agent:running` transition removes it like any other stale state.

**Unchanged on purpose.**

- Reviewer ↔ Iterator: the Issue stays `agent:review`. No `agent:fixing` state.
- **`APPROVED` is not `DONE`**: the human review and merge are still to come, the Issue stays
  `agent:review`. Only the merge produces `agent:done`; FlowForge never merges.
- **`FAILED` is not `BLOCKED`**: a technical failure of the cycle (API error, cancelled job,
  workflow-set verdict) leaves the label as is; re-run the cycle once fixed. A business
  `BLOCKED` needs a human decision, a technical failure only a re-run.
- `NO_OP` (PR closed or merged during the cycle) changes nothing: the PR close itself is
  handled by `agent-lifecycle.yml`.
- The stand-alone `agent-review.yml` (`flowforge-review.yml`) never changes labels: only the
  cycle, which owns the decision, does. Its `APPROVE` only moves the Project card to
  `Human validation` (opt-in; [synchronization](github-projects/synchronization.md)).
- **Developer: business stop vs technical failure.** `agent:blocked` only when the agent
  itself stopped (Claude Code `success`, no Draft PR): a human must clarify the Issue. When
  Claude Code failed, was cancelled or never ran (`failure`, `cancelled`, `skipped`) and no
  Draft PR exists, the Issue goes back to no FlowForge state, with a warning: a re-run
  (re-adding `agent:ready`) is enough. Known limit, unchanged by #19: a re-run requires
  deleting the `agent/*` branch first if it was pushed.

**Closed without merge.** The work was abandoned, not done: no `agent:done`. It is not
`agent:blocked` either: the agent is not waiting for anything, a human chose to stop. The
Issue goes back to *no FlowForge state* (backlog); a human re-adds `agent:ready` (after
deleting the branch) or closes it.

**Trigger of the terminal state.** `pull_request: closed` on `agent/*` branches of the
target (`examples/target-repository/flowforge-lifecycle.yml`), merge state and linked Issue
read from the API (GraphQL `state`, `closingIssuesReferences` of the same repository). It
fires once per close, whether or not `Closes #n` also closes the Issue, and needs no Issue
event after the merge. `issues: closed` is not used: it would race with the PR event and
cannot tell a merge from a manual close. `workflow_run` would add a hop and artifacts for
nothing.

**Guards (no arbitrary Issue is ever relabeled).** The Issue is never taken from PR or
Issue text: it is the single Issue of the same repository GitHub links to the PR with a
closing keyword. It must already carry the expected source state (`agent:review` for
`issue_state`; `agent:review` or `agent:blocked` for the terminal state): an Issue moved back
to `agent:ready` / `agent:running` belongs to a newer run, an Issue without a FlowForge state
was never handed to FlowForge. `issue_state` also re-reads the PR and leaves a PR closed in
the meantime to the lifecycle workflow.

**Transitions are idempotent.** `flowforge_set_state <issue> <state|"">` reads the Issue
labels, removes every *other* label of the fixed set `agent:ready`, `agent:running`,
`agent:review`, `agent:blocked`, `agent:done`, `agent:needs-clarification` (plus `ready_label`), adds the target if
missing, and makes no write call when nothing changes. Removing an absent label or adding a
present one is a no-op. Other labels (`bug`, `priority:high`, …) are never touched. A target
state label that does not exist on the repository yet is skipped with a warning, the stale
labels are removed anyway (see *Rollout*).

**Permissions.** `issues: write` + `pull-requests: read` for `issue_state` and
`agent-lifecycle.yml`; no `contents` permission, no secret, no checkout of PR code. The
Developer job keeps its existing permissions.

**Rollout on an onboarded target.**

1. `terraform plan` / `apply` of the target's own state, to create `agent:done` (the module
   now manages five labels). Until then, a merge leaves the Issue with no state label instead
   of `agent:done`.
2. Copy `flowforge-lifecycle.yml` into the target.
3. Raise `issues: read` to `issues: write` in the target's `flowforge-review-cycle.yml`
   caller: a called workflow cannot widen the caller's permissions, so a caller still on
   `issues: read` makes the cycle fail at startup.
4. Retroactive clean-up of Issues closed before #19 is a manual, one-off step.

**GitHub Project mapping** (Phase 6, model defined in Prompt 26, Project provisioned in Prompt 27, synced in Prompt 28, §2.11): see
[github-projects/kanban-model.md](github-projects/kanban-model.md). Eight statuses
(`Backlog`, `Refining`, `Ready`, `Developing`, `Review`, `Iteration`, `Human validation`,
`Done`) plus an `Attention` field; there is no *Blocked* or *Needs clarification* column. The
Project is finer than the labels (`agent:review` maps to `Review`, `Iteration` or
`Human validation`), labels keep their trigger and guard roles, and workflows stay the source
of truth of execution.

### 2.7 Human merge gate (Phase 4.1)

> **Status**: implemented in the Terraform module (`github_repository_ruleset`, enabled by
> default); enforced on a target once its own state is applied. Live validation pending (§2.8).

The full chain, from Issue to merge:

```text
Issue + agent:ready
  ↓
Developer ──► branch agent/<issue>-<slug> + Draft PR
  ↓
Reviewer ──► APPROVE ─────────────────────────────┐
  │          BLOCKED ──► human decision            │
  ↓          REQUEST_CHANGES                       │
Iterator (fixes on the PR branch)                  │
  ↓                                                │
Reviewer … at most 3 Iterator passes               │
  ↓                                                │
cycle result: APPROVED / BLOCKED / MAX_ITERATIONS_REACHED
  ↓                                                ◄┘
PR still Draft, still unmerged, still protected
  ↓
human: Ready for review → GitHub approval (≥ 1) → merge     ← enforced by GitHub
  ↓
agent-lifecycle.yml ──► agent:done
```

**Two different approvals.**

| | FlowForge Reviewer `APPROVE` | GitHub approval |
|---|---|---|
| Who | Reviewer agent (`github-actions[bot]`) | A human with write access |
| What it is | A verdict in one PR **comment** + `review.json` | A PR **review** with state `APPROVED` |
| Counts for the ruleset | No | Yes |
| Meaning | "No finding left, in the agent's judgement" | "I take responsibility for this merge" |

`APPROVED` (cycle result) is therefore an input to the human decision, never a substitute.

**Enforcement** — ruleset `flowforge-default-branch` on `~DEFAULT_BRANCH`
(`terraform/modules/target-repository`, README "Default-branch ruleset"):

- pull request required: nobody pushes directly to the default branch;
- at least one approving review (`required_approving_review_count = 1`); approvals are
  dismissed by any new push (an Iterator commit after a human approval needs a new one);
- force push and deletion blocked;
- required status checks opt-in (`required_status_checks`, not strict), once the FlowForge
  GitHub App delivers agent PRs (§2.10);
- no bypass actor by default. Opt-in `admin_pull_request_bypass` for solo-maintainer targets:
  the *admin* repository role may merge a PR without approval, never push directly. Agents
  run as `github-actions[bot]`, which is not an admin.

Why agents cannot pass the gate: they author their PRs (an author cannot approve its own PR),
no FlowForge workflow submits a review, merges, enables auto-merge or marks a PR ready, and
`agent/*` branches are not matched by the ruleset, so Developer and Iterator pushes are
unaffected. `demo-api` opts in to the admin bypass (single human writer); its ruleset lives
in its own state, like its labels.

### 2.8 Phase 4.1 — Hardening & lifecycle

| Item | Implementation | Live validation |
|---|---|---|
| #17 Iterator partial delivery (`PARTIAL`) | ✅ done (§5.3, `tests/iterator-partial-delivery.sh`) | ✅ live: Iterator `PARTIAL` (6 `FIXED`, 3 `NOT_ACTIONABLE`) → Reviewer, demo-api PR #25 |
| #18 closed / merged PR = `NO_OP` | ✅ done (§2.5.1, `tests/review-no-op.sh`) | ✅ live: cycle on a merged (#25) and a closed (#26) PR → `NO_OP`; mid-cycle race not raced |
| #19 Issue label lifecycle | ✅ done (§2.6, `tests/label-lifecycle.sh`), rolled out on `demo-api` | ✅ live: human merge of PR #25 → Issue #24 `agent:blocked` → `agent:done`, closed |
| Human merge gate (default-branch ruleset) | ✅ done (§2.7, `terraform test` of the module) | ✅ live: ruleset active, merge blocked despite FlowForge `APPROVE`; ⚠️ merged through the admin bypass (no second human writer) |

Validated live on 2026-10-09 with FlowForge `77763ec`; evidence and reservations in
[milestones/phase41-hardening-e2e.md](milestones/phase41-hardening-e2e.md). Frozen as tag
`flowforge-phase4.1-hardening-e2e` (baseline: milestone §9).

**Known manual limitations** (accepted, not bugs): an Issue closed by hand without a PR, and
Issues closed before #19, keep their last `agent:*` label (§2.6, *Rollout* step 4). At the
freeze, a PR closed or merged between `REQUEST_CHANGES` and the Iterator start ended the cycle
`FAILED`; fixed after the freeze by Issue #22 (Iterator `NO_OP`, §2.5.1).

### 2.9 Phase 5 — Refiner agent

> **Status**: rules in [agents/refiner.md](../agents/refiner.md), Issue format in
> [issue-contract.md](issue-contract.md) (Prompt 21). **Executable** since Prompt 22
> (`agent-refine.yml`, §2.9.1). Validated in isolation (Prompt 23,
> [milestone](milestones/phase5-refiner-simple-cases.md)) and end to end in the Refiner → Developer →
> Reviewer chain (Prompt 24, [milestone](milestones/phase5-refiner-e2e.md); Iterator not needed). Developer,
> Reviewer and Iterator are unchanged. **Closed** in Prompt 25, validated with reservations, tag
> `flowforge-phase5-refiner-e2e` (milestone §13).

The Refiner sits **before** the Developer. It turns a rough need into a refined Issue and a
verdict; a human stays the gate between the two.

```text
user / external source
        │  rough need (Issue, text)
        ▼
     Refiner ──────────────► NEEDS_CLARIFICATION ─► requester answers ─► Refiner again
        │ READY                BLOCKED ─► human decision
        ▼
  refined Issue (body = spec + original request + refinement record)
        │  human applies agent:ready
        ▼
    Developer ─► Draft PR ─► Reviewer ⇄ Iterator (≤ 3) ─► human approval + merge ─► agent:done
```

Since Phase 7 a raw Issue can also come from a Notion Need (§2.12); the Refiner still reads the
Issue only, never Notion, and is still started on demand.

| Decision | Choice | Why |
|---|---|---|
| Where the result goes | The Issue **body** is rewritten; the original request is kept verbatim inside it, with a refinement record | Developer, Reviewer and Iterator read the body only; nothing in them changes |
| Who applies `agent:ready` | **A human**, never the Refiner | Human gate before any code; a `GITHUB_TOKEN` label would not trigger the Developer anyway |
| Not-ready state | `agent:needs-clarification`, one state label at a time (§2.6) | Added to the module and the state helper in Prompt 22 |
| Verdicts | `READY` / `NEEDS_CLARIFICATION` / `BLOCKED` | Same style as the other agents; refinement verdict, not a pipeline result |
| Non-invention | Every added statement is tagged `[provided]` / `[observed]` / `[assumption]` / `[recommended]` / `[missing]` | An assumption never reads as a requirement |
| Code access | Read-only; no branch, commit, push or PR | The Refiner prepares work, it does not do it |
| External sources | GitHub only: a Notion Need reaches the Refiner only as the Issue the submission created (Phase 7) | The agent never holds a Notion credential; Notion text stays untrusted Issue content |

#### 2.9.1 Execution (Prompt 22)

```text
human: gh workflow run flowforge-refine.yml -f issue_number=<n>      (target repository)
        │ uses: agent-refine.yml@<full SHA> # vX.Y.Z  (§3.1)
        ▼
 refine job  (contents / issues / pull-requests: read, Claude token)
   Issue + comments ─► preconditions ─► checkout default branch (no credentials)
   ─► Claude Code (Read/Glob/Grep, read-only git, gh issue|pr view|list; Edit/Write denied)
   ─► structured output ─► workspace unchanged? ─► validate ─► render body / title / comment
        │ artifact flowforge-refine-issue-<n>
        ▼
 publish job (issues: write only, no checkout, no Claude)
   re-read Issue: unchanged since the agent read it? still no state / needs-clarification?
   ├─ READY                ─► title + body rewritten, state label removed, comment   STOP
   ├─ NEEDS_CLARIFICATION  ─► title + body rewritten, agent:needs-clarification, comment
   └─ BLOCKED              ─► comment only
```

| Topic | Behaviour |
|---|---|
| Trigger | `workflow_dispatch` with `issue_number`, in the target (`examples/target-repository/flowforge-refine.yml`). No `issues` event: refining is an explicit request; a label trigger can come later |
| Preconditions (technical failure if not met) | Issue exists, is open, is not a PR, carries no state other than `agent:needs-clarification` (an Issue already handed to the Developer is never re-specified); a refined body has intact markers |
| Agent input | Rules `agents/refiner.md` and `docs/issue-contract.md` fetched at `job.workflow_sha`; Issue title, author, labels, body; the 30 latest human comments (requester answers); the default branch checked out. All of it untrusted data except the rules |
| Read-only | `Edit`, `Write`, `MultiEdit`, `NotebookEdit` disallowed; Bash limited to read-only git and `gh issue|pr view|list`; read-only token; `persist-credentials: false`; no push step. After Claude, a modified tracked file or a moved `HEAD` fails the run (nothing published); untracked files are listed as a warning, never committed |
| Result | Structured output (`--json-schema`), validated by `flowforge_refine_validate`: shape, verdict enum, `READY` ⇒ no blocking question and every required section filled, `NEEDS_CLARIFICATION` ⇒ ≥ 1 blocking question, `BLOCKED` ⇒ a reason, every criterion tagged, every non-blocking question has a default |
| Issue update | Option *rewrite the body, keep the original inside* (contract §2): title and body replaced. The workflow, not the model, writes *Original request* (first run: current title and body quoted verbatim; later runs: block carried over unchanged) and *Refinement record* (earlier entries kept, one appended). GitHub keeps the edit history |
| Comment | One FlowForge comment per Issue (`<!-- flowforge-refiner -->`, `github-actions[bot]`), created once then updated: verdict, blocking questions or block reason, run link |
| Labels | `READY` → no state (human applies `agent:ready`); `NEEDS_CLARIFICATION` → `agent:needs-clarification`; `BLOCKED` → unchanged. Via `flowforge_set_state`, idempotent |
| Technical failure (`FAILED`) | Issue unreadable, preconditions, Claude Code error, invalid or inconsistent output, dirty workspace, body > 65 536 characters, Issue edited or relabelled during the run, GitHub write error: the run fails; before `publish`, the Issue is untouched |
| Idempotence | Same input ⇒ same body (deterministic rendering); re-runs never duplicate sections, never re-quote a refined body as the original, update the single comment, and add one record entry each |
| Not done | No Developer start (`agent:ready` stays human; a `GITHUB_TOKEN` label would not trigger it anyway), no branch, commit, push or PR, no GitHub Project, no Notion |

### 2.10 Delivery identity: FlowForge GitHub App (Issue #34)

**Problem.** Pushes and PRs made with `GITHUB_TOKEN` create the target's `pull_request` runs
in an approval-required state: agent PRs had no CI evidence (Phase 5 reservation R7) and no
required status check could be added to the ruleset.

**Design (option A, decided 2026-10-11).** `claude-code-action` uses one `github_token` both
for git and for the `gh` CLI inside the session, so the App token is never given to Claude:

```text
Developer job
  Claude Code (GITHUB_TOKEN)   commits on agent/<n>-<slug>, writes .flowforge-pr/{title.txt,body.md}
                               or comments on the Issue and stops (no request = no PR)
  Verify delivery request      on the agent branch, ≥ 1 commit on top of the base commit,
                               not the base/default branch, request files not committed,
                               title ≤ 256 chars, body ≤ 60000 bytes
  Create App delivery token    only now; repo-scoped; contents + pull-requests write
  Push branch and open PR      git push HEAD:refs/heads/<agent branch>; gh pr create --draft
  Enforce Draft PR + label     GITHUB_TOKEN, unchanged (a failed delivery = technical, no state)

Iterator publish job           App token (contents write) for the verified fast-forward push only
```

- **One App for every target**, owned by the organization, installed on *selected
  repositories*; its client id and private key are organization variable/secret with
  *Selected repositories* visibility. Onboarding: [target-onboarding.md](target-onboarding.md).
- **Optional.** Without `app_client_id`, `GITHUB_TOKEN` delivers (previous behaviour).
- **Anti-loop rules.** (1) the App has no `issues` permission, so it can never apply
  `agent:ready`; (2) `flowforge-review.yml` ignores every `[bot]` actor, so an Iterator push
  never starts a Reviewer outside the cycle; (3) the review cycle stays `workflow_dispatch`;
  (4) `agent-develop.yml` refuses an `agent:ready` label event sent by a bot, before any state
  change (Phase 7: the Notion Bridge App holds `issues: write`, [notion/submission.md §9](notion/submission.md)).
- **Tests.** `tests/developer-delivery.sh` runs the real *Verify delivery request* step on
  throwaway repositories and checks the invariants (Claude cannot push, token minted after
  Claude, no `issues` permission, token used by the push step only).
- **Validated live** on 2026-10-11: `demo-api` Issue #28 → Draft PR #37 authored by the App, CI
  without approval, human approval and merge without bypass
  ([milestone §14.3](milestones/phase5-refiner-e2e.md)).
- **Required status check.** The `target-repository` module takes `required_status_checks`
  (opt-in, not strict); set it on a target only once the App delivers its agent PRs.
- **Not yet.** Iterator push through the App observed live (needs a `REQUEST_CHANGES`).

### 2.11 GitHub Project sync (Phase 6, Prompt 28)

Details: [github-projects/synchronization.md](github-projects/synchronization.md).

```text
workflow event ──► flowforge-state.sh   (labels: triggers + guards, unchanged)
              └──► flowforge-project.sh (card Status + Attention, best-effort)     never back
```

- **One helper** `.github/scripts/flowforge-project.sh`, fetched at `job.workflow_sha` like the
  state helper: event table (E1–E22 of the model), pure decision function, find-or-add of the
  item (`addProjectV2ItemById` returns the existing item), writes only what differs.
- **Hook points**: Refiner start / result / failure, Developer start / result, Iterator start /
  delivered result (inside `agent-iterate.yml`, passed by the cycle only), cycle start / result
  (two jobs of `review-cycle.yml`), PR merged / closed (`agent-lifecycle.yml`). The Reviewer
  workflow is unchanged.
- **Stale guard**: an event from an unexpected source is applied only if its target is ahead in
  the flow; behind = refused with a warning. Maintainer bypass: `sync-issue.sh --force`.
- **Identity**: the FlowForge App, token with `organization projects: write` only, minted per
  sync; in the jobs that run Claude, an `always()` step revokes the start token before the agent
  starts, elsewhere the action revokes it at job end. Issue reads use `GITHUB_TOKEN`. Still no
  `issues` permission.
- **Opt-in**: input `project_number` (0 = off) on every syncing workflow, callers read the
  organization variable `FLOWFORGE_PROJECT_NUMBER`; IDs come from `config/github-project.json`.
- **Best-effort**: a sync failure is a warning + job summary line, never a failed agent run.
- **Never Project → workflow**: no workflow listens to Project events (tested).

### 2.12 Notion intake and feedback (Phase 7)

Details: [notion/model.md](notion/model.md), [notion/submission.md](notion/submission.md),
[notion/feedback.md](notion/feedback.md); validation: [milestones/phase7-notion-complete.md](milestones/phase7-notion-complete.md).

```text
Notion Need (Submit ✔) ──► notion-submit.yml (FlowForge, maintainer dispatch) ──► 1 Issue in the target
                              checks → allowlist → Bridge App token (1 repository, issues: write)
target workflows (unchanged) ──► labels + GitHub Project card
GitHub Project / Issue / PR ──► notion-sync.yml (FlowForge, schedule + dispatch) ──► Need status in Notion
                              read-only Bridge token, two-sided correlation, writes only what differs
```

- **Central**: both workflows run in FlowForge only; a target receives no Notion logic and no Notion
  secret. `NOTION_TOKEN` and the Bridge App key live in the FlowForge environment `notion-bridge`
  (deployments from `main` only).
- **One way each**: Notion → GitHub is the initial Issue creation only; GitHub → Notion is status
  feedback only. Edits made later on either side are not propagated the other way.
- **Identity**: a dedicated **FlowForge Notion Bridge** App (`issues: write`, `pull_requests: read`,
  `organization_projects: read`), separate from the FlowForge App, which keeps no `issues`
  permission. Issues are created without any label: Notion never starts an agent.
- **Correlation**: one Need ↔ one Issue, keyed by the Notion page ID (Bridge-authored marker in the
  Issue body + `GitHub Issue` URL on the Need, both checked on every sync).

### 2.13 SPEC.md contract (Phase 8.1)

Details: [spec-contract.md](spec-contract.md).

- **What**: every target holds `SPEC.md` at its root, with four level-2 sections (*Objectif et
  périmètre*, *Fonctionnalités*, *Règles et contraintes*, *Scénarios de validation*, or their
  English titles), at least one behaviour and one validation scenario. Structure only, never
  meaning.
- **Where**: step *Check SPEC contract* of `agent-develop.yml`, right after *Resolve issue
  context* and before *Mark issue as running*; it reads `SPEC.md` of `github.repository` on
  `base_branch` through the API (`.github/scripts/flowforge-spec.sh`, fetched at
  `job.workflow_sha`).
- **On failure**: the run fails like any other precondition, no label, Project card, branch or
  agent is touched; the Issue keeps `agent:ready`. `FAILED` (conformity) and `ERROR` (technical,
  never reported as "absent") are distinct diagnostics.
- **Not gated**: Refiner, Reviewer, Iterator, review cycle, lifecycle and Notion workflows. Every
  development, whatever the origin of the Issue, starts through `agent-develop.yml`.
- **Phase 8.2 — use by the agents** ([spec-contract §7](spec-contract.md#7--how-the-agents-use-specmd-phase-82)):
  the Refiner reads `SPEC.md` from the checked-out default branch and returns `spec_impact`
  (`COMPLIANT` / `EXTENDS` / `NEW_FEATURE` / `MODIFIES` / `CONTRADICTS` / `NEEDS_DECISION` /
  `NO_SPEC`), the cited items and the contract changes; the workflow decides whether `SPEC.md`
  exists and `flowforge_refine_validate` refuses a `READY` that skips an arbitration. The refined
  Issue gains *Specification* and *Definition of Done*. Developer, Reviewer and Iterator rules
  read `SPEC.md`; their workflows only gain one prompt line. No new agent, workflow, label or
  dependency.

------

## 3. 📐 Contract between FlowForge and a target

| Item | Provided by | Notes |
|---|---|---|
| `agent:*` labels | FlowForge (Terraform) | Created by the module: `agent:needs-clarification`, `agent:ready`, `agent:running`, `agent:review`, `agent:blocked`, `agent:done` (§2.6) |
| `flowforge-lifecycle.yml` | target (copied from `examples/`) | `pull_request: closed` on `agent/*` → `agent-lifecycle.yml`; `issues: write`, `pull-requests: read`, no secret |
| Review cycle job permissions | target caller | `contents: write`, `issues: write` (the `issue_state` job only), `pull-requests: write`, `checks`, `statuses: read` |
| `flowforge-agent.yml` | target (copied from `examples/`) | Only trigger + `uses:` + inputs |
| `issue_number`, `base_branch` | target → FlowForge | `workflow_call` inputs |
| `setup_uv`, `allowed_tools` | target → FlowForge | Optional inputs: target tooling and the exact commands the agent may run |
| `claude_code_oauth_token` | `CLAUDE_CODE_OAUTH_TOKEN` secret → FlowForge | Org secret (Selected repositories) or repo secret; passed explicitly, never `secrets: inherit` |
| `app_client_id`, `app_private_key` | `FLOWFORGE_APP_CLIENT_ID` variable, `FLOWFORGE_APP_PRIVATE_KEY` secret → FlowForge (Developer, review cycle → Iterator) | Optional: FlowForge GitHub App delivery identity, one App for all targets (§2.10); empty = `GITHUB_TOKEN` delivery |
| Job permissions | target caller | `contents: write`, `issues: write`, `pull-requests: write` (a called workflow can only narrow) |
| `branch`, `pull_request` | FlowForge → target | `workflow_call` outputs |
| `flowforge-review.yml` | target (copied from `examples/`) | Calls `agent-review.yml` |
| `pull_request_number` | target → FlowForge (Reviewer) | Only required input; base, head, Issue and CI are resolved from it |
| Reviewer job permissions | target caller | `contents`, `issues`, `checks`, `statuses: read`; `pull-requests: write` (the comment only) |
| `pull_request_number`, `iteration_number`, `max_iterations`, `review_json` | target → FlowForge (Iterator) | `review_json` = the Reviewer's `review.json`; base, head, Issue resolved from the PR |
| Iterator job permissions | target caller | `contents: write` (the push job only), `issues: read`, `pull-requests: read` |
| `verdict`, `result_artifact`, `review_json`, `no_op_json` | FlowForge → target (Reviewer) | `review_json`: full `review.json`, compact JSON; `no_op_json`: set only on `NO_OP` (§5.2) |
| `result`, `commit_sha`, `result_artifact`, `iteration_json`, `no_op_json` | FlowForge → target (Iterator) | `iteration_json`: final `iteration.json` (per-finding statuses), compact JSON; `no_op_json`: set only on `NO_OP`, then `result` is empty (§2.5.1) |
| `flowforge-review-cycle.yml` | target (copied from `examples/`) | Calls `review-cycle.yml`, `workflow_dispatch` only |
| `pull_request_number`, `max_iterations` (+ `setup_uv`, `review_allowed_tools`, `iterate_allowed_tools`) | target → FlowForge (cycle) | Base/head branches resolved from the PR by each agent workflow, never passed in |
| Cycle job permissions | target caller | Union of both agents: `contents: write`, `pull-requests: write`, `issues`/`checks`/`statuses: read`; each called job narrows it |
| `result`, `iterations_used`, `final_reviewer_verdict`, `cycle_json` | FlowForge → target (cycle) | `workflow_call` outputs |
| `flowforge-refine.yml` | target (copied from `examples/`) | Calls `agent-refine.yml`, `workflow_dispatch` only |
| `issue_number` | target → FlowForge (Refiner) | Only input; default branch resolved from the repository |
| Refiner job permissions | target caller | `contents: read`, `pull-requests: read`, `issues: write` (the `publish` job only; the agent job has `issues: read`) |
| `verdict`, `result_artifact`, `refinement_json` | FlowForge → target (Refiner) | `refinement_json`: `refinement.json` compact (§5.8); empty on technical failure |
| `agent:needs-clarification` | FlowForge (Terraform) | Sixth state label; until a target applies the module, the Refiner skips it with a warning |
| `SPEC.md` | target | **Required** by the Developer: root of the base branch, minimal structure of [spec-contract.md](spec-contract.md) (§2.13) |
| `CLAUDE.md` | target | Optional but strongly recommended |
| CI | target | FlowForge never replaces the target's CI |

### 3.1 Versioning

From `v0.1.0` (Prompt 39.1, experimental POC version), a FlowForge version is an annotated
tag `vX.Y.Z` on `main`. Targets consume the module with a Git source `?ref=vX.Y.Z` and pin
their callers to that tag's **full commit SHA**, the same in all five. The reusable workflows
fetch their scripts at `job.workflow_sha`, so the caller SHA pins everything. Tags are never
moved. Update and rollback: [target-onboarding.md §10](target-onboarding.md).

------

## 4. 🔐 Security model

| Principle | How |
|---|---|
| No secret in Git | `.gitignore` (tfstate, tfvars, .env, keys), `detect-private-key` hook, token only via env |
| No secret in Terraform state | Actions secrets are provisioned outside Terraform |
| Least privilege (Actions) | `permissions: {}` at workflow level; the Developer job gets `contents`/`issues`/`pull-requests: write` only, no `id-token` |
| Bounded agent | `--max-turns 40` + 30-min job timeout; Bash denied except an explicit allowlist (git read/commit, `gh issue view/comment` on its Issue, target commands); no push, no `gh pr create` |
| Delivery not in the agent's hands (Developer) | Claude only commits and writes a PR request (`.flowforge-pr/`); a workflow step verifies the branch and commits, then pushes and opens the Draft PR (§2.10) |
| Delivery identity | FlowForge GitHub App token minted after Claude ends, scoped to the calling repository, `contents` + `pull-requests` only (Iterator: `contents`), no `issues`; fallback `GITHUB_TOKEN` (§2.10) |
| Least privilege (Terraform) | Fine-grained token limited to onboarded repositories |
| Untrusted issue content | Read via `env` + `jq`, never `${{ }}`-interpolated into scripts; treated as data by the agent |
| No direct push to `main` | Only the workflow pushes, to the `agent/*` branch it created, after checking it is neither the base nor the default branch + agent rules + default-branch ruleset (pull request required, no force push, no deletion — §2.7) |
| Human merge | Agent opens **Draft** PRs only (forced back to draft by the workflow if needed); the default-branch ruleset requires ≥ 1 GitHub approval, which the agent identity cannot give; no bypass for FlowForge, no auto-merge, no automatic Draft → Ready (§2.7) |
| Pinned actions | Third-party actions pinned by commit SHA |
| Read-only Reviewer | Review job has no write permission; publish job has `pull-requests: write` only and never runs PR code; Edit/Write tools disallowed; `persist-credentials: false` |
| Reviewer configuration not controlled by the PR | `CLAUDE.md`, `CLAUDE.local.md`, `.claude/`, `.mcp.json` reset to the base branch in the local workspace before Claude runs; fork PRs rejected |
| No silent approval | Missing, invalid or inconsistent Reviewer output becomes a workflow-set `BLOCKED` and fails the run |
| Iterator push is not in the agent's hands | Claude runs with a read-only token and no push permission; a separate job, which runs no PR code, verifies the commit and fast-forward pushes it to the PR head branch only |
| Bounded Iterator | `iteration_number <= max_iterations`, ceiling 3, checked before any checkout; stale review (`head_sha` ≠ PR head) refused |
| Read-only Refiner | Agent job has read permissions only, no push credentials, edit tools disallowed, Bash read-only; a changed workspace fails the run; the `publish` job (`issues: write`) runs no agent; the original request and the record are written by the workflow, not by the model |
| Project sync identity | FlowForge App token with `organization projects: write` only, minted per sync, revoked before Claude in agent jobs (`always()` step) and at job end elsewhere, never given to Claude; Issue reads via `GITHUB_TOKEN`; the Project never triggers a workflow (§2.11) |
| Notion credential | `NOTION_TOKEN` only in the FlowForge environment `notion-bridge` (deployment branch `main`), never in a target, never in a job that runs Claude; Notion text is untrusted input, sanitised and capped (§2.12) |
| Notion Bridge identity | Dedicated App, token minted per run for the single target repository and revoked at job end; issues created without labels, so Notion cannot start an agent; destination from Notion relations checked against the Git allowlist (§2.12) |
| Bounded review cycle | Static chain with exactly three Iterator jobs (no 4th pass can exist), `max_iterations` checked before any agent, one active cycle per PR (concurrency group); the cycle never merges, never marks a PR ready, never deletes a branch |

------

## 5. ✅ Decisions taken (Phase 1, step 5)

| Topic | Decision |
|---|---|
| How Claude Code runs | `anthropics/claude-code-action` (pinned SHA), automation mode (`prompt` set): no tracking comment, no branch/PR created by the action |
| Authentication | `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`) only — no API key, no Anthropic WIF |
| Delivery of `agents/developer.md` | Fetched at `job.workflow_sha` from `job.workflow_repository` and embedded in the prompt |
| Branch | Created by the workflow (`git switch -c`) before Claude runs; Claude only commits on it, the workflow pushes it (§2.10) |
| Identity used to push and open PRs | ~~Workflow `GITHUB_TOKEN` passed as `github_token`~~ Superseded by Issue #34 (2026-10-11): FlowForge GitHub App installation token, used by a workflow step, never by Claude; `GITHUB_TOKEN` stays the fallback and Claude's token (§2.10) |

> ⚠️ **Warning**: with the `GITHUB_TOKEN` fallback, the target must allow *"GitHub Actions to
> create and approve pull requests"*, and PRs it opens do **not** run `pull_request` workflows
> on their own: the run stays `action_required` until a maintainer approves it. The FlowForge
> GitHub App removes this (§2.10).

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
| PR no longer open | `CLOSED` or `MERGED` when read (preconditions, then before the push): `NO_OP`, run succeeds, nothing pushed, `result` empty, `no_op_json` with `reason` and `stage` (§2.5.1). Every other precondition failure stays a workflow `BLOCKED` |
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
| Permissions | `permissions: {}` at workflow level; each call job gets what its called workflow requests, which narrows it per job: `contents: write` only reaches the Iterator push job, `pull-requests: write` only the Reviewer publish job, `issues: write` only `issue_state` (§2.6); `summary` has none |
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
- Review and iterate entries carry `no_op_reason`: `PR_ALREADY_CLOSED` or
  `PR_ALREADY_MERGED` for a no-op Reviewer (then `verdict` is empty) or Iterator (then
  `result` is empty), `null` otherwise.
- `timeline`: only the jobs that ran, in order; `job_result` ∈ `success | failure | cancelled`.
- `iterations_used`: Iterator jobs engaged (succeeded or not). `final_reviewer_verdict`: the
  last verdict produced, empty when no Reviewer produced one.

### 5.7 Refiner decisions (Phase 5, Prompt 22)

| Topic | Decision |
|---|---|
| Workflow | `agent-refine.yml` (`workflow_call`), two jobs like the Reviewer: agent read-only, publish write-only |
| Trigger | `workflow_dispatch` on the target, one Issue per run |
| Where the result goes | Issue title and body rewritten (contract §2), original kept verbatim in it by the workflow; single updated comment |
| Labels | `agent:needs-clarification` created in the module and added to the state helper; `READY` removes it; `agent:ready` stays human-only |
| Technical failure | Run fails, Issue untouched; no workflow-set verdict (unlike the Reviewer's `BLOCKED`): a refinement is a proposal, there is nothing safe to publish without one |
| Result contract | `refinement.json`, `schema_version: 1` (§5.8; `2` since Phase 8.2) |

### 5.8 Refinement result contract (`refinement.json`, `schema_version: 2`)

Artifact `flowforge-refine-issue-<n>` holds `refinement.json` (also the `refinement_json`
output), `comment.md`, and for `READY` / `NEEDS_CLARIFICATION` `title.txt` and `body.md`; a
rejected agent output is kept as `rejected-output.json`.

```json
{
  "schema_version": 2,
  "repository": "owner/name",
  "issue": 12,
  "author": "requester-login",
  "original_title": "Version endpoint",
  "input_digest": "sha256 of title + body read before the agent ran",
  "run_url": "https://github.com/...",
  "rules_sha": "FlowForge commit of agents/refiner.md",
  "refined_at": "2026-10-10T12:00:00Z",
  "spec_present": true,
  "verdict": "READY",
  "blocked_reason": "",
  "title": "feat: add GET /version endpoint",
  "context": ["… `[provided]`"], "goal": "…", "scope": ["…"], "out_of_scope": ["…"],
  "acceptance_criteria": ["… `[recommended]`"], "constraints": ["…"], "references": ["…"],
  "open_questions": [{ "question": "…", "blocking": false, "default": "…" }],
  "assumptions": ["`[assumption]` …"], "notes_for_agents": ["…"],
  "proposed_labels": ["`agent:ready` (to be applied by a human)"],
  "added": "…", "references_used": ["…"],
  "spec_impact": "EXTENDS",
  "spec_references": ["`F-005` — Task listing (`CONFIRMED`): …"],
  "spec_changes": ["Add `S-020` — …"],
  "definition_of_done": ["…"]
}
```

- `verdict` ∈ `READY | NEEDS_CLARIFICATION | BLOCKED`; `FAILED` is never written: it is a
  failed run without artifact result.
- Fields after `verdict` are the agent's structured output; the ones before are added by the
  workflow.
- `schema_version: 2` (Phase 8.2) adds `spec_present` (workflow) and `spec_impact`,
  `spec_references`, `spec_changes`, `definition_of_done` (agent); rules in
  [refiner §5.4](../agents/refiner.md#54-compare-with-specmd). The Issue body marker stays
  `schema_version=1`: the body sections are additive and the markers unchanged.

### 5.9 Notion decisions (Phase 7, Prompts 31–36)

| Topic | Decision |
|---|---|
| Role of Notion | Business intake and high-level tracking only; GitHub (Issue, Project, Actions, PR) stays the technical source of truth |
| Granularity | One Need → one target repository → one Issue (1:1, idempotent on the Notion page ID) |
| Submission trigger | `workflow_dispatch` by a maintainer (`notion-submit.yml`); no automatic trigger in the POC |
| Issue-creation identity | Separate FlowForge Notion Bridge App; the FlowForge App never gets `issues` (anti-loop) |
| Routing truth | `config/notion-allowlist.json` in Git + coherence Project ↔ Repository checked before any GitHub credential |
| Feedback shape | Central reconciler in FlowForge (`notion-sync.yml`, `schedule` + dispatch), not per-target hooks |
| Contributors | `Requested by` / `Created by` are business data, never mapped to a GitHub identity |
| Statuses | `Draft` and `Closed` exist only in Notion; `Backlog` … `Done` are mirrored from the GitHub Project; `Integration status` is separate from `FlowForge Status` |

## 6. 🚧 Open design decisions

| Topic | To decide at |
|---|---|
| Remote Terraform backend | Before the first `apply` |
| Required status checks in the default-branch ruleset | Once targets have a stable CI check |
| Automatic start of the review cycle after the Developer (today: `workflow_dispatch`) | After the review cycle E2E |
| Refiner label trigger (`agent:refine`) or automatic refinement on Issue opened | After the Refiner E2E (Prompts 23–24) |
| Aligning `.github/ISSUE_TEMPLATE/feature.yml` with the refined Issue contract | After the Refiner E2E |
