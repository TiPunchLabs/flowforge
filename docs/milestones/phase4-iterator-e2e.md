# 🏁 Milestone — Phase 4: Iterator E2E

> **Tag**: `flowforge-phase4-iterator-e2e` (annotated, on FlowForge and `demo-api`)
> **Date**: 2026-10-07/08 (UTC)
> **Status**: ✅ Validated with reservations (§7) — Developer, Reviewer, Iterator and the bounded
> review cycle run end to end on `demo-api`; no auto-merge, no agent push to `main`.

------

## 🧠 Mental Model

```text
demo-api Issue ──agent:ready──► agent-develop.yml ──► Draft PR (bot)
                                                          │  human: gh workflow run
                                                          ▼  flowforge-review-cycle.yml
                         review-cycle.yml  (one cycle per PR, concurrency group)
                           Reviewer #1 ── REQUEST_CHANGES ──► Iterator #1 ── commit, ff push
                                ▲                                   │
                                └──────────── Reviewer #2 ◄─────────┘
                                                  │ APPROVE
                                                  ▼
                                   APPROVED → human: Ready → merge
```

------

## 1. 🎯 Objective of Phase 4

Close the loop after the Reviewer: an **Iterator** agent fixes the findings of a
`REQUEST_CHANGES` review on the existing PR branch, then hands the PR back to the Reviewer, in a
loop bounded to `max_iterations = 3`, with a structured final result and a human merge gate.

## 2. 📦 Delivered

| Item | Where | FlowForge PR |
|---|---|---|
| Iterator specification (finding statuses, results `COMPLETED` / `PARTIAL` / `BLOCKED`) | `agents/iterator.md` | #11 |
| Reusable Iterator workflow, one iteration per call (`iterate` read-only + `publish` push jobs) | `.github/workflows/agent-iterate.yml` | #12 |
| Bounded review cycle (unrolled chain, `if:` gates, final result, `cycle.json`) | `.github/workflows/review-cycle.yml` | #13 |
| Target caller template (`workflow_dispatch` only) | `examples/target-repository/flowforge-review-cycle.yml` | #13 |
| Architecture and decisions (§2.4, §2.5, §5.3–§5.5) | `docs/architecture.md` | #11–#13 |

Target side (`demo-api`): caller `flowforge-review-cycle.yml` (demo-api #10), and API reference
moved from `CLAUDE.md` to `README.md` (demo-api #21, see §7).

## 3. 🏗️ Architecture of the cycle

```text
target repo (demo-api)                          FlowForge (central, @main)
──────────────────────                          ──────────────────────────
flowforge-review-cycle.yml ── workflow_call ──► review-cycle.yml
  (workflow_dispatch,                             check → review_1 → iterate_1 → review_2 → …
   pull_request_number)                                  → iterate_3 → review_4 → summary
                                                  agent-review.yml   (Reviewer, read-only)
                                                  agent-iterate.yml  (Iterator, one pass)
```

- `review-cycle.yml` decides who runs and when; it never reads code nor judges a review.
- `iterate_k` runs only if `review_k` returned `REQUEST_CHANGES`; `review_k+1` only if
  `iterate_k` returned `COMPLETED` or `PARTIAL`. There is no job for a 4th Iterator.
- Concurrency group `flowforge-review-cycle-<repository>-<pr>`, `cancel-in-progress: false`.

## 4. 🔐 Triggers and permissions

| Workflow | Trigger (target caller) | Job permissions |
|---|---|---|
| Review cycle | `workflow_dispatch` (`pull_request_number`) only — no `pull_request` / `push` | caller grants the union; each called job narrows it |
| Iterator — `iterate` job | (called by the cycle) | `contents`, `issues`, `pull-requests`: **read**; `persist-credentials: false` |
| Iterator — `publish` job | (same run) | `contents: write` only — no Claude, no PR code; verifies one fast-forward commit, pushes it |

The Iterator commits locally; the commit leaves the job as a git bundle and is pushed by the
`publish` job only after it checks the head SHA, the single commit, and that no agent
configuration (`CLAUDE.md`, `.claude/`, `.mcp.json`) or workflow file is touched.

## 5. 🤖 Role of Claude Code in the runners

Unchanged for the Developer and the Reviewer (see the Phase 3 milestone). The **Iterator** works
on the PR head branch with a read-only token, fixes only the findings, runs the target's tests,
lint and format commands (`iterate_allowed_tools`), and returns a JSON-schema-constrained
`iteration.json` validated by the workflow. It never pushes, rebases, merges, or changes the PR.

## 6. ✅ Validated E2E scenarios and evidence

All runs executed FlowForge **`647e663`** (`referenced_workflows` of every run below).

### 6.1 Developer → review cycle (4 natural scenarios)

| Issue | Developer run | Draft PR | Cycle run | Result |
|---|---|---|---|---|
| [#11](https://github.com/TiPunchLabs/demo-api/issues/11) `GET /info` | [37646258627](https://github.com/TiPunchLabs/demo-api/actions/runs/37646258627) | [#12](https://github.com/TiPunchLabs/demo-api/pull/12) | [37646560085](https://github.com/TiPunchLabs/demo-api/actions/runs/37646560085) | `APPROVED`, 0 / 3 |
| [#13](https://github.com/TiPunchLabs/demo-api/issues/13) filter + paginate | [37646829748](https://github.com/TiPunchLabs/demo-api/actions/runs/37646829748) | [#14](https://github.com/TiPunchLabs/demo-api/pull/14) | [37647072999](https://github.com/TiPunchLabs/demo-api/actions/runs/37647072999) | `APPROVED`, 0 / 3 |
| [#15](https://github.com/TiPunchLabs/demo-api/issues/15) priority + PATCH | [37647667804](https://github.com/TiPunchLabs/demo-api/actions/runs/37647667804) | [#16](https://github.com/TiPunchLabs/demo-api/pull/16) | [37647966252](https://github.com/TiPunchLabs/demo-api/actions/runs/37647966252) | `APPROVED`, 0 / 3 |
| [#17](https://github.com/TiPunchLabs/demo-api/issues/17) bulk + stats | [37694663934](https://github.com/TiPunchLabs/demo-api/actions/runs/37694663934) | [#18](https://github.com/TiPunchLabs/demo-api/pull/18) | [37694939087](https://github.com/TiPunchLabs/demo-api/actions/runs/37694939087) | `APPROVED`, 0 / 3 |

Each `APPROVE` was checked independently (tests re-run, edge cases probed): none was lenient.

### 6.2 Reviewer → Iterator → Reviewer ([demo-api PR #20](https://github.com/TiPunchLabs/demo-api/pull/20))

PR #20 (Issue [#19](https://github.com/TiPunchLabs/demo-api/issues/19), `POST /tasks/{id}/toggle`)
is a work-in-progress draft written by Claude Code in an interactive session at the
maintainer's request, declared as such in the PR body: nominal path and nominal test only. No
defect was injected after the Developer.

| Step | Evidence |
|---|---|
| Cycle #1 — Reviewer #1 | [37699012192](https://github.com/TiPunchLabs/demo-api/actions/runs/37699012192): `REQUEST_CHANGES` (2 MAJOR, 1 NOTE) on `b2136a7` |
| Cycle #1 — Iterator #1 | `BLOCKED`: the fix required the `CLAUDE.md` API table, which the Iterator may never commit; no push. Cycle result `BLOCKED`, run green (business result, not `FAILED`) |
| Fix on the target | demo-api #21 moved the API reference to `README.md`; Issue #19 criterion updated accordingly |
| Cycle #2 — Reviewer #1 | [37699990351](https://github.com/TiPunchLabs/demo-api/actions/runs/37699990351): `REQUEST_CHANGES` (2 MAJOR, 1 MINOR) on `377f0ab` |
| Cycle #2 — Iterator #1 | `COMPLETED`: 4 `FIXED`, 1 `NOT_ACTIONABLE` (PR title); pytest / ruff / format `PASS`; one commit `30a66a1` by `claude[bot]`, fast-forward pushed by `github-actions[bot]` to `wip/19-toggle-task` |
| Cycle #2 — Reviewer #2 | `APPROVE` on `30a66a1` (the new head), all criteria `PASS`. Cycle result `APPROVED`, 1 / 3 |
| Publication | [single FlowForge comment](https://github.com/TiPunchLabs/demo-api/pull/20#issuecomment-6048511310), updated in place |
| Human gate | PR #20 left Draft by FlowForge; Ready and merge by `xgueret` → `9d24dd2` |

### 6.3 Concurrency

A second cycle dispatched on PR #12 while the first was running stayed `pending` (its 2-second
`check` job never started), then was cancelled: [37646624881](https://github.com/TiPunchLabs/demo-api/actions/runs/37646624881).
The Iterator push (`GITHUB_TOKEN`) started no second cycle.

### 6.4 Integration of the Developer PRs

PRs #14, #16 and #18 were brought up to date with `main` by a maintainer sub-agent (merge of
`main`, plain push, no force-push), re-reviewed by `FlowForge review`
([37713343789](https://github.com/TiPunchLabs/demo-api/actions/runs/37713343789) →
`REQUEST_CHANGES` because Issue #13 still required the removed `CLAUDE.md` table;
[37714356515](https://github.com/TiPunchLabs/demo-api/actions/runs/37714356515) cycle →
`APPROVED` after the specs were updated;
[37786195259](https://github.com/TiPunchLabs/demo-api/actions/runs/37786195259) and
[37788699438](https://github.com/TiPunchLabs/demo-api/actions/runs/37788699438) → `APPROVE`),
then merged by a human. The #16 merge caught a real integration bug (toggle reset `priority`).

### 6.5 Safety checks on the final state

| Check | Result |
|---|---|
| `main` | `2278ce5` → `4185089` through 7 `pr_merge` by `xgueret` only; no agent push |
| Force-push | 0 `force_push` events in the repository activity |
| Auto-merge / auto Draft → Ready | none |
| Secrets | 18 runs with logs, 53.3k lines: no `sk-ant`, `ghp_`/`ghs_`/`gho_`/`github_pat_` value; OAuth token always `***` |
| `write-all`, `secrets: inherit` | none |
| Tests on final `main` | pytest 56 passed, ruff and format clean, pre-commit clean |
| Comments | exactly one FlowForge comment per PR (#12, #14, #16, #18, #20) |

## 7. ⚠️ Limitations and known risks

- **Developer → Iterator never observed on the same PR.** The four Developer PRs were approved
  without iteration; the Iterator ran on a declared WIP draft. No code links the two (the cycle
  only takes a PR number), but the literal Prompt 14 chain was not observed in one run.
- **`MAX_ITERATIONS_REACHED` and `FAILED`** are enforced by the code, not observed live.
- **A single `BLOCKED` finding discards every feasible fix**: the Iterator returns `BLOCKED` and
  pushes nothing, even when other findings were fixable. Safe, but wasteful.
- **Agent configuration is out of the Iterator's reach**: `CLAUDE.md` is pinned and never
  committed by the Iterator, so a target must not keep product documentation there (fixed on
  `demo-api` by #21).
- **Findings outside the repository** (Issue text, PR description, PR title) can only be fixed
  by a human; Issues written before a convention change produce such findings.
- **Review of a PR merged in the meantime** fails the run (`expected OPEN`) instead of skipping.
- **Bot-triggered `action_required` runs** must not be approved for a PR handled by the cycle;
  they end as `failure` (0 jobs) when the PR closes.
- **Closed Issues keep `agent:review`**; targets still track `@main`; the default-branch
  ruleset requiring a human approval is still planned, not enforced.

## 8. 🧭 Architectural decisions retained

See `docs/architecture.md` §5.3–§5.5. In short: one iteration per workflow call; the loop is a
static chain (no 4th Iterator can exist); the Iterator never holds a write token next to PR
code; agent results (`BLOCKED`, `MAX_ITERATIONS_REACHED`) end the cycle green, only technical
failures (`FAILED`) turn it red; one cycle per PR; the cycle never merges, never marks a PR
ready, never deletes a branch.

## 9. 🔖 Exact Git references

| Repository | Validated commit | Why this commit | Tag |
|---|---|---|---|
| `TiPunchLabs/flowforge` | `647e663297c3777c1273530b1e75c4b55fb63f51` | `main` HEAD executed by every Developer, Reviewer, Iterator and cycle run of this milestone | `flowforge-phase4-iterator-e2e` → this commit |
| `TiPunchLabs/demo-api` | `9d24dd2` | Human merge of PR #20, the PR on which the Iterator ran (cycle #2) | `flowforge-phase4-iterator-e2e` → this commit |
| `TiPunchLabs/demo-api` | `4185089` | Final state after all PRs of the session were merged and verified (§6.5) | — |

> 💡 **Note**: as for Phase 3, the FlowForge tag points to the **validated** commit
> (`647e663`), not to the later commit adding this document. Previous milestone:
> `flowforge-phase3-reviewer-e2e` (FlowForge `2ca4e57`, demo-api `b76dbbb`), left unchanged.

## 10. 🚀 Next

1. **Iterator partial delivery**: classify a finding that touches a protected file as
   `NOT_ACTIONABLE` (human required) and push the feasible fixes as `PARTIAL`.
2. **Skip, don't fail** a review whose PR is no longer open.
3. **Human gate notes** in the caller template (`action_required` runs, conflicts between agent PRs).
4. **Pin targets** to a FlowForge tag or SHA; **GitHub App identity**; **default-branch ruleset**.
5. Later: Refiner agent, GitHub Project, Notion.

------

> **Document created on**: 2026-10-08
> **Author**: xgueret, with Claude Code
> **Version**: 1.1 — tag created
