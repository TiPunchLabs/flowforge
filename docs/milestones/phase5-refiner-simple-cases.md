# 🧭 Milestone — Phase 5: Refiner validated on simple cases

> **Date**: 2026-10-10 (UTC)
> **Status**: ✅ Validated in isolation (Prompt 23): 7 real runs on `demo-api`, 6 scenarios, all
> `PASS`. No correction was needed. Two cosmetic reservations (§9). The Refiner → Developer chain is
> **not** covered here (Prompt 24).

------

## 🧠 Mental Model

```text
  raw need (Issue)            Refiner run (read-only)            published result
  ────────────────            ───────────────────────            ────────────────
  A  GET /ready         ─►   READY                ─►  body rewritten, no agent:* label
  B  "Améliorer les logs" ─► NEEDS_CLARIFICATION  ─►  agent:needs-clarification, 4 blocking Qs
  C  /tasks/search + 6 constraints ─► READY       ─►  6/6 constraints kept [provided]
  D  form-style, partial ─►  READY                ─►  2 criteria + 1 constraint kept, sections added
  F  GET /health (exists) ─► NEEDS_CLARIFICATION  ─►  duplicate detected from the repository
  E  re-run A and B     ─►   same verdict         ─►  1 comment (edited), Refinement 2 appended
                                                       STOP — no Developer, no branch, no PR
```

------

## 1. 🎯 Objective

Check the **functional quality** of the Refiner (`agent-refine.yml`, Prompt 22) on real runs:
`READY` vs `NEEDS_CLARIFICATION`, non-invention, constraint preservation, enrichment without loss,
use of the repository as context, labels, traceability, idempotence, and least privilege.
Boundary: `Need → Refiner → verdict → STOP`.

## 2. 🏗️ Environment

| Item | Value |
|---|---|
| FlowForge | `109e459d10ca688571e1285363b6277879fbc1dc` (`main`, `referenced_workflows` of every run, `rules_sha` of every record) |
| Target | `TiPunchLabs/demo-api`, `main` at `7a5be0d`, **unchanged** before/after |
| Caller | `demo-api/.github/workflows/flowforge-refine.yml` (`workflow_dispatch`, `@main`) |
| Trigger | `gh workflow run flowforge-refine.yml -R TiPunchLabs/demo-api -f issue_number=<n>` |
| Secret | `CLAUDE_CODE_OAUTH_TOKEN`, organization secret (`Secret source: Actions`) |
| Label convention | `READY` → **no** `agent:*` label (`agent:ready` is human-only); `NEEDS_CLARIFICATION` → `agent:needs-clarification`; `BLOCKED` → unchanged |

**Scenario adaptation.** `demo-api` already serves `GET /health` and `GET /version`, so the literal
Prompt 23 inputs for A and C are duplicates (contract §9.1 note). A uses `GET /ready`, and C uses
`GET /tasks/search` with the same kind of constraints. The literal `/health` request is kept as an
extra scenario F (duplicate detection). All test Issues are titled `[FlowForge validation P23-X]`.

## 3. 📊 Results

| Scenario | Issue | Run | Expected | Obtained | Verdict |
|---|---|---|---|---|---|
| A — clear need | [#28](https://github.com/TiPunchLabs/demo-api/issues/28) | [38075184055](https://github.com/TiPunchLabs/demo-api/actions/runs/38075184055) | READY | READY, no label | ✅ PASS |
| B — vague need | [#29](https://github.com/TiPunchLabs/demo-api/issues/29) | [38075275855](https://github.com/TiPunchLabs/demo-api/actions/runs/38075275855) | NEEDS_CLARIFICATION | NEEDS_CLARIFICATION, `agent:needs-clarification` | ✅ PASS |
| C — constraints | [#30](https://github.com/TiPunchLabs/demo-api/issues/30) | [38075283572](https://github.com/TiPunchLabs/demo-api/actions/runs/38075283572) | READY, constraints kept | READY, 6/6 `[provided]` | ✅ PASS |
| D — partial structure | [#31](https://github.com/TiPunchLabs/demo-api/issues/31) | [38075290524](https://github.com/TiPunchLabs/demo-api/actions/runs/38075290524) | READY or justified clarification | READY, nothing lost | ✅ PASS |
| E — idempotence (A) | [#28](https://github.com/TiPunchLabs/demo-api/issues/28) | [38075400135](https://github.com/TiPunchLabs/demo-api/actions/runs/38075400135) | Stable | Stable (cosmetic drift, §9) | ✅ PASS |
| E — idempotence (B) | [#29](https://github.com/TiPunchLabs/demo-api/issues/29) | [38075406790](https://github.com/TiPunchLabs/demo-api/actions/runs/38075406790) | Stable | Stable | ✅ PASS |
| F — duplicate | [#32](https://github.com/TiPunchLabs/demo-api/issues/32) | [38075296685](https://github.com/TiPunchLabs/demo-api/actions/runs/38075296685) | NEEDS_CLARIFICATION or BLOCKED | NEEDS_CLARIFICATION, 1 blocking Q | ✅ PASS |

All 7 runs: `refine` ✅, `publish` ✅, 3 to 5 agent turns, $0.11–0.18 each (~$0.94 in total).

## 4. 🔍 Scenarios

### 4.1 A — `GET /ready` → `READY`

Input: *Ajouter un endpoint GET /ready retournant HTTP 200 avec un JSON {"status":"ready"}.*

- Title `feat: add GET /ready readiness endpoint`. All sections are filled, and the 2 provided criteria (200, exact body) are kept as `[provided]`.
- **Non-invention**: authentication, caching, extra fields, real dependency checks and non-200
  states are placed **out of scope**, never in the criteria. "No dependency check requested" is
  tagged `[missing]` and resolved by an explicit `[assumption]` (unconditional 200).
- **Repository as context**: `health.py` / `test_health.py` are named as the pattern to follow `[observed]`. The README table and ruff/pytest commands come from `CLAUDE.md` `[observed]`. "No new dependency" is tagged `[observed]` (from `CLAUDE.md`), not `[provided]`.
- One non-blocking question (new module vs `health.py`), with a default. No useless question.

### 4.2 B — "Améliorer les logs." → `NEEDS_CLARIFICATION`

- The same 4 blocking questions as contract §9.2: problem to solve, events, format, user content in logs. Plus 1 non-blocking question (configurable level, default fixed `INFO`).
- Repository read: "no `logging` usage or `print` in `src/demo_api/`" `[observed]`, and no other logging Issue (`gh issue list`).
- Goal "Not determinable yet"; **no acceptance criterion** ("none yet: … without inventing the requirement"). The request was not turned into an assumed one.
- Labels: `agent:needs-clarification` only, no `agent:ready`. The comment lists the blocking questions.

### 4.3 C — `GET /tasks/search` with constraints → `READY`

Input constraints (verbatim): no new dependency; use the existing `TaskStore`; case-insensitive; `q` absent or empty → 422; add the tests; do not modify existing endpoints.

- **All 6 constraints** appear in *Constraints* as `[provided]`, with their meaning intact (no "should" or "avoid"). Three of them also appear in the criteria or out of scope.
- **Provided / observed / recommended kept apart**:
  - `[observed]` (`tasks.py`): "declare `/search` before `/{task_id}`, like `/stats`". This is a repository fact, not a requester demand.
  - `[recommended]`: "sorted by id, same `Task` shape as `GET /tasks`" and "no match → `[]`". These follow the neighbouring route, as rules §5.3 allows.
  - Whitespace-only and trimming of `q` are non-blocking questions with defaults. They are not decided silently.
- Reservation (minor): one criterion tagged `[provided]` lists specific test cases, which details "ajouter les tests associés" beyond its words. `[recommended]` would have been the exact tag.

### 4.4 D — partially structured Issue → `READY`

Input: form-style *Goal*, 2 *Acceptance criteria*, 1 constraint in *Technical notes*. No scope, out of scope or references.

- Goal preserved. **Both criteria kept** as `[provided]` (faithful translation). The constraint "do not change `DELETE /tasks?completed=true`" is kept as `[provided]` in Constraints, Out of scope **and** a criterion.
- Enrichment: scope, out of scope, 5 `[recommended]` criteria (empty store → `{"updated": 0}`, title and priority unchanged…), observed patterns (`DeletedCount`, `delete_completed`, route order).
- The original markdown is quoted verbatim in *Original request*. Nothing was replaced silently, and there is no massive duplication.
- `READY` is justified: no blocking ambiguity, one non-blocking question (response model name).

### 4.5 E — idempotence (re-run of A and B, Issues unchanged)

| Check | A (#28) | B (#29) |
|---|---|---|
| Verdict | READY → READY | NEEDS_CLARIFICATION → NEEDS_CLARIFICATION |
| Title | identical | identical |
| Labels | `[]` → `[]` | `agent:needs-clarification`, once |
| FlowForge comments | 1 → 1, same id `6100703048` (edited) | 1 → 1, same id `6100714741` (edited) |
| `##` sections / marker lines | 13 → 13 / 5 | 13 → 13 / 5 |
| *Original request* block | byte-identical | byte-identical |
| *Refinement record* | `Refinement 2` appended, entry 1 kept | `Refinement 2` appended, entry 1 kept |
| Content | same criteria, constraints, question, assumptions; wording varies; inline backticks dropped (§9) | 1 context line added ("no answers since previous refinement") |

### 4.6 F — literal `GET /health` → `NEEDS_CLARIFICATION` (duplicate)

The Refiner observed `health.py`, `test_health.py` and the README row. It invented no criterion and asked one blocking question: close as implemented, or what is missing? This is the behaviour of contract §9.1's note. It shows the Refiner checks the repository rather than rubber-stamping a clear request.

## 5. 🏷️ Labels

| Verdict | Expected (§6 of the contract) | Observed |
|---|---|---|
| READY (A, C, D, E-A) | no `agent:*` label | `[]` on #28, #30, #31 |
| NEEDS_CLARIFICATION (B, F, E-B) | `agent:needs-clarification`, never `agent:ready` | `["agent:needs-clarification"]` on #29, #32 |

The agent only **proposes** labels (*Proposed labels*); the workflow applies the state. No new label was introduced.

## 6. 🧾 Traceability

Each refined body holds the source (`Issue #n by @xgueret`), the UTC date, the role and rules SHA (`FlowForge Refiner, agents/refiner.md at 109e459…`), the workflow-run link, the verdict, what was added, the references used and the question counts. The FlowForge comment repeats verdict, date, SHA and run link. The first human version is kept verbatim between the `flowforge-original-request` markers, and GitHub keeps the edit history.

## 7. 🔐 Security and least privilege

| Check | Result |
|---|---|
| `GITHUB_TOKEN` of `refine` (Claude) | `Contents: read`, `Issues: read`, `PullRequests: read`, `Metadata: read` |
| `GITHUB_TOKEN` of `publish` | `Issues: write`, `Metadata: read`; no checkout, no Claude |
| Checkout | `persist-credentials: false` |
| Secret in logs (7 runs, both jobs) | 0 credential-like string; secret only as `***` |
| `##[error]` / `##[warning]` | 0 / 0. The "workspace changed" and "untracked files" checks did not fire: grep hits were only the script source echoed |
| Commits, pushes, PRs | none: `git push` / `git commit` / `gh pr create` absent from logs |
| Branches / PRs / `main` | unchanged (snapshot before and after: same branch list, same 18 PRs, `main` `7a5be0d`) |
| Writes | only the 5 test Issues (title/body/label) and 1 `github-actions[bot]` comment each |
| Developer | not triggered: no `agent:ready`, no `flowforge-agent.yml` run |

## 8. 🔧 Corrections

None. No defect blocked a scenario, and no FlowForge file was changed by this validation.

## 9. ⚠️ Reservations and limitations

**Observed deviations (cosmetic, not fixed):**

1. **Escaped quotes**: A pass 1 Goal rendered `{\"status\":\"ready\"}`. The model put the backslashes in the string; the renderer is not at fault. Pass 2 fixed it by itself.
2. **Inline code drift on re-run**: on A pass 2, most backticks disappeared. The artifact `refinement.json` shows the model returned them without backticks. Meaning is unchanged, but formatting is not stable across runs. A possible later rule: "keep inline code formatting".
3. **Tag precision**: C has one `[provided]` criterion more detailed than the request (§4.3).
4. **Cross-Issue awareness**: the Refiner lists open Issues and cited sibling test Issues (#28 ↔ #32). F also stated, as an `[assumption]`, that it is a validation Issue "per its title". This is harmless, but the test Issues are not blind.

**Not validated here (Prompt 24):**

- Refiner → Developer (human `agent:ready` on a refined Issue)
- Developer → Draft PR from a refined body
- Reviewer / Iterator reading a refined body (criteria `PASS`/`FAIL`)
- `BLOCKED` verdict live (prompt injection, CI/secrets request): covered only by `tests/refiner.sh`
- Re-refinement **with answers** in comments (B → READY)
- The technical-failure path (`FAILED`, rejected output, Issue edited mid-run) live

## 10. ✅ Acceptance criteria (Prompt 23)

| Criterion | Status |
|---|---|
| ≥ 4 distinct functional scenarios executed | PASS (A, B, C, D, F) |
| Clear scenario → `READY` | PASS (A) |
| Ambiguous scenario → `NEEDS_CLARIFICATION` | PASS (B) |
| Constraints all kept | PASS (C, 6/6) |
| Partial Issue enriched without loss | PASS (D) |
| Idempotence scenario executed | PASS (E ×2) |
| `READY` Issues have testable criteria | PASS |
| Ambiguous Issues have no `agent:ready` | PASS |
| No invented business requirement | PASS |
| Facts / assumptions / recommendations distinguished | PASS (one imprecise tag, §9.3) |
| Repository used as context | PASS (A, B, C, D, F) |
| Repository patterns not turned into requirements | PASS (tagged `[observed]` / `[recommended]`) |
| Original content traceable | PASS |
| Labels follow the conventions | PASS |
| No uncontrolled duplication on re-runs | PASS |
| No commit / push / PR | PASS |
| No secret exposed | PASS |
| Functional vs technical errors distinguished | PASS: all runs technically successful; `NEEDS_CLARIFICATION` is a business outcome of a green run. The failure path was not exercised live (§9) |
| Run evidence documented | PASS |
| Corrections limited to the strict minimum | PASS (none) |
| Developer not triggered | PASS |

------

> **Document created on**: 2026-10-10
> **Author**: xgueret, with Claude Code
> **Version**: 1.0
