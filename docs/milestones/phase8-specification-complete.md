# 🏁 Milestone — Phase 8: Specification complete

> **Status**: ✅ **PHASE 8 VALIDATED WITH RESERVATIONS**, none blocking (§5). The capabilities
> run live on two targets, with no target-specific code in FlowForge. Several paths are proven by
> offline tests only, and stay listed as reservations.
> **Scope**: Prompts 37 → 41. FlowForge `main` `eb90903` (PR #65) + this documentation PR;
> version `v0.1.0` = `afa60c599fa47643bba45e26dad0e836b0375b69`, published.
> **Audited on**: 2026-10-22, read-only: GitHub API, job logs, local files. No run was
> triggered, nothing was changed on `demo-api` or `demo-api-2`.

------

## 🧠 Mental Model

```text
  37   SPEC.md contract + Developer gate ─────────┐
  38   Refiner compares requests with SPEC.md ────┤
  38.1 Reviewer proves PASS, card after APPROVE ──┼──► one target-agnostic FlowForge, version v0.1.0
  39   onboarding reference, R1–R18 ──────────────┤          │
  39.1 versions: tag + full SHA ──────────────────┤          ├─► demo-api    (full chain, reference)
  39.2 evidence-based permission checks ──────────┤          └─► demo-api-2  (onboarding + Refiner replayed)
  40   second target, no FlowForge change ────────┤
  41   README + GETTING_STARTED ──────────────────┘
```

------

## 1. 🎯 Capabilities introduced

| Prompt | PR / commit | Capability | Reference |
|---|---|---|---|
| 37 (8.1) | #59 `bc18c23` | every target holds `SPEC.md` (four sections, at least one behaviour and one scenario). Step *Check SPEC contract* runs before the Developer starts: `PASS` / `FAILED` / `ERROR` | [spec-contract.md](../spec-contract.md) §1–§5 |
| 37.1 / 37.2 | target PRs (`demo-api` #56) | target preparation mission aligned with the contract: exact titles in the target's language, statuses `CONFIRMED` / `OBSERVED` / `KNOWN GAP`, scenario → test coverage | [preparation mission](../preparation-projet-existant-pour-flowforge.md), spec-contract §6 |
| 38 (8.2) | #60 `a994085` | Refiner `spec_impact` (`COMPLIANT` … `NO_SPEC`), cited `F/R/S` items, contract changes, Definition of Done; `READY` refused with `CONTRADICTS` / `NEEDS_DECISION`. Developer, Reviewer and Iterator rules read `SPEC.md` | spec-contract §7, [issue-contract.md](../issue-contract.md) §5 (R9) |
| 38.1 | #61 `3306d88` | Reviewer: no `PASS` without evidence; runs the gate's checker. Gate: one summary block. Stand-alone Reviewer `APPROVE` moves the card to `Human validation` | [phase8-spec-refinement.md](phase8-spec-refinement.md) §9 |
| 39 | #62 `afa60c5` | single onboarding reference: levels A / B / C, `import` adoption, readiness checks R1–R18 | [target-onboarding.md](../target-onboarding.md) |
| 39.1 | #63 `3eba913` | first version `v0.1.0`: module by Git tag, the five callers by the same full SHA | onboarding §10, [architecture §3.1](../architecture.md#31-versioning) |
| 39.2 | #64 `a3fdc72` | evidence levels `DIRECT` / `REPO-SIDE` / `DECLARED` / `FUNCTIONAL`, permission per check, owner-only checks A-1 / A-2 | onboarding §4 |
| 40 / 40.1 | #65 `eb90903` | second target onboarded with existing mechanisms only; Refiner replayed from `v0.1.0` | [phase8-second-target-onboarding.md](phase8-second-target-onboarding.md) |
| 41 | this PR | [README.md](../../README.md) as the entry point, [GETTING_STARTED.md](../../GETTING_STARTED.md) as the practical guide | — |

No new agent, label, dependency or Terraform resource was added in Phase 8: the module changed
in its README only (`git diff --stat flowforge-phase7-notion-e2e main`). Code changes are the
gate (`flowforge-spec.sh`, step in `agent-develop.yml`), the Refiner's result schema v2, the
Reviewer's checker and `project_status` job, and the Project-sync helper they share with the
review cycle.

------

## 2. 🧪 Live validations

### 2.1 `demo-api` (reference POC, full chain)

| Claim | Evidence | Date |
|---|---|---|
| Refiner classifies against `SPEC.md` | #57 `COMPLIANT` / `READY`, #58 `NEW_FEATURE` / `READY`, #59 `CONTRADICTS` → owner decision → `MODIFIES` / `READY` (feature branch) | 2026-10-20 |
| **Gate `PASS` in a real Developer run** | run `39356037326` (FlowForge `a994085`, contained in `v0.1.0`): log `SPEC CONTRACT PASSED — TiPunchLabs/demo-api, branch 'main'`, then `Ready → Developing → Review` | 2026-10-20 01:54Z |
| **Developer updates `SPEC.md` as the Issue authorises** | Draft PR #60, authored by `app/tipunchlabs-flowforge`: adds `F-012` and `S-020` exactly as refined in #58, plus code and tests | 2026-10-20 |
| **Reviewer runs the checker (38.1 A2)** | run `39452791058` (FlowForge `3306d88`): `bash …/flowforge-spec.sh SPEC.md` allowed and run; criterion `PASS` with evidence *"last line: 'SPEC contract: PASS'"* | 2026-10-20 15:55Z |
| **Card after a stand-alone `APPROVE` (38.1 A4)** | same run, log `Project sync TiPunchLabs/demo-api#58 [Reviewer APPROVE]: update — Status Review → Human validation` | 2026-10-20 15:56Z |
| Human merge, `agent:done`, `Done` | PR #60 merged by the owner 16:08Z; lifecycle `39454789555` `Human validation → Done` | 2026-10-20 |
| Onboarding R1–R18 | all `PASS` except R14 `NOT_VERIFIED`; callers pinned to `v0.1.0` (PR #62) | 2026-10-21 |

### 2.2 `demo-api-2` (reproducibility)

| Claim | Evidence | Date |
|---|---|---|
| Onboarding replayed with the reference only | R13 and R16 `FAIL` at first, fixed by target PRs #4 and #3; no FlowForge code change | 2026-10-21 / 22 |
| Pinned version served | callers at `afa60c5`; both Refiner results carry `rules_sha` `afa60c5` | 2026-10-22 |
| Phase 8.2 on another `SPEC.md` | #5 `READY` / `COMPLIANT`; #6 `NEEDS_CLARIFICATION` / `CONTRADICTS` on `R-004`, with no option chosen | 2026-10-22 |
| Project from a pinned version | `Refining → Ready`; `Refining → Backlog` + `Needs clarification` | 2026-10-22 |

Read again on 2026-10-22: the five callers of both targets point to
`afa60c599fa47643bba45e26dad0e836b0375b69 # v0.1.0`, and the two IaC states use
`?ref=v0.1.0`. On `demo-api-2`, the IaC change is on a branch, with its plan still pending (§5).

------

## 3. 📘 Documentation (Prompt 41)

| Document | Role | Checked |
|---|---|---|
| `README.md` | presentation: problem, cycle, roles, features validated live, limitations | links and anchors resolved by script |
| `GETTING_STARTED.md` | practical guide: steps 1–8 and troubleshooting, derived from the reference | Terraform example: `init -backend=false` + `validate` + `fmt -check` against the real `v0.1.0` module (also with the optional inputs enabled); commands compared with the reference and with the target configurations |
| `docs/target-onboarding.md` | detailed technical reference, unchanged in substance | header points to the guide |

A reader following the guide in order would have reproduced both onboardings. The two
difficulties met on `demo-api-2` are covered explicitly: a `SPEC.md` and callers that must be
merged before the first request (guide §2.2, §4.2), and section titles that must match exactly
(guide §2.1).

------

## 4. 📊 Exit criteria

| Criterion | Result |
|---|---|
| `SPEC.md` contract defined, gate in the Developer, tests | ✅ `tests/spec-contract.sh` |
| Gate observed live | ⚠️ `PASS` only (§2.1); `FAILED` / `ERROR` tests only (§5 R1) |
| Refiner compares with `SPEC.md`, never arbitrates | ✅ live on two targets |
| Developer / Reviewer use `SPEC.md` | ⚠️ the compliant path is live (§2.1); contradiction and finding paths are not (§5 R3, R4) |
| Onboarding reproducible without FlowForge adaptation | ✅ `demo-api-2` |
| Versioned consumption | ✅ `v0.1.0` published, both targets pinned |
| Permissions checked with evidence, no false `PASS` | ✅ R14 kept `NOT_VERIFIED` on both targets |
| Entry documentation for a new user | ✅ README + GETTING_STARTED (this PR) |

------

## 5. ⚠️ Reservations — still open

| # | Item | Status | How to close it |
|---|---|---|---|
| R1 | Gate `FAILED` / `ERROR` in a real Developer run | tests only (T2–T8) | the first target that legitimately lacks a valid `SPEC.md`; no run only to test |
| R2 | 38.1 gate summary block (`### SPEC contract: …`) in a real run | the only live Developer run predates PR #61 (old format) | next legitimate Developer run |
| R3 | Developer stops on a contradiction (developer §4.1) | not observed | when such a case happens |
| R4 | Reviewer contract findings (broken requirement, silent contract change) | only a compliant PR was reviewed | a review cycle on a PR that breaks `SPEC.md` |
| R5 | Iterator §6.1 (`SPEC.md` changed only to fix a finding) | not observed | same as R4 |
| R6 | Developer / Reviewer / Iterator / lifecycle served from the pinned `v0.1.0` SHA | only the Refiner ran from it (`demo-api-2`); the others ran from `@main` before pinning | next legitimate run on either target |
| R7 | R14, App installation repository list | `NOT_VERIFIED` on both targets | owner check A-2 (UI) |
| R8 | A-1, organization *Selected repositories* lists | not read (`REPO-SIDE` only) | owner check A-1 |
| R9 | `demo-api-2` Terraform plan after the source change | pending, expected *No changes*; IaC branch `chore/flowforge-v0.1.0` unmerged | maintainer `terraform plan`, then merge |
| R10 | Owner decisions | `demo-api` #57, #59 and `demo-api-2` #5 `READY`; `demo-api-2` #6 and Q-07 open | the owner applies `agent:ready`, answers or closes |

Observations, not defects:

- Scenario coverage lines in a target's `SPEC.md` go stale when a test-only Issue adds coverage
  (`demo-api-2` #5). The owner chooses whether to keep them.
- A contract change can be written as conditional by the Refiner. Prompt-level hint only.
- The caller templates in `examples/` keep `@main` as a placeholder, and every document says to
  replace it with a full SHA. Shipping the templates with the version's SHA would remove that
  step. Possible small improvement, out of scope for a documentation-only change.

------

## 6. 🔭 Possible next steps (not a roadmap)

- Close R2, R6 and then R1 / R3–R5 with the next **legitimate** requests on the targets; never
  with a run started only to test.
- Owner checks A-1 / A-2, the `demo-api-2` plan, and the owner decisions on the open Issues.
- A tag `flowforge-phase8-specification-e2e` on the merge commit of this PR, if the maintainer
  wants one (Phase 7 practice).

------

## 7. ✅ Decision

**PHASE 8 VALIDATED WITH RESERVATIONS.** The `SPEC.md` contract, SPEC-aware refinement,
versioned onboarding and the entry documentation are in place and were observed live where
§2 says so. Phase 8 is **not** fully validated: R1–R6 are untested live paths, and R7–R10 are
human actions. None of them blocks using FlowForge `v0.1.0` on a new target.

------

> **Document created on**: 2026-10-22
> **Author**: xgueret, with Claude Code (Phase 8, Prompt 41)
> **Version**: 1.0
