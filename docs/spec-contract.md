# 📜 FlowForge — SPEC.md contract

> **Status**: Phase 8.1 (gate) and 8.2 (use by the agents, §7). Every target repository holds a
> `SPEC.md` at its root: the functional reference of the project. Before the Developer starts,
> `agent-develop.yml` checks that it exists and has the minimal structure below. The check is
> **structural only**: whether the specification is right, complete and consistent stays a human
> responsibility.
> Implementation: `.github/scripts/flowforge-spec.sh`, step *Check SPEC contract*; tests:
> `tests/spec-contract.sh`.

------

## 🧠 Mental Model

```text
  human applies agent:ready
        │
        ▼
  agent-develop.yml ── Resolve issue context ── Check SPEC contract ──┬── PASS ──► Mark running ─► Claude ─► Draft PR
                                                 (SPEC.md of THIS     │
                                                  repository, on the  ├── FAILED (absent / empty / incomplete)
                                                  base branch)        │      └► run fails, nothing changed, Issue keeps agent:ready
                                                                      └── ERROR  (API / rights / branch)
                                                                             └► run fails, nothing changed — NOT "absent"
```

| The check proves | The check does not prove |
|---|---|
| `SPEC.md` exists on the base branch | that it describes the product correctly |
| it holds the four sections | that the requirements are consistent or complete |
| at least one behaviour and one scenario are written | that the Issue being developed agrees with it (the agents' job since Phase 8.2, §7) |

------

## 1. 📖 Why `SPEC.md` is mandatory

An Issue describes one change; nothing in it says what the product *is*. Without a project
reference, an agent can only judge a change against the Issue and the code, and a change that
contradicts the product goes unnoticed until a human reads the PR.

`SPEC.md` is that reference, one per target, versioned with the code it describes:

- **humans** write and validate it when the project is prepared, and change it by pull request
  like any other file;
- **agents** get a stable, citable source: features, rules and scenarios with identifiers
  (`F-001`, `R-001`, `S-001`) an Issue, a review finding or a PR body can point to;
- **FlowForge** refuses to start an autonomous development on a project that has none.

Phase 8.1 guarantees the file is there and shaped as below. Phase 8.2 makes the agents use it
(§7).

------

## 2. 🧱 Minimal structure

`SPEC.md` at the **root** of the repository (exact name, upper case), in Markdown, with four
**level-2** sections:

```markdown
# Project Specification

## 1. Objectif et périmètre

What the product is for, who uses it, what it does not do.

## 2. Fonctionnalités

### F-001 — Health check

`GET /health` answers `200` with `{"status": "ok"}`.

## 3. Règles et contraintes

### R-001 — Stateless

The service keeps no state between two requests.

## 4. Scénarios de validation

### S-001 — Service is up

GIVEN the service is started
WHEN a client calls `GET /health`
THEN the answer is `200`
```

### 2.1 Section titles

| Section | Accepted titles |
|---|---|
| 1 | `Objectif et périmètre`, `Objective and scope` |
| 2 | `Fonctionnalités`, `Features` |
| 3 | `Règles et contraintes`, `Rules and constraints` |
| 4 | `Scénarios de validation`, `Validation scenarios` |

Tolerated: case, accents (`Regles` = `Règles`), a leading number (`1.`, `2)`, `3 -`), an emoji,
extra spaces, closing `##`. The order of the sections is not checked. Other sections may be
added freely.

Use these titles **exactly**, in the language of the target repository (the language of its
`README.md` / `CLAUDE.md`): an English-speaking repository writes `## 1. Objective and scope`,
`## 2. Features`, `## 3. Rules and constraints`, `## 4. Validation scenarios`. Any other wording,
even a faithful translation (`Purpose and scope`), is not recognised and fails check 3. The rest
of the file (labels, text) follows the repository's language too.

### 2.2 Stable references: `F-xxx`, `R-xxx`, `S-xxx`

Recommended, **not checked**: one level-3 heading per item, `### F-001 — <name>` for a
feature, `R-001` for a rule, `S-001` for a scenario, then its description. Identifiers are
never reused or renumbered: a removed item keeps its number retired. Scenarios are best written
`GIVEN` / `WHEN` / `THEN`, possibly in a fenced code block; the form is free.

### 2.3 Requirement status: `CONFIRMED`, `OBSERVED`, `KNOWN GAP`

Recommended, **not checked**. Each `F-xxx` and `R-xxx` states its status in backticks, on a
`**Status:**` line or at the end of the statement; a statement inside it with another status
carries its own tag.

| Status | Meaning | For an agent |
|---|---|---|
| `CONFIRMED` | documented (README, `CLAUDE.md`, an accepted Issue) or explicitly decided by the owner | a requirement: a change must preserve it |
| `OBSERVED` | current behaviour seen in the code or the tests, never validated as a requirement | not a requirement: changing it does not contradict `SPEC.md`, but the PR says so |
| `KNOWN GAP` | the expected contract and the implementation or the tests disagree | the contract wins; the gap is tracked (Issue, review document) |

An observed behaviour never becomes `CONFIRMED` on its own: only a source or an owner decision
promotes it. A value nobody decided (an HTTP code, a threshold, a message) is never `CONFIRMED`.
Open questions and contradictions are not statuses: they stay in the review document until the
owner decides, and do not enter `SPEC.md` as requirements.

------

## 3. ✅ What the check verifies

Run by the step *Check SPEC contract* of `agent-develop.yml`, after the Issue checks and before
any label change, checkout or Claude Code run.

| # | Check | Failure message |
|---|---|---|
| 1 | `SPEC.md` exists at the root of the **calling** repository, on the `base_branch` the Developer starts from | `Missing SPEC.md at repository root (branch '<base>').` |
| 2 | it holds at least one non-blank character | `SPEC.md is empty.` |
| 3 | the four sections are present as level-2 headings (§2.1); every missing one is reported | `Missing section '## 3. Règles et contraintes'.` |
| 4 | section 2 holds at least one content line | `Section '## 2. Fonctionnalités' describes no behaviour.` |
| 5 | section 4 holds at least one content line | `Section '## 4. Scénarios de validation' holds no validation scenario.` |

A **content line** is a non-blank line that is neither a heading nor an HTML comment. Lines in a
fenced code block are content; a heading inside a fenced code block is not a heading. A section
holding only `### F-001 — To do` and `<!-- … -->` therefore fails check 4.

Sections 1 and 3 must exist but may be short: their quality is a human matter.

### 3.1 Results

| Result | Meaning | Step | Issue |
|---|---|---|---|
| `PASS` | contract holds | succeeds, `SPEC contract: PASS` in the job summary | the run continues normally |
| `FAILED` | conformity error (checks 1–5) | fails: `SPEC CONTRACT FAILED` diagnostic in the log and the job summary, one `::error` annotation per reason | unchanged: keeps `agent:ready`, no label, comment, branch nor Project move |
| `ERROR` | technical error: `SPEC.md` could not be read | fails: `SPEC CONTRACT ERROR` diagnostic | unchanged |

The step output `result` (`steps.spec.outputs.result`) carries the same value.

`ERROR` is never reported as "absent". GitHub answers `404` both for a missing file and for an
unreadable repository, so a `404` counts as "absent" only if the repository and the base branch
are readable with the workflow token; otherwise, and for any other API error (`403`, `5xx`,
network), the result is `ERROR` with GitHub's reason, sanitised and capped at 200 characters.
No token is ever printed.

### 3.2 Isolation

The check reads `repos/$GITHUB_REPOSITORY/contents/SPEC.md?ref=<base_branch>` with the
workflow token, so it always reads the target that called the workflow, and only that one.
FlowForge holds no target `SPEC.md`, no target path and no target name.

### 3.3 What is not gated

| Operation | Gated? | Why |
|---|---|---|
| Developer (`agent-develop.yml`) | **yes** | the only workflow that starts an autonomous development from an Issue |
| Refiner (`agent-refine.yml`) | no | preparing a need must stay possible on a project being specified |
| Reviewer, Iterator, review cycle (`agent-review.yml`, `agent-iterate.yml`, `review-cycle.yml`) | no | they work on an existing PR; unchanged in Phase 8.1 |
| Lifecycle, Notion submission and feedback | no | no development started |
| A human PR that creates or fixes `SPEC.md` | no | FlowForge runs nothing on it |

Whatever the origin of the request (GitHub Issue, Notion Need submitted as an Issue), a
development starts only through `agent:ready` → `agent-develop.yml`, so it always meets the
gate.

------

## 4. 🔧 Fixing a non-conformity

1. Read the `SPEC CONTRACT FAILED` block in the failed run (log or job summary): it names the
   repository, the branch and every failed check with its action.
2. Write or complete `SPEC.md` on the base branch, by pull request (human review, as any change).
3. Re-apply `agent:ready` on the Issue (remove it, then add it again): the Developer runs again,
   from the start.

For `SPEC CONTRACT ERROR`: check GitHub's status, that the workflow token can read the repository
and that `base_branch` exists, then re-apply `agent:ready`. Do not create a `SPEC.md` because of
an `ERROR`: nothing proved it was missing.

> ⚠️ **Warning**: a target that has no `SPEC.md` yet cannot start the Developer any more once it
> calls a FlowForge version with this gate. Add `SPEC.md` before moving the target to it.

------

## 5. 🚧 Limits

- Structure, not meaning: a `SPEC.md` full of placeholders written as text passes.
- The base branch is read when the run starts; a `SPEC.md` changed during the run is not seen.
- Only the four headings and two content counts are checked; identifiers are a convention.
- A failed gate does not comment on the Issue: like the other preconditions, the failure is
  visible in the Actions run (annotation, job summary) and its notification.
- Statuses (§2.3), identifiers and scenario coverage are conventions: the gate does not read them.

------

## 6. 🛠️ Producing `SPEC.md` for an existing project

`SPEC.md` is written in the target, not in FlowForge, by the **target preparation mission**:
[preparation-projet-existant-pour-flowforge.md](preparation-projet-existant-pour-flowforge.md), run
by Claude Code inside the target repository. It produces `SPEC.md` (this contract: titles §2.1,
statuses §2.3) and a review document `docs/flowforge-spec-review.md` (sources, observations,
contradictions, owner questions, scenario → test coverage). This contract stays the single
reference for the structure; the mission only applies it. Before submitting the PR, the structure
can be checked locally with the gate's own helper:

```bash
# From the target repository; <flowforge> is a local FlowForge checkout. Prints nothing when PASS.
bash -c 'source <flowforge>/.github/scripts/flowforge-spec.sh && flowforge_spec_check SPEC.md && echo PASS'
```

Two Phase 8 instructions share the number 37; they are distinct:

| Name | Runs in | Responsibility | Output |
|---|---|---|---|
| **Prompt 37** (Phase 8.1, FlowForge) | FlowForge | the gate: contract, `flowforge-spec.sh`, step *Check SPEC contract*, tests | this document |
| **Target preparation mission** (called "Prompt 37" in the 37.1 audit) | each target | writing `SPEC.md` and its review document, for the owner to validate | `SPEC.md`, `docs/flowforge-spec-review.md` in the target |

Prompt 37.1 audited the first preparations (`demo-api`, `demo-api-2`); Prompt 37.2 aligned the
mission with this contract (titles, statuses, coverage) and corrected `demo-api`.

------

## 7. 🔗 How the agents use `SPEC.md` (Phase 8.2)

No new agent, workflow or rules engine: the existing rules read `SPEC.md` and the Refiner's
structured result carries the comparison.

```text
request ─► Refiner ── reads SPEC.md ── spec_impact ──┬─ COMPLIANT / EXTENDS / NEW_FEATURE / MODIFIES ─► READY possible
                                                      ├─ CONTRADICTS / NEEDS_DECISION ─► NEEDS_CLARIFICATION (arbitration), never READY
                                                      └─ NO_SPEC ─► refinement continues; the Developer gate will refuse
human agent:ready ─► gate (§3) ─► Developer: respects SPEC.md, updates it in the same PR only when the Issue says so
                                ─► Reviewer: Issue ↔ SPEC.md ↔ code ↔ tests (findings)
```

| Agent | Rule | What is enforced by code, not only by the prompt |
|---|---|---|
| Refiner | [refiner §5.4](../agents/refiner.md#54-compare-with-specmd): cite `F/R/S` items, classify the impact, never arbitrate, list contract changes, write a Definition of Done | `flowforge_refine_validate`: presence of `SPEC.md` decided by the workflow and matched by `spec_impact`; `CONTRADICTS` / `NEEDS_DECISION` never `READY`; `READY` needs references, a Definition of Done, and contract changes exactly for `EXTENDS` / `NEW_FEATURE` / `MODIFIES` ([issue contract §5](issue-contract.md#5--ready-definition), R9) |
| Developer | [developer §4.1](../agents/developer.md#41-functional-contract-specmd): preserve `CONFIRMED` requirements, change `SPEC.md` only as the Issue authorises and in the same PR, stop on a contradiction | the gate (§3); the rest is reviewed |
| Reviewer | [reviewer §4.8](../agents/reviewer.md#48-check-the-functional-contract-specmd): severities for a broken requirement, a silent contract change, a missing or inconsistent `SPEC.md` update | the existing verdict rules (a `BLOCKER` / `MAJOR` prevents `APPROVE`) |
| Iterator | [iterator §6.1](../agents/iterator.md#61-fix-the-finding-nothing-else): `SPEC.md` changed only to fix a finding, as the Issue authorises | — |

The semantic comparison stays the agents' judgement, reviewed by a human: the code checks only
what is deterministic.

------

> **Document created on**: 2026-10-19
> **Author**: xgueret, with Claude Code
> **Version**: 1.2 (Phase 8.1, Prompt 37; Prompt 37.2: titles rule, statuses, preparation mission; Phase 8.2, Prompt 38: §7)
