# 📐 Milestone — Phase 8.2: requests refined against `SPEC.md`

> **Date**: 2026-10-20 (UTC)
> **Status**: ✅ **Validated with reservations** (Prompt 38). The real Refiner workflow, run from
> FlowForge `8f78d8b` (branch `feat/phase8-spec-refinement`) on `demo-api`, read the target's
> `SPEC.md` and classified three requests as expected: compatible → `COMPLIANT` / `READY`, new
> feature → `NEW_FEATURE` / `READY` with the contract changes prepared, contradiction →
> `CONTRADICTS` / `NEEDS_CLARIFICATION` with an arbitration question. After an explicit requester
> decision, the contradiction was refined again to `MODIFIES` / `READY`. No Developer was started.
> Reservations (§7): the gate and the Developer / Reviewer rules are **NOT VERIFIED LIVE**.
>
> **Prerequisites**: [spec-contract.md](../spec-contract.md) §7, [refiner rules](../../agents/refiner.md) §5.4,
> [issue-contract.md](../issue-contract.md) §5 (R9).

------

## 🧠 Mental Model

```text
  raw Issue ─► agent-refine.yml (feature branch) ─► Claude reads SPEC.md ─► spec_impact
                                                                          │
   #57 filters combined   ── R-009 already says it ─────────► COMPLIANT      ─► READY
   #58 counts per priority ── nothing in SPEC.md ────────────► NEW_FEATURE   ─► READY + F-012 / S-020
   #59 title in the log   ── R-013 forbids it ──────────────► CONTRADICTS   ─► NEEDS_CLARIFICATION
          └─ requester: "change R-013" ─► re-run ───────────► MODIFIES      ─► READY + R-012/R-013/S-017/S-018 amendments
```

------

## 1. 🎯 Objective

Check that the Refiner consults `SPEC.md`, cites the concerned items, separates compatible
requests, contract extensions and contradictions, and never resolves an arbitration on its own
(Prompt 38, cases A, B, C), without starting any development.

## 2. 🧰 Setup

| Item | Value |
|---|---|
| FlowForge | `8f78d8b`, branch `feat/phase8-spec-refinement` (not merged) |
| Target | `TiPunchLabs/demo-api`, `main` = `dae5f2b`, `SPEC.md` from PR #56 (`F-001`…`F-011`, `R-001`…`R-015`, `S-001`…`S-019`) |
| Caller | temporary branch `test/flowforge-p38-refine` (`cbc99d2`): only `flowforge-refine.yml` changed, `@main` → `@feat/phase8-spec-refinement`; runs started with `gh workflow run --ref`; branch deleted after the runs |
| Trigger | `workflow_dispatch`, one run per Issue; Project sync on (org variable), as in production |
| Not done | no `agent:ready`, no Developer, no change to `demo-api` code or `main`, nothing on `demo-api-2` |

## 3. 📊 Results

| Case | Issue | Run | Verdict | `spec_impact` | Items cited | Contract changes | DoD | Label |
|---|---|---|---|---|---|---|---|---|
| A — compatible | [#57](https://github.com/TiPunchLabs/demo-api/issues/57) | [39351401205](https://github.com/TiPunchLabs/demo-api/actions/runs/39351401205) | `READY` | `COMPLIANT` | `R-009`, `F-005`, `S-008` | none | 4 items | none |
| B — new feature | [#58](https://github.com/TiPunchLabs/demo-api/issues/58) | [39351404304](https://github.com/TiPunchLabs/demo-api/actions/runs/39351404304) | `READY` | `NEW_FEATURE` | `F-009`, `R-001`, `R-012`, `R-015`, `S-015` | add `F-012`, `S-020` (+ a conditional section 1 note) | 5 items | none |
| C — contradiction | [#59](https://github.com/TiPunchLabs/demo-api/issues/59) | [39351407517](https://github.com/TiPunchLabs/demo-api/actions/runs/39351407517) | `NEEDS_CLARIFICATION` | `CONTRADICTS` | `R-013`, `R-012`, `S-018`, `S-017`, `F-011` | none | none | `agent:needs-clarification` |
| C — after decision | #59 | [39351588777](https://github.com/TiPunchLabs/demo-api/actions/runs/39351588777) | `READY` | `MODIFIES` | same | amend `R-013`, `R-012`, `S-018`, `S-017`, `F-011` | yes | none (removed) |

All runs succeeded (`refine` and `publish` jobs); every `refinement.json` is `schema_version: 2`
with `spec_present: true`.

### 3.1 Case A — compatible

Request: a test proving `completed` and `priority` filters work together. The Refiner observed that
`R-009` (`CONFIRMED`) already states it and that no test combines them: `COMPLIANT`, no contract
change, criteria in test form, `S-008` named as a scenario that must keep passing.

### 3.2 Case B — new feature

Request: "how many tasks there are for each priority". The Refiner found no feature covering it,
named `F-009` (counters) as the closest one and kept `GET /tasks/stats` out of scope. It prepared
`F-012` and `S-020` (`GIVEN … WHEN … THEN`) for the same PR, put the `SPEC.md` update in *Scope*
and the DoD, and left the path and the counting of completed tasks as **non-blocking** questions
with defaults.

### 3.3 Case C — contradiction, then decision

Request: log the title on task creation. The Refiner cited `R-013` (`CONFIRMED`: titles never in
logs) and `S-018`, classified `CONTRADICTS` and asked one blocking question offering both options
(keep `R-013`, or change `R-013` / `R-012` / `S-018`). It did not pick. The requester then answered
in a comment ("change R-013, creation record only"); the re-run tagged the decision `[provided]`,
classified `MODIFIES` and listed the amendments, including `S-017` and `F-011` that the decision
implies (`[recommended]`). The refinement record shows both passes: `CONTRADICTS` then `MODIFIES`.

## 4. 🔐 Guarantees observed

- `READY` was never returned with `CONTRADICTS` (case C, pass 1): enforced by
  `flowforge_refine_validate`, not only by the prompt.
- The original request was kept verbatim; the record gained one entry per run.
- `agent:ready` was never applied; no branch, PR or Developer run exists for #57–#59.
- The Issues were refined from the target's default branch only; FlowForge holds no `demo-api`
  specific text.

## 5. 🚦 SPEC.md gate (Prompt 37, unchanged)

The gate step is unchanged by this Prompt. Coverage: `tests/spec-contract.sh` T1–T9, run against
the real step script — `PASS` continues (T1, T7), absent `SPEC.md` `FAILED` (T2), missing section or
empty features / scenarios `FAILED` (T4–T6), unreadable repository, missing branch, HTTP 403 / 502
`ERROR` and never "absent" (T8), step placed after the Issue context and before any state change,
never skipped (T9). The gate is on `main` since PR #59, but **no real Developer run has gone
through it yet** (§7).

## 6. 🧪 Tests

`pre-commit run --all-files`: all hooks pass, including `tests/refiner.sh` (137 checks, of which
new: impact rules `SP`, *Specification* / *Definition of Done* rendering, record line, comment,
`CONTRADICTS` rendering, prompt and schema wiring) and every pre-existing workflow test (no
regression).

## 7. ⚠️ Reservations — NOT VERIFIED LIVE

| # | Item | Why | How to close it |
|---|---|---|---|
| R1 | Gate in a real Developer run (`PASS`, `FAILED`, `ERROR`) | A `PASS` starts a development; a `FAILED` needs a target without `SPEC.md`, and `demo-api-2` is reserved | First legitimate Developer run after the merge (`PASS`); `FAILED` / `ERROR` at the Phase 8 secondary validation |
| R2 | Developer §4.1 (updates `SPEC.md` in the same PR, stops on a contradiction) | No development was allowed in this Prompt | Apply `agent:ready` on #58 or #59 (both `READY`) after the merge |
| R3 | Reviewer §4.8 (contract findings) and Iterator §6.1 | Need a PR | Same run as R2 |
| R4 | Rules served from `main` | Runs used the feature branch through a temporary caller | Re-run one case after the merge |

## 8. 📌 Observations

- Case B: the endpoint path is an observable API choice that the Refiner left **non-blocking** with
  a default (`GET /tasks/stats/priority`), on the "one natural answer" rule (refiner §5.3). It is
  visible in the Issue and the human accepts it with `agent:ready`. To watch: if such choices
  surprise reviewers, make an undefined route path a blocking question.
- Case B: one contract change is conditional ("update section 1 only if needed"). A Developer can
  act on it, but contract changes should be definite. Prompt-level hint for later, not a defect.
- The three test Issues stay open on `demo-api` (#57, #58 `READY`; #59 `READY` after the decision).
  They can feed R1–R3, or be closed by a human.

------

## 9. 🔧 Prompt 38.1 — Reviewer evidence, SPEC gate summary, Project card after APPROVE

Reference run: `demo-api` [#58](https://github.com/TiPunchLabs/demo-api/issues/58) → Draft PR
[#60](https://github.com/TiPunchLabs/demo-api/pull/60) → stand-alone Reviewer
([39356503509](https://github.com/TiPunchLabs/demo-api/actions/runs/39356503509), `pull_request`
event) → `APPROVE`. Three non-blocking anomalies, fixed with the existing mechanisms only (no new
workflow, agent or dependency; `demo-api` / `demo-api-2` untouched).

| # | Observed on #58 / PR #60 | Cause | Fix |
|---|---|---|---|
| A2 | Criterion "`SPEC.md` … passes the contract check" marked `PASS` with "I did not run the contract gate itself, but the structure matches" | The Reviewer had no way to run the checker and no rule against inferring `PASS` | `agents/reviewer.md` §4.4 / §4.8 / §9: a named check is `PASS` only if run; the workflow fetches `flowforge-spec.sh` at its commit and allows exactly `bash <runner temp>/flowforge-review/flowforge-spec.sh SPEC.md`; `PASS` with empty evidence → result refused (`BLOCKED`) |
| A3 | Gate summary held one line, `- SPEC contract: **PASS**`, without repository nor ref; FAILED / ERROR copied the log block | Summary written ad hoc per result | One `### SPEC contract: PASS\|FAILED\|ERROR` block (repository, ref, file, result, reason) for every result; log, exit codes and fail-closed unchanged; `flowforge-spec.sh` also runs as a local script |
| A4 | Card of #58 still `Review` after `APPROVE` (checked read-only on 2026-10-19 with `sync-issue.sh --show`) | Only `review-cycle.yml` synced the Project; the stand-alone Reviewer was deliberately untouched | `agent-review.yml` job `project_status` (opt-in, `APPROVE` only, after the comment): event `review-approved`, `Review → Human validation`, via `flowforge_project_sync_pr` now shared with the cycle |

A posteriori, `SPEC.md` of PR #60's head passes the checker (`SPEC contract: PASS`, run locally):
the `PASS` was right but unproven, which is the defect A2 fixes.

**NOT VERIFIED LIVE.** No run was triggered for this Prompt (no Developer re-run, #58 untouched).
A4 needs the target caller `flowforge-review.yml` to pass `project_number`, `app_client_id` and
`app_private_key` ([example](../../examples/target-repository/flowforge-review.yml)): the
`demo-api` caller is not changed here, so its stand-alone reviews keep moving no card until it is
updated. The exact-match permission of the A2 command is documented Claude Code behaviour, not yet
observed in a run. Tests: `tests/review-evidence.sh` (new), `tests/spec-contract.sh`,
`tests/project-sync.sh`.

------

> **Document created on**: 2026-10-20
> **Author**: xgueret, with Claude Code
> **Version**: 1.1 (Prompt 38.1)
