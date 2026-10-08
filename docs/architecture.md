# 🏗️ FlowForge — Architecture

> **Status**: Phases 1–4 done (Foundation, Developer E2E, Reviewer E2E, Iterator E2E — with reservations, see [milestone](milestones/phase4-iterator-e2e.md)). Phase 4.1 (hardening & lifecycle) implemented, live validation pending (§2.8). Describes the target design; see [phase-1.md](phase-1.md) for what exists today.

------

## 🧠 Mental Model

```text
           ┌──────────────────────── FlowForge (central) ────────────────────────┐
           │  terraform/            .github/workflows/        agents/            │
           │  target-repository     agent-develop.yml         developer.md       │
           │  module                agent-review.yml          reviewer.md        │
           │                        agent-iterate.yml         iterator.md        │
           │                        review-cycle.yml          (generic rules)    │
           │                        agent-lifecycle.yml                          │
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
| State helper | `.github/scripts/flowforge-state.sh` | The one implementation of Issue state label transitions (§2.6), fetched by the workflows at their own commit |
| Agent rules | `agents/*.md` | Generic, project-independent behavior of each agent: `developer.md`, `reviewer.md`, `iterator.md` |
| Caller templates | `examples/target-repository/` | What a target repository copies (`flowforge-agent.yml`, `flowforge-review.yml`, `flowforge-review-cycle.yml`, `flowforge-lifecycle.yml`) |
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
| Ready | `agent:ready` | human | Issue refined | — (trigger of the Developer) |
| Running | `agent:running` | `agent-develop.yml` | Developer starts (preconditions passed) | every other state, and `ready_label` |
| Review | `agent:review` | `agent-develop.yml` | A Draft PR exists at the end of the Developer run (even if Claude Code then failed: the review judges it) | every other state |
| Blocked | `agent:blocked` | `agent-develop.yml` | Claude Code ended normally without a Draft PR: the agent stopped and commented (rules §8) | every other state |
| Blocked | `agent:blocked` | `review-cycle.yml` (`issue_state`) | cycle result `BLOCKED` or `MAX_ITERATIONS_REACHED`, PR still open, Issue in `agent:review` | every other state |
| Done | `agent:done` | `agent-lifecycle.yml` | PR **merged** (by a human), Issue in `agent:review` or `agent:blocked` | every other state |

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
  cycle, which owns the decision, does.
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
`agent:review`, `agent:blocked`, `agent:done` (plus `ready_label`), adds the target if
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

**Future GitHub Project mapping** (not implemented): one Status field value per state, so a
Project automation (or a label → field sync) maps one-to-one.

| Project status | FlowForge state |
|---|---|
| Backlog | no `agent:*` state label |
| Ready | `agent:ready` |
| Developing | `agent:running` |
| Review | `agent:review` |
| Blocked | `agent:blocked` |
| Done | `agent:done` |

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
- no required status check yet (no stable target check);
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
| #17 Iterator partial delivery (`PARTIAL`) | ✅ done (§5.3, `tests/iterator-partial-delivery.sh`) | ⏳ pending: a real `PARTIAL` delivery |
| #18 closed / merged PR = `NO_OP` | ✅ done (§2.5.1, `tests/review-no-op.sh`) | ⏳ pending: a real close / merge race during a cycle |
| #19 Issue label lifecycle | ✅ done (§2.6, `tests/label-lifecycle.sh`), rolled out on `demo-api` | ⏳ pending: a real `pull_request: closed`, `agent:review` → `agent:done` |
| Human merge gate (default-branch ruleset) | ✅ done (§2.7, `terraform test` of the module) | ⏳ pending: `apply` on `demo-api`, then a merge refused without approval |

Only offline tests back these items so far; none is claimed validated live until the
Phase 4.1 stabilization E2E has run.

------

## 3. 📐 Contract between FlowForge and a target

| Item | Provided by | Notes |
|---|---|---|
| `agent:*` labels | FlowForge (Terraform) | Created by the module: `agent:ready`, `agent:running`, `agent:review`, `agent:blocked`, `agent:done` (§2.6) |
| `flowforge-lifecycle.yml` | target (copied from `examples/`) | `pull_request: closed` on `agent/*` → `agent-lifecycle.yml`; `issues: write`, `pull-requests: read`, no secret |
| Review cycle job permissions | target caller | `contents: write`, `issues: write` (the `issue_state` job only), `pull-requests: write`, `checks`, `statuses: read` |
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
| No direct push to `main` | Only `git push origin HEAD:refs/heads/<agent branch>` is allowed + agent rules + default-branch ruleset (pull request required, no force push, no deletion — §2.7) |
| Human merge | Agent opens **Draft** PRs only (forced back to draft by the workflow if needed); the default-branch ruleset requires ≥ 1 GitHub approval, which the agent identity cannot give; no bypass for FlowForge, no auto-merge, no automatic Draft → Ready (§2.7) |
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
- Review entries carry `no_op_reason`: `PR_ALREADY_CLOSED` or `PR_ALREADY_MERGED` for a
  no-op Reviewer (then `verdict` is empty), `null` otherwise.
- `timeline`: only the jobs that ran, in order; `job_result` ∈ `success | failure | cancelled`.
- `iterations_used`: Iterator jobs engaged (succeeded or not). `final_reviewer_verdict`: the
  last verdict produced, empty when no Reviewer produced one.

## 6. 🚧 Open design decisions

| Topic | To decide at |
|---|---|
| Remote Terraform backend | Before the first `apply` |
| Required status checks in the default-branch ruleset | Once targets have a stable CI check |
| Automatic start of the review cycle after the Developer (today: `workflow_dispatch`) | After the review cycle E2E |
