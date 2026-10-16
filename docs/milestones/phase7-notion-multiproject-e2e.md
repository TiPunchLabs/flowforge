# 🧭 Milestone — Phase 7: Notion multi-contributor / multi-project E2E validated live

> **Date**: 2026-10-16 (UTC)
> **Status**: ✅ **Validated with reservations** (Prompt 35). Two Notion contributors, two Notion
> Projects and two real target repositories (`TiPunchLabs/demo-api`, `TiPunchLabs/demo-api-2`)
> ran side by side on FlowForge `main` `53f62c0`. Four Needs were submitted: a cross-project Need
> was `REFUSED` before any GitHub credential existed, three were `CREATED`, each in its own
> repository. Two of them (A1, B1) went through the real chain — Refiner `READY` → human
> `agent:ready` → Developer Draft PR → Reviewer `APPROVE` → human approval and merge → `Done` — and
> every state reached Notion through `notion-sync.yml`, never by a manual edit. The third (A2) stopped
> at `Ready` by design. A **scheduled** `notion-sync` run carried both Needs to `Done` (first live
> schedule evidence). Reruns and the all-Needs reconciliation were `UNCHANGED`, `changed=[]`.
> Reservations (§15): `Refining` in Notion, B1 `Developing` in Notion and the Iterator path are
> **NOT VERIFIED LIVE**.
>
> **Prerequisites**: [model.md](../notion/model.md), [submission.md](../notion/submission.md),
> [feedback.md](../notion/feedback.md), [phase7-notion-submission.md](phase7-notion-submission.md),
> [phase7-notion-feedback.md](phase7-notion-feedback.md), [target-onboarding.md](../target-onboarding.md).

------

## 🧠 Mental Model

```text
 Notion (2 contributors)                FlowForge (main 53f62c0)               Targets
 ───────────────────────                ────────────────────────               ───────
 Project FlowForge POC ── demo-api      notion-submit ──► Bridge token ──►     demo-api
   A1 NEED-14  (maintainer) ─────────► CREATED ─────────────────────────────► #51 → PR #53 → Done
   A2 NEED-12  (guest)      ─────────► CREATED ─────────────────────────────► #52 → Ready (stop)
   X1 NEED-11  (maintainer, → demo-api-2) REFUSED (Project ≠ Repository's)     nothing
 Project FlowForge POC B ── demo-api-2
   B1 NEED-13  (guest)      ─────────► CREATED ─────────────────────────────► demo-api-2
                                                                              #1 → PR #2 → Done
                                        notion-sync (dispatch + schedule)
 FlowForge Status / PR / Completed at ◄─ reads card + Issue + PR (read-only) ◄─ shared Project #1
```

`Requested by` (Notion person) ≠ GitHub execution identity (Apps, `github-actions`) ≠ agent
identity (`claude[bot]` commits) ≠ human reviewer / merger (`xgueret`).

------

## 1. 🎯 Objective

Prove live that Phase 7 holds with several contributors, several Notion Projects and several real
repositories: each Need is tracked independently, acts only on its own target repository, receives
its own statuses and PR, nothing leaks between projects or repositories, business and technical
roles stay separate, and the model stays deterministic and idempotent.

------

## 2. 🏗️ Architecture

Unchanged from Prompts 33–34; no FlowForge code change was needed (pre-Prompt 35 audit on
`a2c18f7`). The only FlowForge change is PR #55 (`53f62c0`): `TiPunchLabs/demo-api-2` added to
[`config/notion-allowlist.json`](../../config/notion-allowlist.json) and
[target-onboarding.md](../target-onboarding.md) §2 updated.

| Piece | Prompt 35 setting |
|---|---|
| Submission | `notion-submit.yml` (`workflow_dispatch`, `notion_page_id`), environment `notion-bridge` |
| Feedback | `notion-sync.yml` (`schedule` */10 + `workflow_dispatch`), central reconciler |
| GitHub Project | single shared organization Project #1 `FlowForge Development` ([config](../../config/github-project.json)) |
| Target credentials | organization level, *Selected repositories* = `demo-api`, `demo-api-2` (§14) |
| Routing | one target per Need; 1 target = 1 state; no external orchestrator |

------

## 3. 📁 Notion Projects

| Project | Notion page | Repositories |
|---|---|---|
| FlowForge POC | existing (Prompt 32) | `demo-api` |
| FlowForge POC B | `3fa6f28f-f5ca-8009-aec7-e239a5a298f5` (created by the maintainer for Prompt 35) | `demo-api-2` |

Duplicate records created during setup were deleted by the maintainer before any submission.

------

## 4. 📦 Repositories

| Repository | Notion record | Project | Allowlisted | Onboarding |
|---|---|---|---|---|
| `TiPunchLabs/demo-api` | existing (Prompt 32) | FlowForge POC | yes | reference target (Phases 2–7) |
| `TiPunchLabs/demo-api-2` | `3fa6f28f-f5ca-8057-8122-c05ea8fae4a0`, enabled | FlowForge POC B | yes (PR #55) | new for Prompt 35 (below) |

`demo-api-2` is a minimal FastAPI notes service (`GET /health`, `GET/POST /notes`,
`GET /notes/{id}`), same tooling as `demo-api` (uv, pytest, ruff, CI job "Tests, lint and format"),
the five `flowforge-*.yml` callers copied from `demo-api`; `main` `ab8c23a` before the E2E. It is
managed by its own Terraform state (`~/Workspace/02-infrastructure/demo-api-2`, local Git only,
temporary POC): repository, six `agent:*` labels, workflow permissions, ruleset
`flowforge-default-branch` (id `25203408`: PR + 1 approval, required check, admin PR bypass).

> 💡 **Note**: the `target-repository` module reads the repository through a data source and its
> ruleset forbids the initial push: a brand-new repository needs
> `terraform apply -target=github_repository.this`, the push of `main`, then the full apply
> ([target-onboarding.md](../target-onboarding.md) §2).

------

## 5. 👥 Contributors

| Role | Who | Evidence |
|---|---|---|
| Contributor A | the maintainer (Notion workspace member) | `Requested by` / `Created by` on A1, X1 |
| Contributor B | a Notion **guest** invited for Prompt 35 | `Requested by` / `Created by` on A2, B1; the guest could open Needs, create/edit, pick both Projects and both repositories |
| GitHub execution | `flowforge-notion-bridge[bot]` (Issues), `tipunchlabs-flowforge` App (PR delivery), `github-actions[bot]` (labels, comments) | Issue / PR authors (§7, §8) |
| Agent | `claude[bot]` (commit author of `ab8d800`, `946c694`) | commit metadata |
| Human reviewer / merger | `xgueret` | PR reviews and merges (§8) |

The guest's access and the `Requested by` / `Created by` values were verified by the maintainer in
the Notion UI (no local Notion read access during Prompt 35). No FlowForge script or workflow reads
`Requested by`, `Created by` or a Notion person property (only prose comments contain the words), so
a Notion contributor is never mapped to a GitHub identity: multi-contributor did not need a second
GitHub account.

------

## 6. 📝 Needs

All created by humans in the Notion UI.

| | Need | Page ID | Title | Requested by | Project | Target repository | Priority |
|---|---|---|---|---|---|---|---|
| A1 | `NEED-14` | `3fb6f28f-f5ca-80e1-9c76-cf33ec9fe4c1` | List overdue tasks | maintainer | FlowForge POC | `demo-api` | Medium |
| A2 | `NEED-12` | `3fb6f28f-f5ca-80f7-91fa-f69ca6f68232` | Support HEAD on the health check | guest | FlowForge POC | `demo-api` | Low |
| B1 | `NEED-13` | `3fb6f28f-f5ca-80dc-a012-dd27a615fd40` | Delete a note | guest | FlowForge POC B | `demo-api-2` | Medium |
| X1 | `NEED-11` | `3fb6f28f-f5ca-80b7-9c20-e99d6697602b` | Cross-project routing test | maintainer | FlowForge POC | `demo-api-2` ✗ | Low |

X1 is deliberately incoherent: its Target repository belongs to the other Project. Notion accepts
it; FlowForge must refuse it. No X2 was created: the check compares the Repository's Project with
the Need's Project, whichever side is wrong.

------

## 7. 🎫 Issues

Submissions (`notion-submit.yml`, FlowForge `53f62c0`). Baseline 2026-10-16T00:54:02Z: `demo-api`
last Issue #50, `main` `0202234`; `demo-api-2` no Issue, no run, `main` `ab8c23a`.

| Need | Run | Time (UTC) | Result | Issue |
|---|---|---|---|---|
| X1 | `38832128007` | 00:54:13 → 00:54:34 | `REFUSED` (§13) | none |
| A1 | `38832227068` | 00:55:15 → 00:55:36 | `CREATED` | `demo-api#51` (00:55:32) |
| A1 rerun | `38832283516` | 00:55:51 → 00:56:08 | `ALREADY_SUBMITTED`, token step skipped | still #51 |
| A2 | `38832341353` | 00:56:28 → 00:56:49 | `CREATED` | `demo-api#52` (00:56:44) |
| B1 | `38832394621` | 00:57:03 → 00:57:27 | `CREATED` | `demo-api-2#1` (00:57:22) |

Each Issue: author `flowforge-notion-bridge[bot]`, no label, no assignee, no Project card at
creation, exactly one `<!-- flowforge:notion-page-id=… -->` marker equal to its own Need's page ID
(still exactly one, unchanged, after the Refiner rewrite). Zero target workflow runs after the
submissions. Notion read back by the maintainer: A1 / A2 / B1 `Backlog`, Integration `OK`,
message `CREATED: Issue #N created in TiPunchLabs/<repo>.`; X1 see §13.

Refined titles: #51 `feat: add GET /tasks/overdue endpoint`, #52 `feat: support HEAD on GET /health`,
`demo-api-2#1` `feat: add DELETE /notes/{id} endpoint`.

------

## 8. 🔀 Pull requests

| Need | PR | Branch / head | Author | Closes | Files | CI |
|---|---|---|---|---|---|---|
| A1 | [`demo-api#53`](https://github.com/TiPunchLabs/demo-api/pull/53) Draft, 17:52:10 | `agent/51-feat-add-get-tasks-overdue-endpoint` @ `ab8d800` | `tipunchlabs-flowforge` App | `demo-api#51` only | README, `routes/tasks.py`, `tests/test_tasks.py` | `38942984711` success |
| B1 | [`demo-api-2#2`](https://github.com/TiPunchLabs/demo-api-2/pull/2) Draft, 17:52:12 | `agent/1-feat-add-delete-notes-id-endpoint` @ `946c694` | `tipunchlabs-flowforge` App | `demo-api-2#1` only | README, `routes/notes.py`, `storage.py`, `tests/test_notes.py` | `38942991368` success |

One commit each, authored by `claude[bot]`; CI ran without approval (App delivery); the automatic
`FlowForge review` runs on the PR events were `skipped` (bot actor, anti-loop rule 2).

| Need | Ready for review | Human approval | Merge (by `xgueret`) | Merge commit = new `main` |
|---|---|---|---|---|
| A1 | 18:46:40 | 18:47:04 `APPROVED` | 18:47:31 | `92716a0` (parents `0202234`, `ab8d800`) |
| B1 | 18:48:06 | 18:48:19 `APPROVED` | 18:48:40 | `a5eb53a` (parents `ab8c23a`, `946c694`) |

------

## 9. 🔢 Run IDs

| Need | Refiner | Developer | Review cycle | Human-activity review | Lifecycle |
|---|---|---|---|---|---|
| A1 | `38925677820` 15:39:13 → 15:40:31 | `38942794204` 17:50:42 → 17:52:21 | `38943177371` 17:53:45 → 17:55:04 | `38949934541` 18:46:43 → 18:47:39 | `38950042613` 18:47:34 |
| A2 | `38925692651` 15:39:20 → 15:40:43 | — | — | — | — |
| B1 | `38925707910` 15:39:26 → 15:40:45 | `38942830212` 17:51:00 → 17:52:25 | `38943188536` 17:53:50 → 17:55:18 | `38950112229` 18:48:08 → 18:49:02 | `38950186031` 18:48:43 |

All `success`. Refiner verdicts: all three `READY`, no label set (the Refiner never applies
`agent:ready`). B1 carried one **non-blocking** open question (non-integer id → FastAPI default
422), accepted as default when the human applied `agent:ready`. Review cycles: `APPROVE` at
Reviewer #1, Iterator #1–#3 skipped. The human-activity reviews were started by `ready_for_review`
(human actor) and re-published `APPROVE` on the same sticky comment.

`notion-sync` runs (all `success`, FlowForge `53f62c0`):

| Start (UTC) | Run | Mode | Need(s) | Result |
|---|---|---|---|---|
| 00:57:58 | `38832482224` | page | A1 | Backlog → Backlog `UNCHANGED` |
| 00:58:21 | `38832517425` | page | A2 | Backlog → Backlog `UNCHANGED` |
| 00:58:44 | `38832554189` | page | B1 | Backlog → Backlog `UNCHANGED` |
| 00:59:07 | `38832589688` | page | X1 | `REFUSED` (no Issue), no write |
| 15:40:40 | `38925873729` | page | B1 | Backlog → Ready `UPDATED` |
| 15:41:04 | `38925924833` | page | A2 | Backlog → Ready `UPDATED` |
| 15:42:32 | `38926120969` | page | A1 | Backlog → Ready `UPDATED` |
| 15:42:55 | `38926171243` | page | B1 | Ready → Ready `UNCHANGED` |
| 17:51:57 | `38942947330` | page | A1 | Ready → **Developing** `UPDATED` |
| 17:52:20 | `38942999563` | page | B1 | Ready → Review + PR #2 `UPDATED` |
| 17:53:17 | `38943117057` | page | A1 | Developing → Review + PR #53 `UPDATED` |
| 17:56:06 | `38943476990` | page | A1 | Review → Human validation `UPDATED` |
| 17:56:30 | `38943524132` | page | B1 | Review → Human validation `UPDATED` |
| 17:56:52 | `38943570501` | page | A1 | Human validation → Human validation `UNCHANGED` |
| 18:52:54 | `38950719805` | **schedule** | all | A1, B1 Human validation → **Done** + Completed at `UPDATED` (§12) |
| 18:55:23, 18:55:45 | `38951040741`, `38951086878` | page | A1 | Done → Done `UNCHANGED` ×2 |
| 18:56:09, 18:56:33 | `38951136439`, `38951188169` | page | B1 | Done → Done `UNCHANGED` ×2 |
| 18:57:36 | `38951318824` | all | all | §12 |

------

## 10. 🔁 Transitions

| Need | GitHub Project card | Notion `FlowForge Status` |
|---|---|---|
| A1 | (none) → Ready¹ → Developing → Review → Human validation → Done | Backlog → Ready → Developing → Review → Human validation → Done |
| A2 | (none) → Refining → Ready | Backlog → Ready |
| B1 | (none) → Refining → Ready → Developing → Review → Human validation → Done | Backlog → Ready → Review → Human validation → Done |
| X1 | none | none (never submitted) |

¹ A1's card was already `Ready` at the first observation (the Refiner finished in ≈ 80 s);
`Refining` was observed live on A2's and B1's cards (≈ 15:40:00). B1's card was observed
`Developing` at 17:51:50. `Attention` stayed empty on every card (no `NEEDS_CLARIFICATION`, no
failure); Notion `Attention` empty is inferred from the syncs, which only ever changed
`FlowForge Status`, `Pull request` and `Completed at`. No card, label or Notion value was changed
by hand; the only human GitHub actions were `agent:ready` (A1, B1), `ready_for_review`, approval
and merge.

Issue labels: `agent:running` (Developer) → `agent:review` (Draft PR, kept through Human validation)
→ `agent:done` (lifecycle after merge); both Issues closed by the merge (18:47:33, 18:48:41).

------

## 11. 🧱 Isolation

| Check | A1 (`demo-api`) | B1 (`demo-api-2`) |
|---|---|---|
| Target runs since baseline | 2 refine (#51, #52), 1 agent, 1 CI, 2 review (1 skipped), 1 review cycle, 1 lifecycle — all on #51/#53, or #52 | 1 refine, 1 agent, 1 CI, 2 review (1 skipped), 1 review cycle, 1 lifecycle — all on #1/#2 |
| `main` | `0202234` → `92716a0` (merge of #53 only) | `ab8c23a` → `a5eb53a` (merge of #2 only) |
| Remaining branches | `main` | `main` |
| PR closing reference | `demo-api#51` | `demo-api-2#1` |
| Notion `Pull request` | `demo-api#53` | `demo-api-2#2` |

- A2 stayed at `Ready`: no label, card `Ready`, no `agent/52-*` branch or PR, no Developer run.
- X1 left no trace: no Issue in either repository carries its page ID, no target run at submission.
- Every sync line names the Need's own Issue; no Need ever received another repository's PR.
- The shared GitHub Project holds one card per Issue; isolation relies on Issue-level correlation
  (Issue URL + Target repository, Bridge author + page marker), not on separate Projects.

------

## 12. ♻️ Idempotence

| Kind | Evidence |
|---|---|
| Submission | A1 rerun `ALREADY_SUBMITTED`, no second Issue, Bridge token step skipped |
| Sync rerun | `UNCHANGED`, `changed=[]` at Ready (B1), Human validation (A1), Done (A1 ×2, B1 ×2) |
| All-Needs (`38951318824`) | 7 Needs read, 0 written (below) |

| Need | Issue | Status | Result |
|---|---|---|---|
| A1 `NEED-14` | `demo-api#51` | Done (PR #53, Completed at 18:47) | `UNCHANGED` |
| A2 `NEED-12` | `demo-api#52` | Ready | `UNCHANGED` |
| B1 `NEED-13` | `demo-api-2#1` | Done (PR #2, Completed at 18:48) | `UNCHANGED` |
| `NEED-5` (Prompt 33) | `demo-api#47` | Closed | `UNCHANGED` |
| `NEED-6` (Prompt 33) | `demo-api#48` | Closed | `UNCHANGED` |
| `NEED-7` (Prompt 34) | `demo-api#49` | Done (PR #50) | `UNCHANGED` |
| `NEED-8` (Prompt 34 mismatch) | `demo-api#47` vs `mismatch-test-repo` | Draft | `REFUSED`, no write |
| X1 `NEED-11` | none | — | not selected: the all-Needs query only reads Needs with a `GitHub Issue` |

**Merge → Done and Completed at.** The scheduled run `38950719805` (18:52:54 → 18:53:18) wrote
`Human validation -> Done` with `changed=[Completed at, FlowForge Status]` on A1 (Completed at
`2026-10-16T18:47:31Z`, the merge instant) and B1 (`2026-10-16T18:48:40Z`); `Pull request`
unchanged, no other field changed. Notion stores minutes; the values read back as
`18:47:00.000+00:00` / `18:48:00.000+00:00` and are compared at minute precision
([feedback.md](../notion/feedback.md)). `Integration status = OK` on both is implied by every later
`UNCHANGED` (any other value forces a write). The same scheduled run left A2 and `NEED-5`–`NEED-7`
`UNCHANGED` and `NEED-8` `REFUSED`.

------

## 13. ⛔ Controlled refusals

| Need | Run | Exact message | Effect |
|---|---|---|---|
| X1 submit | `38832128007` | `REFUSED: The Target repository does not belong to the Need's Project.` | Bridge token and delivery steps skipped (no GitHub credential minted); Notion Integration `Error`, same message, `Submit` unticked, `GitHub Issue` empty (read back by the maintainer) |
| X1 sync | `38832589688` | `REFUSED: The Need has no GitHub Issue (not submitted): nothing to sync.` | no write |
| `NEED-8` sync | `38950719805`, `38951318824` | `REFUSED: GitHub Issue repository TiPunchLabs/demo-api does not match the Target repository (TiPunchLabs/mismatch-test-repo).` | no write (already recorded) |

------

## 14. 🔐 Security

| Check | Result |
|---|---|
| `NOTION_TOKEN` | only in FlowForge environment `notion-bridge` (with `NOTION_BRIDGE_PRIVATE_KEY`) |
| Target secrets | `demo-api`, `demo-api-2`: no repository secret, no environment; visible org secrets = `CLAUDE_CODE_OAUTH_TOKEN`, `FLOWFORGE_APP_PRIVATE_KEY` only; no target workflow mentions Notion |
| Bridge App `flowforge-notion-bridge` (installation 171187017) | `issues: write`, `pull_requests: read`, `organization_projects: read`, `metadata: read`; selected = `demo-api`, `demo-api-2`; unchanged |
| FlowForge App `tipunchlabs-flowforge` (installation 170384259) | `contents: write`, `pull_requests: write`, `organization_projects: write`, `metadata: read` (no `issues`); selected = `demo-api`, `demo-api-2` |
| Bridge token | minted per run for the Need's single target repository, revoked by the action's post step |
| Untrusted Notion text | rendered into the Issue body only; the destination comes from relations + allowlist; anti-corruption checks (marker, Bridge author, Target repository) active on every sync |
| Identities | `Requested by` never used technically (§5); agents never merged; the human approved and merged |
| Credentials migration | `FLOWFORGE_APP_*` moved to organization level; the temporary gh `admin:org` scope was removed |

------

## 15. ⚠️ Limits and NOT VERIFIED LIVE

| Item | Status |
|---|---|
| `Refining` in Notion | **NOT VERIFIED LIVE**: each Refiner finished in ≈ 80 s, before the first sync; seen on the Project cards only |
| B1 `Developing` in Notion | **NOT VERIFIED LIVE**: the PR existed before the sync (Ready → Review); seen on the card at 17:51:50. A1 `Developing` was verified in Notion |
| Iterator path (`Iteration`) | **NOT VERIFIED LIVE** in Prompt 35: both Reviewers approved first time (covered by Phase 6, Prompt 29.2 only) |
| `NEEDS_CLARIFICATION` across projects | not exercised (all `READY`; covered by Prompt 34 on `demo-api`) |
| A2 beyond `Ready` | intentionally not continued |
| Pagination | not validated (< 100 Needs) |
| Schedule cadence | schedule verified live (`38950719805`), but the observed scheduled runs were hours apart (01:25, 06:04, 11:14, 15:23, 18:52 UTC) despite `*/10`; cron unchanged |
| Post-merge review publish | A1's human-activity Reviewer started at 18:46:43 (PR open) and published `APPROVE` at 18:47:35, after the merge (18:47:31): the closed-PR `NO_OP` check runs at start only. Harmless here (no state change) |
| Notion read-back | Integration messages, `Requested by` and X1's `Submit` were read by the maintainer in the UI, not by an API call during Prompt 35 |
| Failure paths (`FAILED`, App not installed, Notion 5xx) | tests only |

------

## 16. 🎓 Verdict

**VALIDATED WITH RESERVATIONS.** None of the reservations is blocking.

| # | Criterion | Evidence |
|---|---|---|
| 1 | ≥ 2 Projects | §3 |
| 2 | ≥ 2 real repositories | §4 |
| 3 | ≥ 2 `Requested by` | §5 (maintainer, guest) |
| 4 | ≥ 3 Needs | §6 (4) |
| 5 | ≥ 1 cross refusal | §13 (X1) |
| 6 | ≥ 2 real lifecycles | §9–§10 (A1, B1) |
| 7 | ≥ 2 real PRs | §8 |
| 8 | Human validation on ≥ 2 | §9 (17:56 syncs) |
| 9 | Done after the human merge | §12 |
| 10 | Completed at correct | §12 (merge instants) |
| 11 | `UNCHANGED` idempotence | §12 |
| 12 | All-Needs, no cross-write | §11, §12 |
| 13 | No target gets `NOTION_TOKEN` | §14 |
| 14 | Bridge least privilege | §14 |
| 15 | `Requested by` never a technical identity | §5 |
| 16 | Anti-corruption active | §13 (`NEED-8`), §14 |
| 17 | No forced state, no auto-merge | §10 |
| 18 | GitHub / Project = technical source of truth | §10 |
| 19 | Schedule | verified live (§12) |
| 20 | Documentation | this milestone |

------

> **Document created on**: 2026-10-16
> **Author**: FlowForge maintainers, with Claude Code
> **Version**: 1.0 — Phase 7, Prompt 35
