# 🔁 Phase 8 — Second-target onboarding validation (`demo-api-2`)

> **Objective**: replay [docs/target-onboarding.md](../target-onboarding.md) on a second, already
> running target, with the existing mechanisms only, and record what is reproducible.
> **Scope**: Prompt 40. FlowForge `main` `a3fdc72` (PR #64), version `v0.1.0` = `afa60c5`.
> **Not done**: no `terraform apply`, no Developer run, no `agent:ready`, no merge by the agent, `demo-api` untouched.
> **Prompt 40.1**: the owner merged demo-api-2 PR #3 and #4 (2026-10-22 00:29Z / 00:30Z, `main` `3e7a1d3`); cases C and D run live (§5, §8).

------

## 🧠 Mental Model

```
 demo-api-2 before                         changes (one PR or commit each)            after
 ─────────────────                         ───────────────────────────────            ─────
 callers @main, Reviewer w/o Project ──►  demo-api-2 PR #4  (pin v0.1.0 SHA)  ──►  R13 PASS
 SPEC.md in PR #3, gate FAILED       ──►  demo-api-2 PR #3  (+1 commit)       ──►  R16 PASS
 module source = local path          ──►  IaC commit d7cb0fd (?ref=v0.1.0)    ──►  R6 PASS, plan pending
                      FlowForge: no workflow, script or module change (docs only)
```

------

## 1. 📋 Initial state (2026-10-21, read-only)

| Item | State |
|---|---|
| Repository | public, `main`, Issues on; 1 Issue (#1 `agent:done`), PR #2 merged (App-authored, 2026-10-16) |
| `SPEC.md` | only in open PR #3 (`docs/flowforge-spec`), written 2026-10-19 by the preparation mission before Prompt 37.2; gate: `Missing section '## 1. Objectif et périmètre'` → `SPEC contract: FAILED` |
| Callers | 5 + CI, all `@main`; `flowforge-review.yml` without the Project inputs (written before FlowForge PR #61) |
| IaC | `02-infrastructure/demo-api-2/github-terraform`, local Git repository (no remote), one state; module source = local path `../../../01-projets/flowforge/...` |

## 2. ✅ Readiness checks R1–R18

Commands of [target-onboarding.md §4.2](../target-onboarding.md), maintainer token (`repo`,
`read:org`, `project`, organization owner, no `admin:org`). "Initial" = before any change.

| Check | Initial | After | Evidence | Limitation |
|---|---|---|---|---|
| R1 | `PASS` | `PASS` | FlowForge `public` (`DIRECT`) | — |
| R2 | `PASS` | `PASS` | installation: contents / pull_requests / organization_projects `write`, metadata `read`, no `issues`, not suspended (`DIRECT`) | — |
| R3 | `PASS` | `PASS` | `bootstrap.sh --check`: *Project conforms to the model* (`DIRECT`) | — |
| R4 | `PASS` | `PASS` | `public`, `main`, `has_issues: true` (`DIRECT`) | — |
| R5 | `PASS` | `PASS` | `enabled: true`, `allowed_actions: all` (`DIRECT`) | — |
| R6 | `PASS` | `PASS` | one module block, in the target's IaC; its state holds 6 labels, ruleset, token settings; no module block nor state in the FlowForge root (`DIRECT`) | IaC repository has no remote |
| R7 | `PASS` | `PASS` | 6 `agent:*` labels (`DIRECT`) | — |
| R8 | `PASS` | `PASS` | `flowforge-default-branch` `active`, admin bypass `pull_request` (`DIRECT`) | — |
| R9 | `PASS` | `PASS` | `write`, `can_approve_pull_request_reviews: true` (`DIRECT`) | — |
| R10 | `PASS` | `PASS` | both secrets visible (`REPO-SIDE`), updated 2026-10-15 22:28Z / 22:33Z; validity `FUNCTIONAL`: run `38942830212` (2026-10-16) minted App tokens and delivered PR #2; Refiner runs `39702286050` / `39702289783` (2026-10-22) produced verdicts and Project updates | organization list not read (A-1) |
| R11 | `PASS` | `PASS` | both variables visible, client ID `MATCH`, Project number `MATCH` (`REPO-SIDE` + `DIRECT`) | organization list not read (A-1) |
| R12 | `PASS` | `PASS` | 0 repository secrets, 0 repository variables (`DIRECT`) | — |
| R13 | **`FAIL`** | `PASS` | initial: 5 callers `@main`. `main` `3e7a1d3` (PR #4): one full SHA (`v0.1.0`), interface check clean (§10.4), Reviewer Project inputs present, no `secrets: inherit` (`DIRECT`) | — |
| R14 | `NOT_VERIFIED` | `NOT_VERIFIED` | `FUNCTIONAL` only: PR #2 authored by `app/tipunchlabs-flowforge` (2026-10-16) | installation repository list (A-2) |
| R15 | `PASS` | `PASS` | required `Tests, lint and format` (15368) = CI job `name:` (`DIRECT`) | — |
| R16 | **`FAIL`** | `PASS` | initial: no `SPEC.md` on `main`. `main` `3e7a1d3`: `SPEC contract: PASS` (checker at `v0.1.0`); both Refiner runs saw it (`spec_present: true`) (`DIRECT`) | structure only |
| R17 | `PASS` | `PASS` | `CLAUDE.md` present (`DIRECT`) | content not judged |
| R18 | `NOT_VERIFIED` | `PASS` | review document present, `SPEC.md` merged by the owner (PR #3) | documentary; Q-07 stays open |

**Project chain, `FUNCTIONAL` (2026-10-16, Issue #1, FlowForge `@main` of that day).** Job-log
lines, all `update`: Developer `38942830212` `Ready → Developing → Review`; review cycle
`38943188536` `Review → Human validation`; lifecycle `38950186031` `Human validation → Done`.
`sync-issue.sh … 1 --show`: `Done`.

## 3. 📝 `SPEC.md` corrections (demo-api-2 PR #3, one commit)

No regeneration, no code or behaviour change, no new rule.

| Finding | Correction |
|---|---|
| Section 1 title `Purpose and scope` refused by the checker | `## 1. Objective and scope` |
| R-002 / S-005: `422` for whitespace-only text marked `CONFIRMED`, the owner decided "rejected" without a code | rejection `CONFIRMED`; status code open (Q-07), `422` kept as a proposal only |
| R-009 / S-014: "never lose a created note", beyond the owner decision (ids unique) | removed (storing a created note stays covered by F-002 / S-003) |
| F-003 did not cite R-008 although S-002 covers both | added |
| `Tested: partial / no` without the mission's scale | `Coverage: COVERED / PARTIAL / NOT_COVERED` with the test; full table in the review document (7 covered, 2 partial, 5 not covered) |

Owner decision still open: **Q-07** (status code of the whitespace-only rejection), not needed to
merge, needed when TD-01 is refined.

## 4. 🔧 Terraform

Source changed to `git::https://github.com/TiPunchLabs/flowforge.git//terraform/modules/target-repository?ref=v0.1.0`,
same module address `module.flowforge` (IaC commit `d7cb0fd`, branch `chore/flowforge-v0.1.0`).
`terraform fmt -check`, `init`, `validate`: OK. No change to the module's `.tf` files between the
last apply (2026-10-15) and `v0.1.0`: the expected plan is *No changes*.
`terraform plan`: to be run by the maintainer (credentials in `pass`), §7 action 1.

## 5. 🧪 Cases A–D

| Case | Result | Evidence |
|---|---|---|
| A — `SPEC.md` valid | `PASS` | `flowforge-spec.sh SPEC.md` on PR #3 head: `SPEC contract: PASS` |
| B — configuration | `PASS` (PR #4) | all `with:` / `secrets:` keys exist in the `v0.1.0` `workflow_call` interfaces, no required one missing, `actionlint` clean, same SHA ×5 |
| C — compatible request refined | `PASS` | Issue #5, run `39702286050`: `READY`, `COMPLIANT` (§8) |
| D — contradiction blocked | `PASS` | Issue #6, run `39702289783`: `NEEDS_CLARIFICATION`, `CONTRADICTS` on `R-004` (§8) |

## 6. ⚖️ Comparison with `demo-api`

| Step | `demo-api` | `demo-api-2` | Verdict |
|---|---|---|---|
| R1–R12, R15, R17 | `PASS` | `PASS` | identical |
| Callers | pinned in PR #62 | pinned in PR #4, byte-for-byte the same files | identical procedure |
| IaC | own state, Git source `v0.1.0` | own state, Git source `v0.1.0` | identical; local Git repository vs no Git: target choice |
| `SPEC.md` | reference POC (PR #56), passed first time | first preparation (pre-37.2) failed the exact-title check | normal: older mission version |
| Stack (`uv`, tools) | same Python / uv stack | same | — |

**Difficulties, all generic and documented, none needing a FlowForge code change:**

1. A `SPEC.md` written before the contract's exact titles fails the gate: caught by the local
   check of [§3](../target-onboarding.md); nothing to change.
2. A `SPEC.md` (or pinned callers) still in an open PR is invisible: the Refiner silently gives
   `NO_SPEC`. → §3 / §5 now state the merge order.
3. Callers copied before an interface gained **optional** inputs pass every tool. → §10.4 now
   says to diff against `examples/` and gives a key check.

No FlowForge-specific adaptation for `demo-api-2` was needed.

## 7. 📌 Remaining human actions

| # | Action | Closes |
|---|---|---|
| 1 | `terraform plan` in the IaC (expected *No changes*), then merge branch `chore/flowforge-v0.1.0` of the IaC repository | §4; state untouched (serial 15, 2026-10-15) |
| 2 | ~~Merge demo-api-2 PR #3 and #4~~ | done 2026-10-22 |
| 3 | ~~Create and refine the test Issues~~ | done (§8) |
| 4 | A-2 (installation repository list, UI) | R14 |
| 5 | Decide Issues #5 (`READY`: apply `agent:ready` or close) and #6 (answer or close); Q-07 when TD-01 is refined | owner decisions |

## 8. 🧪 Cases C and D, live (2026-10-22, Prompt 40.1)

Issues created from the drafts the owner approved. The Refiner was started with `gh workflow run
flowforge-refine.yml` on `main` `3e7a1d3` (caller pinned to `v0.1.0`; `rules_sha` in both results =
`afa60c5`). Both runs ended `success` (jobs *Refine Issue* and *Publish refinement on Issue*).
Both `refinement.json` files have `schema_version: 2` and `spec_present: true`.

| | C — compatible | D — contradiction |
|---|---|---|
| Issue | [#5](https://github.com/TiPunchLabs/demo-api-2/issues/5) "test: cover note list ordering and the 500-character limit" | [#6](https://github.com/TiPunchLabs/demo-api-2/issues/6) "feat: let clients choose the id of a new note" (client id, replace if it exists) |
| Run | [39702286050](https://github.com/TiPunchLabs/demo-api-2/actions/runs/39702286050) | [39702289783](https://github.com/TiPunchLabs/demo-api-2/actions/runs/39702289783) |
| Verdict / `spec_impact` | `READY` / `COMPLIANT` (expected) | `NEEDS_CLARIFICATION` / `CONTRADICTS` (expected) |
| `SPEC.md` items | `S-006`, `S-007` (both `NOT_COVERED`), `R-002`, `R-005`, `F-002`, `F-003` | `R-004` first (both halves: client-chosen id and overwrite), `R-003`, `F-002`, `S-013`, `S-012`, the section 1 "no update" limit |
| Context | 5 lines tagged `[provided]` / `[observed]`, with file sources | 6 lines; the unstated motivation is tagged `[missing]` |
| Acceptance criteria | 6 (GIVEN / WHEN / THEN for ordering and 500 characters, no `src/` change, no test weakened, checks pass) | none (not `READY`) |
| Definition of Done | 4 items | empty |
| `spec_changes` | empty (tests only) | empty |
| Questions | none | 5 blocking, plus 1 non-blocking with a default. The first is the arbitration *keep `R-004` (and drop this request), or change `R-004` and `S-013`*; no option is chosen |
| Label | none (`agent:ready` stays human) | `agent:needs-clarification`, by `github-actions[bot]` (publish job) |
| Project card (job-log lines, all `update`) | `(none) → Refining → Ready` | `(none) → Refining → Backlog`, Attention `Needs clarification` (model T4 / E4) |
| `sync-issue.sh --show` | `Ready`, no Attention | `Backlog`, `Needs clarification` |

No other run has started since (no Developer, no review): `gh run list` shows only these two
Refiner runs after 00:50Z. No agent took a functional decision: the questions on #6 name the
`SPEC.md` items and leave the choice to the owner.

**New live evidence.**
- The `Refining` status was observed on the GitHub Project. On the Notion side it stayed NOT
  VERIFIED LIVE in Phase 7.
- These are the first Refiner runs served from a pinned version (`v0.1.0`), not from `@main` or a
  feature branch.
- The Phase 8.2 behaviour was reproduced on a second target, with a different `SPEC.md`.

**Observation (not a FlowForge defect).** The `demo-api-2` `SPEC.md` carries per-scenario coverage
lines (`Coverage: NOT_COVERED`). Case C adds the tests for S-006 / S-007 and is correctly
`COMPLIANT`, with no `spec_changes`. The Developer changes `SPEC.md` only as the Issue authorises,
so it will not update those lines: they will be stale after the merge. The gate does not read
coverage ([spec-contract §5](../spec-contract.md)), and the mission keeps the authoritative table
in the review document. The target owner chooses: drop the coverage lines from `SPEC.md`, or ask
for their update in such Issues.

## 9. ✅ Verdict

**VALIDATED.** One human action is pending: the Terraform plan, expected *No changes*; no apply is
needed. R1–R18 have no `FAIL`. R14 stays `NOT_VERIFIED` until A-2, which §4.3 accepts. Cases A–D
`PASS`. `demo-api-2` needed no FlowForge-specific adaptation. The generic findings are in
[target-onboarding.md](../target-onboarding.md) v2.3.
