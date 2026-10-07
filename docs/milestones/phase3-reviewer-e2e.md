# 🏁 Milestone — Phase 3: Reviewer E2E

> **Tag**: `flowforge-phase3-reviewer-e2e` (annotated, on FlowForge and `demo-api`)
> **Date**: 2026-10-06 (UTC runs on 2026-10-06/07)
> **Status**: ✅ Validated — Developer and Reviewer run end to end on `demo-api`; no auto-merge.

------

## 🧠 Mental Model

```text
demo-api Issue #5 ──agent:ready──► FlowForge agent-develop.yml ──► Draft PR #7 (bot)
                                                                       │
                                     human: workflow_dispatch /        │
                                     ready_for_review                  ▼
                                   FlowForge agent-review.yml ──► comment "Verdict: APPROVE"
                                                                       │  (one comment,
                                                                       ▼   updated in place)
                                                              human merge → demo-api b76dbbb
```

------

## 1. 🎯 Objective of Phase 3

Add a second, specialized agent — the **Reviewer** — between the Developer's Draft PR and the
human review. It analyzes the PR against its linked Issue and the target's conventions, and
publishes a structured verdict (`APPROVE` / `REQUEST_CHANGES` / `BLOCKED`) without ever
modifying the code or the PR state.

## 2. 📦 Delivered

| Item | Where | FlowForge PR |
|---|---|---|
| Reviewer specification (read-only, verdict rules, finding severities) | `agents/reviewer.md` | #6 |
| Reusable Reviewer workflow (`workflow_call`) | `.github/workflows/agent-review.yml` | #7 |
| Target caller template | `examples/target-repository/flowforge-review.yml` | #7, #8, #9 |
| Fix: `workflow_dispatch` PR number passed as a number (`fromJSON`) | caller template | #8 |
| Fix: skip `pull_request` runs whose actor is `github-actions[bot]` | caller template | #9 |
| Architecture and decisions (§2.3, §4, §5.1, §5.2) | `docs/architecture.md` | #6–#9 |

Not delivered (out of scope): Iterator agent, Reviewer ↔ Iterator loop, Refiner, GitHub
Project, Notion.

## 3. 🏗️ Architecture Developer → Reviewer

```text
target repo (demo-api)                       FlowForge (central, @main)
──────────────────────                       ──────────────────────────
flowforge-agent.yml  ── workflow_call ──►    agent-develop.yml + agents/developer.md
   (issues: labeled agent:ready)               → branch agent/<issue>-<slug>, commits, Draft PR

flowforge-review.yml ── workflow_call ──►    agent-review.yml + agents/reviewer.md
   (workflow_dispatch | pull_request)          job review  (read-only)  → review.json artifact
                                               job publish (PR comment) → <!-- flowforge-review -->
```

The two agents share nothing at runtime: separate workflows, separate rule files, separate
permissions. The Reviewer's only input is `pull_request_number`; base, head SHA, linked Issue
(`closingIssuesReferences`) and CI snapshot are resolved by the workflow.

## 4. 🔐 Triggers and GitHub permissions

| Workflow | Trigger (target caller) | Job permissions |
|---|---|---|
| Developer | `issues: labeled` with `agent:ready` | `contents: write`, `issues: write`, `pull-requests: write` |
| Reviewer — `review` job | `workflow_dispatch` (`pull_request_number`), or `pull_request` (`opened`, `reopened`, `synchronize`, `ready_for_review`) on same-repo `agent/*` branches, actor ≠ `github-actions[bot]` | `contents`, `issues`, `pull-requests`, `checks`, `statuses`: **read** |
| Reviewer — `publish` job | (same run) | `pull-requests: write` only — no checkout, no agent |

Both reusable workflows declare `permissions: {}` at workflow level; secrets are passed
explicitly (`claude_code_oauth_token`), never `secrets: inherit`.

## 5. 🤖 Role of Claude Code in the runners

- Runs through `anthropics/claude-code-action` (pinned SHA) in automation mode, authenticated
  by `CLAUDE_CODE_OAUTH_TOKEN`.
- Agent rules (`agents/*.md`) are fetched from FlowForge at `job.workflow_sha` and embedded in
  the prompt; the target's `CLAUDE.md` adds project conventions.
- **Developer**: commits and pushes only its own `agent/*` branch, opens a **Draft** PR.
- **Reviewer**: `Read`/`Glob`/`Grep`, read-only `git`, and the target's non-destructive checks
  (`allowed_tools`); `Edit`/`Write`/`MultiEdit`/`NotebookEdit` disallowed;
  `persist-credentials: false`; agent configuration files reset to the base branch. Output is
  a JSON-schema-constrained result, validated by `jq` and rendered by the workflow.

## 6. ✅ Validated E2E scenarios and evidence

### 6.1 Developer (Phase 2, regression baseline)

| Step | Evidence |
|---|---|
| Issue #3 → Developer run | [run 37516204602](https://github.com/TiPunchLabs/demo-api/actions/runs/37516204602) — success, FlowForge `ce216b8` |
| Draft PR → human merge | [demo-api PR #4](https://github.com/TiPunchLabs/demo-api/pull/4), merged by `xgueret` → `d67bf71` |

### 6.2 Developer → Reviewer (Phase 3)

| Step | Evidence |
|---|---|
| Issue #5 labeled `agent:ready` by a human (23:49:34Z) | [demo-api issue #5](https://github.com/TiPunchLabs/demo-api/issues/5) |
| Developer run | [run 37548666121](https://github.com/TiPunchLabs/demo-api/actions/runs/37548666121) — success, FlowForge `e5fb615` |
| Draft PR opened by `github-actions[bot]` | [demo-api PR #7](https://github.com/TiPunchLabs/demo-api/pull/7), head `4b439f9` |
| Reviewer via `workflow_dispatch` (after fix #8) | [run 37549027133](https://github.com/TiPunchLabs/demo-api/actions/runs/37549027133), [run 37549262700](https://github.com/TiPunchLabs/demo-api/actions/runs/37549262700), [run 37553614196](https://github.com/TiPunchLabs/demo-api/actions/runs/37553614196) — success, `APPROVE` |
| Reviewer via `pull_request` (`ready_for_review` by a human) | [run 37553989390](https://github.com/TiPunchLabs/demo-api/actions/runs/37553989390) — success, `APPROVE`, FlowForge `2ca4e57` |
| Result published | [single comment](https://github.com/TiPunchLabs/demo-api/pull/7#issuecomment-6027706902): created 23:54:54Z, updated in place 00:50:49Z, 6/6 acceptance criteria PASS, no finding |
| No auto-merge | PR #7 has no GitHub review from the bot; merged by `xgueret` at 00:51:44Z → `b76dbbb` |
| No secret in logs | The 5 run logs above (Developer + Reviewer) contain no `sk-ant`, `ghp_`/`ghs_`/`gho_`/`github_pat_` value; secrets appear only masked (`***`) |

Failed runs on the way, both fixed before the final validation:

- [run 37548750154](https://github.com/TiPunchLabs/demo-api/actions/runs/37548750154) — `pull_request` started by `github-actions[bot]`: `claude-code-action` refuses bot actors → FlowForge #9 / demo-api #9 skip those runs.
- [run 37548841491](https://github.com/TiPunchLabs/demo-api/actions/runs/37548841491) — `workflow_dispatch` number arriving as a string → FlowForge #8 / demo-api #8 (`fromJSON`).

The reusable workflows and agent rules are functionally identical between `e5fb615`
(Developer run) and `2ca4e57` (final Reviewer run): the only diff in executed files is the
status line of `agents/reviewer.md`.

## 7. ⚠️ Limitations and known risks

- **One scenario only**: a single `APPROVE` on a small refactor. `REQUEST_CHANGES` and
  `BLOCKED` paths are specified and enforced by the workflow but not observed live.
- **Bot-opened PRs are not reviewed automatically**: the `pull_request` run for a PR opened
  with `GITHUB_TOKEN` is skipped; review needs a human (`workflow_dispatch` or
  `ready_for_review`). A GitHub App identity would remove this.
- **Bot-actor skip not yet exercised live**: since #9, no new bot-opened `agent/*` PR was
  created; the earlier skipped runs were filtered by branch name, not by actor.
- **Targets track `@main`**: callers are not pinned to a tag or SHA yet (architecture §3.1).
- **Reviewer quality is non-deterministic**: the verdict depends on the model; consistency
  rules (no `APPROVE` with `BLOCKER`/`MAJOR`) are enforced, correctness is not guaranteed.
- **Default-branch ruleset** requiring a human approval is still planned in the Terraform
  module, not applied.

## 8. 🧭 Architectural decisions retained

See `docs/architecture.md` §5.1. In short: PR number as the only contract input; Issue resolved
from closing references, never guessed; Reviewer rules delivered at `job.workflow_sha`; base
branch `CLAUDE.md` enforced; structured output validated by the workflow; publication as one
PR **comment** (not a GitHub review) updated in place; any invalid output becomes `BLOCKED`
and fails the run; review and publish split into two jobs with separate permissions.

## 9. 🔖 Exact Git references

| Repository | Validated commit | Why this commit | Tag |
|---|---|---|---|
| `TiPunchLabs/flowforge` | `2ca4e571dd0d3c98fa09a1d15b6da91c36d8894e` | `main` HEAD executed by the final Reviewer run (`referenced_workflows` of run 37553989390) | `flowforge-phase3-reviewer-e2e` → this commit |
| `TiPunchLabs/demo-api` | `b76dbbbf962af036278e220159576cc724fdbe43` | Human merge of reviewed PR #7: parents `3bcba3d` (caller workflows used by the run) and `4b439f9` (reviewed head) | `flowforge-phase3-reviewer-e2e` → this commit |

> 💡 **Note**: the FlowForge tag points to the **validated** commit, not to the later commit
> adding this document. The tag then designates exactly the code the runners executed, and
> this document records it without a self-referencing SHA. Previous milestone:
> `flowforge-phase2-e2e` (FlowForge `09dccbc`, demo-api `d67bf71`), left unchanged.

## 10. 🚀 Next: toward multi-agent orchestration

1. **Iterator agent**: consumes `review.json` findings and pushes fixes on the same `agent/*` branch.
2. **Bounded Reviewer ↔ Iterator loop**: iteration limit, stop conditions, human escalation.
3. **Pin targets** to a FlowForge tag or SHA instead of `@main`.
4. **GitHub App identity** so agent-opened PRs trigger CI and reviews without human approval.
5. Later: Refiner agent, GitHub Project, Notion.

------

> **Document created on**: 2026-10-06
> **Author**: xgueret, with Claude Code
> **Version**: 1.0
