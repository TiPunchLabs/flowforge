# 🛡️ Milestone — Phase 4.1: Hardening & lifecycle E2E

> **Date**: 2026-10-09 (UTC)
> **Status**: ✅ Validated E2E, with one reservation (§7) — Iterator `PARTIAL`, `NO_OP` on merged
> and closed PRs, `agent:done` after a human merge, and the default-branch ruleset observed live
> on `demo-api`. No tag yet (frozen in a separate step).

------

## 🧠 Mental Model

```text
Issue #24 ──agent:ready──► Developer ──stops (workflow file)──► agent:blocked
   │                                                               │
   └── WIP Draft PR #25 (agent/24-…) ──► review cycle 37937948534  │
          Reviewer #1  REQUEST_CHANGES (1 BLOCKER, 3 MAJOR, 1 NOTE) │
          Iterator #1  PARTIAL  6 FIXED · 3 NOT_ACTIONABLE ─► 6bd20d0
          Reviewer #2  REQUEST_CHANGES on 6bd20d0 (ci.yml remains) │
          Iterator #2  BLOCKED  0 FIXED ─► cycle BLOCKED (green)    │
      human commit ci.yml 1e96d86 ─► Reviewer APPROVE               │
      GitHub: REVIEW_REQUIRED, merge blocked ─► human merge 1db2601 │
                                   │                                ▼
              pull_request.closed ─► lifecycle ─► Issue #24 CLOSED, agent:done
   cycle on merged PR #25 ─► NO_OP · cycle on closed PR #26 ─► NO_OP
```

------

## 1. 🎯 Objective

Prove live the four Phase 4.1 guarantees that offline tests could not: a real Iterator
`PARTIAL` (#17), `NO_OP` on a pull request no longer open (#18), the `agent:done` transition
after a human merge (#19), and the human merge gate enforced by GitHub.

## 2. 🏗️ Environment

| Item | Value |
|---|---|
| FlowForge | `77763ec77f311e639dddc815e0ece97ec4d04a07` (`main`, `referenced_workflows` of every run below) |
| demo-api before / after | `11220e9` → `1db2601` (human merge of PR #25) |
| Runner | `ubuntu-24.04`, image `20261004.327.1`, runner `2.337.0` |
| Callers | `@main`, `max_iterations: 3`, explicit permissions, explicit secret (no `secrets: inherit`) |

## 3. ✅ #17 — Iterator partial delivery

| Step | Evidence |
|---|---|
| Issue | [#24](https://github.com/TiPunchLabs/demo-api/issues/24): `POST /tasks/{id}/duplicate` + `.github/workflows/ci.yml` |
| Developer | [37937420587](https://github.com/TiPunchLabs/demo-api/actions/runs/37937420587): stopped without a PR (GitHub rejects a `GITHUB_TOKEN` push of a workflow file) → `agent:blocked` |
| Draft PR | [#25](https://github.com/TiPunchLabs/demo-api/pull/25), WIP declared in the body (nominal path only, `0fe30e6`), same precedent as Phase 4 PR #20 |
| Cycle | [37937948534](https://github.com/TiPunchLabs/demo-api/actions/runs/37937948534) |
| Reviewer #1 | `REQUEST_CHANGES` on `0fe30e6`: BLOCKER 404 missing, MAJOR tests, MAJOR README, MAJOR `ci.yml`, NOTE |
| Iterator #1 | **`PARTIAL`**: 6 `FIXED`, 3 `NOT_ACTIONABLE` (2 × `ci.yml` protected path, 1 PR description), 0 individual `BLOCKED`; pytest / ruff / format `PASS` |
| Commit | `6bd20d0` by `claude[bot]`, single commit on `0fe30e6`, fast-forward pushed to the PR branch; files `README.md`, `src/demo_api/routes/tasks.py`, `tests/test_tasks.py` = union of the `FIXED` files |
| Reviewer #2 | `REQUEST_CHANGES` on **`6bd20d0`** (the pushed commit): BLOCKER `ci.yml`, MINOR PR description |
| Iterator #2 | `BLOCKED`, 0 `FIXED` (the remaining fix is a workflow file): no commit. Cycle result `BLOCKED`, run green |

Objective constraints were enforced by the workflow (the result is `produced_by: iterator`, so
none of these checks tripped): one commit for the `FIXED` items, no path matching
`CLAUDE.md`, `.claude/`, `.mcp.json` or `.github/workflows/`, no tracked change left
uncommitted, commit files equal to the `FIXED` files, fast-forward on the reviewed SHA.

> 💡 **Note**: **semantic subset safety = agent decision; objective safety constraints =
> workflow enforced.** Untracked files are not checked, but cannot leave the job: only the
> commit travels, as a git bundle.

**`yq`**: the hooks needing `yq` (`tests/*.sh`) run in FlowForge CI; they passed on the same
image (`ubuntu-24.04` `20261004.327.1`, run [37861228569](https://github.com/TiPunchLabs/flowforge/actions/runs/37861228569)),
which ships `yq` 4.54.1 (mikefarah v4). The Iterator job itself does not call `yq`.

## 4. ✅ #18 — `NO_OP` on a pull request no longer open

| Case | Run | Result |
|---|---|---|
| MERGED (PR #25) | [37965091309](https://github.com/TiPunchLabs/demo-api/actions/runs/37965091309) | `NO_OP` (`PR_ALREADY_MERGED`), run `success` |
| CLOSED, not merged (throwaway PR #26) | [37965267905](https://github.com/TiPunchLabs/demo-api/actions/runs/37965267905) | `NO_OP` (`PR_ALREADY_CLOSED`), run `success` |

In both runs: steps `Resolve pull request context` → `Record no-op` only; checkout, prompt and
**Claude Code skipped**, publish skipped (no comment), every Iterator and later Reviewer
skipped, `issue_state` skipped. `NO_OP` is neither `BLOCKED` nor `FAILED`.

Both cycles were dispatched after the merge / close: the state is read at run time by the
first check. The second check (`Re-check pull request state`, a close during checkout) was not
raced live.

## 5. ✅ #19 — Label lifecycle

| Step | Evidence |
|---|---|
| Before merge | Issue #24 `OPEN`, `agent:blocked` (set by the Developer stop; a FlowForge state the lifecycle accepts) |
| Merge | PR #25 merged by `xgueret` at 17:15:41Z → `1db2601` |
| Lifecycle | [37965007761](https://github.com/TiPunchLabs/demo-api/actions/runs/37965007761), `pull_request` `closed`, `success`: `Issue #24: FlowForge state agent:done (removed: agent:blocked).` |
| Linked Issue | resolved by GitHub (`closingIssuesReferences`, from `Closes #24`) after the merge |
| Final state (API) | Issue #24 `closed` (`completed`), labels `["agent:done"]` only |

Label timeline: `agent:ready` (xgueret) → `agent:running` → `agent:blocked` → closed by the
merge → `agent:done` (`github-actions[bot]`). `issue_state` correctly left the Issue alone after
the `BLOCKED` cycle (it only moves `agent:review`).

## 6. ✅ Human merge gate

| Check | Evidence |
|---|---|
| Ruleset | `flowforge-default-branch` (24757548), `enforcement: active`, `~DEFAULT_BRANCH`: `deletion`, `non_fast_forward`, `pull_request` (1 approval, stale reviews dismissed) |
| FlowForge `APPROVE` not enough | Reviewer `APPROVE` on `1e96d86` while GitHub showed `reviewDecision: REVIEW_REQUIRED`, `mergeStateStatus: BLOCKED`, 0 GitHub reviews; UI: "Merging is blocked" |
| Bypass | only the `admin` repository role, `bypass_mode: pull_request` (never a direct push); `github-actions[bot]` is not a bypass actor |
| `main` history | only `pr_merge` by `xgueret`; 0 `force_push` events; auto-merge disabled |

## 7. ⚠️ Reservations and limitations

- **No human approval observed.** PR #25 was authored by the maintainer (WIP fallback) and
  `demo-api` has a single writer: nobody could approve it, so the merge used the documented
  admin bypass (`admin_pull_request_bypass = true`). The gate was observed **holding**; the
  "approve, then merge without bypass" path was not.
- **Workflow approvals**: `can_approve_pull_request_reviews = true`. On an agent PR the bot is
  the author and cannot approve it; on a human-authored `agent/*` PR such as #25, a workflow
  token could. No FlowForge workflow submits reviews; not tested.
- **Developer → `PARTIAL` not observed on the same PR**: an Issue needing a workflow file makes
  the Developer stop without a PR, so PR #25 started as a declared WIP draft.
- **Bot-triggered `action_required` runs**: the Iterator push queued a `FlowForge review` run
  ([37938256844](https://github.com/TiPunchLabs/demo-api/actions/runs/37938256844)) that stayed
  unapproved and ended `failure` with 0 jobs at close. No second cycle ran.
- Manual cases kept out of scope: an Issue closed by hand without a PR, and Issues closed
  before the lifecycle existed, keep their last label.

## 8. 🔐 Security and concurrency

| Check | Result |
|---|---|
| Secrets | 26 job logs, 22.6k lines: no `sk-ant`, `ghp_`/`ghs_`/`gho_`/`github_pat_`; OAuth token always `***` |
| `write-all`, `secrets: inherit` | none |
| Agent push to `main`, force-push, auto-merge | none |
| Cycles per PR | at most 1 active; the Iterator push started no cycle |
| `max_iterations` | 3 (caller and `cycle.json`), unchanged |
| Tests on `main` `1db2601` | pytest 60 passed, `ruff check` and `ruff format --check` clean; new `CI` workflow green on PR #25 |

------

> **Document created on**: 2026-10-09
> **Author**: xgueret, with Claude Code
> **Version**: 1.0
