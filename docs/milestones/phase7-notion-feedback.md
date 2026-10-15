# 📥 Milestone — Phase 7: GitHub → Notion status feedback validated live

> **Date**: 2026-10-15 (UTC)
> **Status**: ✅ **Validated with reservations** (Prompt 34). A real Need (`NEED-7`) followed the
> real FlowForge chain on `demo-api` — Backlog → Refining → Backlog + *Needs clarification* (×2) →
> Ready → Developing → Review (+ PR #50) → Human validation → Done — and every state reached Notion
> through [`notion-sync.yml`](../../.github/workflows/notion-sync.yml), never by a manual edit. One
> live defect (rerun on `Done` not idempotent) was found, fixed by PR #53 and re-verified
> (`UNCHANGED`, `changed=[]`). A controlled Repository mismatch was `REFUSED` with Integration fields
> only. Reservations (§9): the **schedule**, the all-Needs mode, `Iteration`, `Closed` and the
> technical failure paths are **NOT VERIFIED LIVE**.
>
> **Prerequisites**: [feedback.md](../notion/feedback.md), [model.md](../notion/model.md) §12,
> [submission.md](../notion/submission.md), [phase7-notion-submission.md](phase7-notion-submission.md).

------

## 🧠 Mental Model

```text
 demo-api #49 (FlowForge)              Project card              Notion NEED-7 (notion-sync run)
 ────────────────────────              ────────────              ───────────────────────────────
 submit 38780226502 CREATED            (none)                    Backlog            38780341480 UNCHANGED
 refine 38780697153 started            Refining                  → Refining         38780743913 UPDATED
           └ NEEDS_CLARIFICATION       Backlog + Needs clar.     → Backlog + NC     38780889816 UPDATED
 refine 38782891532 started            Refining                  → Refining, NC ✗   38782938712 UPDATED
           └ NEEDS_CLARIFICATION       Backlog + Needs clar.     → Backlog + NC     38783119091 UPDATED
 refine 38786117887 started            Refining                  → Refining, NC ✗   38786165512 UPDATED
           └ READY                     Ready                     → Ready            38786324526 UPDATED
 human agent:ready → dev 38786799030   Developing                → Developing       38786844750 UPDATED
           └ Draft PR #50              Review                    → Review + PR #50  38787063806 UPDATED
 cycle 38787517033 APPROVE             Human validation          → Human validation 38787756628 UPDATED
 human approve + merge, lifecycle      Done                      → Done             38788818908 UPDATED
   38788690455                                                     rerun ✗ UPDATED  38788865541, 38788962515
                                       ── fix PR #53 (4eac3df) ──
                                                                   rerun UNCHANGED  38794178314, 38794226674
 NEED-8 → #47 but target mismatch-test-repo                       REFUSED          38794291809 (written)
                                                                   REFUSED          38794339980 (no write)
```

------

## 1. 🎯 Objective

Prove on real data that the GitHub / FlowForge state of a submitted Need is mirrored on the Need in
Notion — status, attention, pull request, completion — automatically, from a central workflow that
holds the only Notion credential, idempotently, and without letting one repository's event touch
another repository's Need.

------

## 2. 🧰 Setup

| Item | Value |
|---|---|
| FlowForge `main` | `dcad7e0` (PR #52, merged 2026-10-15 17:41:27 UTC) for §3–§5; `4eac3df` (PR #53, merged 19:27:03 UTC) for §6.3–§7 |
| Workflow | `.github/workflows/notion-sync.yml` "FlowForge — Notion sync", ID `385824526`, `workflow_dispatch` with `notion_page_id` |
| Notion Bridge App installation | `171187017`: `issues: write`, `metadata: read`, **`pull_requests: read`, `organization_projects: read`** (accepted 2026-10-15 12:23:14 −04:00), `events: []`, selected repositories |
| Validation Need | `NEED-7`, page `3fa6f28f-f5ca-8180-88aa-d5c65ea72e33`, Project *FlowForge POC*, Target repository *demo-api*, Priority Medium, created by the maintainer in the Notion UI |
| Mismatch Need | `NEED-8`, page `3fa6f28f-f5ca-81fe-b2cc-e9ad91f3947a`, Target repository *mismatch-test-repo* (`TiPunchLabs/mismatch-test-repo`, FlowForge enabled = false), `GitHub Issue` typed by hand = `demo-api` #47, Submit = false |
| Credentials | runtime `NOTION_TOKEN` and Bridge key from environment `notion-bridge` only; **no local Notion token** was used; no target repository received a Notion secret |
| Observation | Notion values are those **read by the sync itself** (log / summary `Previous status`, `pr=`, `completed=<read>`); pre-run values of `NEED-8` were read by the maintainer in the Notion UI |

------

## 3. 📤 Submission and Backlog

| Run | Result |
|---|---|
| `notion-submit.yml` `38780226502` (`dcad7e0`) | `CREATED`: `NEED-7` → `TiPunchLabs/demo-api#49`, author `app/flowforge-notion-bridge`, no label, marker of this page in the body |
| `notion-sync.yml` `38780341480` | `NEED-7` read `Backlog → Backlog`, **UNCHANGED**, no write: Notion shows `Backlog` (written by the submission); #49 has no Project card yet → status kept (feedback.md §5.1) |

This first sync was also the first live call of the reconciler to the Notion and GitHub APIs.

------

## 4. 🔄 Refinement (real Refiner, three passes)

| # | FlowForge | Card | Notion (sync) | Runs | Time (UTC) |
|---|---|---|---|---|---|
| 1 | Refiner started | `Refining` | `Backlog → Refining`, UPDATED, "SYNCED: FlowForge status updated to Refining." | refine `38780697153`, sync `38780743913` | card 17:50:57 |
| 2 | `NEEDS_CLARIFICATION` (the Need was a lifecycle probe, no repository change) | `Backlog` + `Needs clarification`, label `agent:needs-clarification` | `Refining → Backlog`, UPDATED, "…Backlog. Attention: Needs clarification." | sync `38780889816` | refined 17:51:24 |
| 3 | requester answer (GET /version) → Refiner | `Refining`, Attention cleared | `Backlog → Refining`, UPDATED, "…Refining. Attention cleared." | refine `38782891532`, sync `38782938712` | card 18:06:58 |
| 4 | `NEEDS_CLARIFICATION` (`/version` already exists; literal 1.0.0 ≠ package 0.1.0) | `Backlog` + `Needs clarification` | `Refining → Backlog`, UPDATED, "…Attention: Needs clarification." | sync `38783119091` | 18:08:02 |
| 5 | requester answer (modify `/version`, package metadata) → Refiner | `Refining`, Attention cleared | `Backlog → Refining`, UPDATED, "…Attention cleared." | refine `38786117887`, sync `38786165512` | card 18:30:17 |
| 6 | **`READY`**, labels removed | `Ready` | `Refining → Ready`, UPDATED, "SYNCED: FlowForge status updated to Ready." | sync `38786324526` | 18:31:11 |

Both clarification answers were written by the maintainer on the Issue (18:06:02, 18:29:16), not by
Claude. Backward moves and `Attention` set / cleared were mirrored each time.

**Correlation survives the Refiner.** The Refiner rewrites the title and body; the Bridge marker
now lives only inside the verbatim *Original request* block, and the Issue is still authored by the
Bridge, so check 8 (feedback.md §4) keeps passing (syncs 2–6).

------

## 5. 🛠️ Delivery, review, Human validation, Done

| # | FlowForge | Card | Notion (sync) | Runs | Time (UTC) |
|---|---|---|---|---|---|
| 7 | human `agent:ready` → Developer, label `agent:running` | `Developing` | `Ready → Developing`, UPDATED | developer `38786799030`, sync `38786844750` | card 18:35:09 |
| 8 | Draft PR **#50** (`app/tipunchlabs-flowforge`, branch `agent/49-feat-return-name-and-version-from-get-ve`), CI `38787012776` green, label `agent:review` | `Review` | `Developing → Review`, UPDATED, "…Review. **Pull request #50 linked.**" | sync `38787063806` | PR 18:36:20 |
| 9 | review cycle: Reviewer #1 **APPROVE** (commit `f94c555`), Iterator skipped, cycle `APPROVED` | `Human validation` | `Review → Human validation`, UPDATED, "**SYNCED: Need reached Human validation.**", `pr=…/pull/50` | cycle `38787517033`, sync `38787756628` | card 18:41:47 |
| 10 | human approval (`xgueret` 18:47:51) + merge (18:48:32, `0202234`); lifecycle: Issue closed *completed* 18:48:33, `agent:done` | `Done` | `Human validation → Done`, UPDATED, "**SYNCED: Need completed.**", `pr=…/pull/50` | lifecycle `38788690455`, sync `38788818908` | 18:49:43 |

- **Pull request**: `https://github.com/TiPunchLabs/demo-api/pull/50`, written at step 8 (rebuilt
  from `closedByPullRequestsReferences`, same repository), carried unchanged through steps 9, 10 and
  every rerun (§6).
- **Human validation** was recorded before the human merge and was not translated into `Done`.

------

## 6. 🔁 Idempotence — a live defect, fixed and re-verified

### 6.1 Defect

Reruns on `Done` (`38788865541`, `38788962515`, both on `dcad7e0`) returned **UPDATED**,
"SYNCED: Notion matches GitHub." instead of `UNCHANGED`: status and PR were equal, `Completed at`
was rewritten each time. Cause, confirmed by §6.3: Notion stores the date at **minute precision**
(`2026-10-15T18:48:00.000+00:00` for a merge at `18:48:32Z`) and the sync compared text. No
corruption (same value, `Last synced` moved forward), but not idempotent. The test stub had assumed
that Notion keeps seconds, so CI could not catch it.

### 6.2 Fix

PR **#53** (`9835c9c`, CI `38793542971` green, merged by `xgueret` 2026-10-15 19:27:03 UTC as
`4eac3df`): `Completed at` compared as a UTC instant at minute precision; summary and log report
`changed=[…]` and `completed=<read>-><written>`; 7 regression checks (they fail on the previous code).

### 6.3 Re-verification (on `4eac3df`)

| Run | Log |
|---|---|
| `38794178314` | `NEED-7 … Done -> Done pr=https://github.com/TiPunchLabs/demo-api/pull/50 result=UNCHANGED writeback=none changed=[] completed=2026-10-15T18:48:00.000+00:00->2026-10-15T18:48:00.000+00:00` |
| `38794226674` | identical |

- `FlowForge Status = Done`, `Pull request` = PR #50 and `Completed at` = merge time (minute
  precision) are read back from Notion by the sync and compared equal: no property written.
- `Integration status = OK` and `Last synced` were written by every `UPDATED` sync (step 10 last);
  the workflow does not print their values, and they were **not read back** by an automated check.

------

## 7. 🚫 Anti-corruption — controlled mismatch

`NEED-8` claims `demo-api` #47 while its Target repository is `TiPunchLabs/mismatch-test-repo`
(disabled). Pre-run values read by the maintainer in Notion: FlowForge Status `Draft`, Attention /
Pull request / Completed at empty, Integration status `Pending`.

| Run | Log |
|---|---|
| `38794291809` | `NEED-8 … issue=…/demo-api/issues/47 Draft -> Draft pr=- result=REFUSED writeback=OK changed=[] completed=-->-: REFUSED: GitHub Issue repository TiPunchLabs/demo-api does not match the Target repository (TiPunchLabs/mismatch-test-repo).` |
| `38794339980` | same, **`writeback=none`**: the refusal is already recorded and not rewritten |

- The REFUSED branch writes only `Integration status = Error` and `Integration message = REFUSED: …`
  (`changed=[]`: no lifecycle property); FlowForge Status was read `Draft` before and after.
- Refused **before any GitHub call** (checks 1–6): no token minted, #47 untouched (`updated_at`
  still 2026-10-14T16:55:31Z).
- The run stays green with a notice (REFUSED is functional, not technical).

------

## 8. 🔐 Security and secrets

| Check | Observed |
|---|---|
| `NOTION_TOKEN` location | environment `notion-bridge` of FlowForge only; never in `demo-api` (its callers unchanged, no Notion secret) |
| Claude and the Notion token | no agent runs in `notion-sync.yml`; agent jobs in `demo-api` have no Notion credential |
| Token scopes | Bridge token minted read-only (`issues`, `pull-requests`, `organization-projects`: read); FlowForge App unchanged |
| Destination | always the page given; repository from the Need's relation + allowlist; free Issue text never used (the Refiner-rewritten body did not change the destination) |
| Logs | Need ID, page ID, Issue URL, statuses, PR URL, dates, decision only; no token in logs or summaries |
| Local credentials | none used for Notion; both Needs were created by the maintainer in the Notion UI |

------

## 9. ⚠️ Reservations — NOT VERIFIED LIVE

| Item | Status | Covered by |
|---|---|---|
| **Schedule** (`*/10`): no `schedule` run fired between the merge (17:41 UTC) and closing (all 17 runs `workflow_dispatch`, workflow `active`) | **NOT VERIFIED LIVE** | trigger declared, workflow invariants tests |
| **All-Needs mode** (no `notion_page_id`: data source query, pagination) | **NOT VERIFIED LIVE** | tests |
| **`Iteration`** in Notion (Reviewer approved on the first review) | **NOT VERIFIED LIVE** | tests; Project-side Iteration observed in Phase 6 §17 |
| **`Closed`** (Issue closed as not planned / duplicate) | **NOT VERIFIED LIVE** | tests — see §10 |
| `Attention = Blocked / Max iterations / Failed` | **NOT VERIFIED LIVE** | tests |
| `FAILED` paths (Notion / GitHub down, write-back error, missing Bridge permission) | **NOT VERIFIED LIVE** | tests |
| Other refusals (author / marker mismatch, deleted Issue, disabled repository alone, not allowlisted) | **NOT VERIFIED LIVE** | tests (Repository mismatch refused live, §7) |
| `Integration status` / `Last synced` values on `NEED-7` / `NEED-8` | written, **not read back** | tests |
| A second target repository | **NOT VERIFIED LIVE** (only `demo-api`) | design (allowlist + Repositories row) |

------

## 10. 📌 Follow-ups

- **The first all-Needs run will move two Prompt 33 Needs.** `demo-api` #47 (`NEED-5`) and #48
  (`NEED-6`) are closed *as not planned* (2026-10-14 16:55 UTC) with no Project card: the first
  scheduled or all-Needs run will set both Needs to `Closed` (correct mirror, feedback.md §5.1;
  their Prompt 33 evidence stays in that milestone). It is also the natural live check of `Closed`
  and of the all-Needs mode. `NEED-8` will be `REFUSED` again without a write.
- Watch the schedule; if it still does not fire, look at the repository's Actions schedule
  (GitHub may delay or skip `schedule` runs) before relying on it.

------

## 11. ✅ Acceptance criteria (Prompt 34)

| # | Criterion | Evidence |
|---|---|---|
| 1 | Deterministic Need identification | page ID + Issue URL + Target repository + Bridge author + page marker (§3–§7) |
| 2 | Feedback centralised in FlowForge | `notion-sync.yml` only; `demo-api` unchanged |
| 3 | No target holds `NOTION_TOKEN` | §8 |
| 4 | FlowForge Status synchronised | §4, §5 (8 distinct transitions) |
| 5 | Pull request synchronised | §5 step 8 |
| 6 | Last synced updated | stamped by every write (§6.3); value not read back (§9) |
| 7 | Completed at at Done | §6.3 |
| 8 | Human validation visible | §5 step 9 |
| 9 | Sync errors ≠ FlowForge states | §7 (`Draft` kept, Integration `Error`) |
| 10 | Idempotent updates | §6.3, §7 second run |
| 11 | No cross-repository write | §7 |
| 12 | Free text cannot change the destination | §4 (rewritten body), §8, tests |
| 13 | No secret leak | §8 |
| 14 | Automated tests pass | `tests/notion-sync.sh` 101 checks, pre-commit, CI on PR #52 / #53 |
| 15–19 | Live path, PR, Human validation, Done, idempotent rerun | §4–§6 |
| 20 | Documentation | [feedback.md](../notion/feedback.md), [model.md](../notion/model.md) §12, this milestone |

------

> **Document created on**: 2026-10-15
> **Author**: FlowForge maintainers, with Claude Code
> **Version**: 1.0 — Phase 7, Prompt 34
