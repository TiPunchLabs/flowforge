# 🎛️ FlowForge — Autonomy contract (v0.2.0)

> **Status**: design (Phase 9, Prompt 42), owner decisions integrated (§11), **implemented in
> Prompt 43** (§13: technical adjustments). Offline-tested (S1–S13); live validation on `demo-api`
> pending (§9). Pilots stay on `v0.1.0`, unchanged.
> **Objective**: decide, with deterministic and verifiable rules, when FlowForge may start the
> Developer on its own after a refinement, and when a human must still apply `agent:ready`.
> **Prerequisites**: [architecture](architecture.md) §2.6 (labels), §2.7 (merge gate), §2.9
> (Refiner); [issue contract](issue-contract.md) §5 (Ready definition); [SPEC contract](spec-contract.md).

## 🧠 Mental Model

```text
                        today (v0.1.0)                           v0.2.0, SEMI_AUTO
                        --------------                           -----------------
 human ─dispatch─► Refiner ─► READY ─► human reads ─► agent:ready ─► Developer
                                  │
                                  └─► autonomy check (bash + jq, no LLM)
                                        LOW + all gates PASS ──► agent:ready (GITHUB_TOKEN) ─► Developer,
                                                                 started by the SAME run (caller job)
                                        anything else       ──► same as today: wait for a human

 The LLM proposes a risk level. The workflow can only RAISE it (SPEC impact, title type,
 keywords), never lower it. Only LOW may start alone. READY is necessary, never sufficient.
 The merge is always human (ruleset).
```

> **Analogy**: the Refiner is the person who fills the work order; the autonomy check is the
> checklist at the counter. Only a small, routine order placed by the owner goes straight to the
> workshop; anything else goes to the owner's desk — exactly where it goes today.

## Contents

0. [Analysis of v0.1.0](#0--analysis-of-v010-what-exists)
1. [Objectives and non-objectives](#1--objectives-and-non-objectives)
2. [Autonomy modes](#2--autonomy-modes)
3. [Risk classification](#3--risk-classification)
4. [Decision rules](#4--decision-rules)
5. [State transitions](#5--state-transitions)
6. [Component responsibilities](#6--component-responsibilities)
7. [Security protections](#7--security-protections)
8. [Error handling](#8--error-handling)
9. [Validation scenarios](#9--validation-scenarios)
10. [Minimal implementation plan](#10--minimal-implementation-plan-prompt-43)
11. [Owner decisions](#11--owner-decisions-2026-10-22)
12. [Acceptance criteria coverage](#12--acceptance-criteria-coverage)
13. [Implementation notes (Prompt 43)](#13--implementation-notes-prompt-43)
14. [Automatic review after an automatic start (Prompt 45)](#14--automatic-review-after-an-automatic-start-prompt-45)

------

## 0. 📖 Analysis of v0.1.0 (what exists)

| Question | Answer in v0.1.0 | Where |
|---|---|---|
| Where is the human gate before development? | A human applies `agent:ready` on the refined Issue. Applying it also accepts every `[recommended]` item as a requirement | [issue-contract §4, §6](issue-contract.md#6--labels-and-states), [refiner §7.2](../agents/refiner.md#72-labels) |
| Who decides an Issue is `READY`? | The Refiner **agent** proposes the verdict; `flowforge_refine_validate` (`.github/scripts/flowforge-refine.sh`) rejects any output that breaks the checkable rules (no blocking question, required sections filled, every criterion tagged, `READY` never with `CONTRADICTS` / `NEEDS_DECISION`, references / contract changes / DoD present) | `agent-refine.yml` step *Validate and render refinement* |
| How is the Developer started? | `issues: labeled` with `agent:ready` in the target caller `flowforge-agent.yml` → `agent-develop.yml`. A label set with `GITHUB_TOKEN` starts nothing (GitHub rule); a label event sent by a bot is refused before any state change | `agent-develop.yml` step *Resolve issue context* |
| What stops an ambiguous or contradictory request? | Validator (above); Refiner `NEEDS_CLARIFICATION` → `agent:needs-clarification`; Ready definition R1–R9; SPEC gate `PASS` required before `agent:running`; the Developer stops (`agent:blocked`) on a contradiction it finds | `flowforge-refine.sh`, `flowforge-spec.sh`, `agents/developer.md` §4.1 |
| What does it NOT stop? | Implicit functional decisions inside a `READY`: on `demo-api` #58 the route path and the counting of completed tasks were **non-blocking** questions with defaults, and one contract change was conditional ("update section 1 only if needed"). A human accepted them with `agent:ready`. Without that human, they would be decided by nobody | [phase8-spec-refinement](milestones/phase8-spec-refinement.md) §3.2, §8 |
| Reusable mechanisms | `refinement.json` (structured, workflow-validated); the two-job Refiner (read-only agent / `issues: write` publish); `flowforge_set_state` (one state label, idempotent, never touches other labels); the digest + precondition re-read in `publish`; `flowforge-spec.sh` local check; per-Issue concurrency groups; the Developer's precondition (Issue open, carries `agent:ready`, branch absent); reusable-workflow outputs; Actions variables; the module's label map; the Project sync events `refine-ready` → `develop-started` | — |

Two GitHub facts constrain the design:

- Events created with `GITHUB_TOKEN` do not start workflows, except `workflow_dispatch` and
  `repository_dispatch` (GitHub Actions docs, *Triggering a workflow from a workflow*). A label
  set by the Refiner's publish job will therefore **never** fire `flowforge-agent.yml`.
- A label set with an App token **would** fire it, and the Developer refuses it (bot sender). So
  the App token must never be used for `agent:ready` (anti-loop rule, [architecture §2.10](architecture.md#210-delivery-identity-flowforge-github-app-issue-34)).

Consequence: the automatic start cannot be an event chain. It is a **job dependency in the same
run**: the target's refine caller gets a second job `develop` that `needs:` the refine job and
runs only when its output says so. Reusable-workflow outputs are available to downstream caller
jobs (GitHub docs, *Using outputs from a reusable workflow*). No new workflow, no dispatch, no
extra permission.

------

## 1. 🎯 Objectives and non-objectives

| Objectives | Non-objectives |
|---|---|
| Two modes, `SUPERVISED` (default, = v0.1.0) and `SEMI_AUTO` (explicit, per target, in the target's Terraform state) | An `AUTO` mode, automatic refinement on Issue opened, Notion-triggered starts |
| Start the Developer without a human **only** for `LOW` requests of the repository owner, when every deterministic gate passes | Automatic start for `MEDIUM` or `HIGH` (v0.2.0); letting the LLM authorise anything on its own |
| Three risk levels `LOW` / `MEDIUM` / `HIGH`, fail-closed | Path-level diff analysis, a policy engine, a permission system |
| Keep every existing protection: human merge, ruleset, iteration bound, one state label | Automatic review cycle start, auto-merge, marking PRs ready, deployment |
| A trace of every decision; easy deactivation per Issue and per target | A new component, dependency, secret or GitHub permission |

------

## 2. 🔀 Autonomy modes

| Mode | Behaviour | Who enables it |
|---|---|---|
| `SUPERVISED` | **Identical to v0.1.0**: same labels, same Issue body and comment text, no automatic start. The decision is computed and written **only** to `refinement.json` and the run summary (`would AUTO_START` / `HUMAN_REQUIRED`), so `SEMI_AUTO` can be evaluated before it is turned on | default |
| `SEMI_AUTO` | After a `READY`, the publish job applies `agent:ready` itself **when all gates of §4 pass**, and the same workflow run starts the Developer. Otherwise identical to `SUPERVISED`, plus the decision in the Issue (§5.4) | target owner, through Terraform |

### 2.1 Configuration (owner decision Q1: Terraform, in the target's state)

Two non-secret **repository** Actions variables, managed by the `target-repository` module in the
state that owns the target (one target = one IaC owner = one state, onboarding §2):

| Variable | Module input | Value | Absent |
|---|---|---|---|
| `FLOWFORGE_AUTONOMY_MODE` | `autonomy_mode` (default `null`) | `SUPERVISED` or `SEMI_AUTO` (Terraform `validation`) | `SUPERVISED` |
| `FLOWFORGE_AUTONOMY_OWNER` | `autonomy_owner` (default `null`; required when `SEMI_AUTO`, `validation`) | the GitHub login of the repository owner (Q3) | no owner ⇒ no automatic start |

- `null` creates **no resource** (no placeholder resource, Terraform rules): a target that does
  not set the inputs has no variable and stays `SUPERVISED`.
- Variables are not secrets: managing them in Terraform is allowed (only Actions **secrets** are
  forbidden in state). Terraform writes them with the maintainer's `GITHUB_TOKEN` env var, which
  already administers the target (rulesets): no new permission, no Actions permission at all.
- The refine caller passes them as typed inputs of `agent-refine.yml`:
  `autonomy_mode: ${{ vars.FLOWFORGE_AUTONOMY_MODE || 'SUPERVISED' }}`,
  `autonomy_owner: ${{ vars.FLOWFORGE_AUTONOMY_OWNER }}`.
- **Absent, empty or any other value ⇒ `SUPERVISED`** (exact, case-sensitive match on
  `SEMI_AUTO`; a different value adds a warning to the run summary). An older caller that does
  not pass the inputs gets the defaults: upgrading FlowForge never turns autonomy on by itself.
- Never at organization level: an organization variable would enable every target at once.
  Readiness check R19 (§10) verifies it.

> ⚠️ **Warning**: a target can only be `SEMI_AUTO` if its refine caller also has the `develop`
> job (§5.2). Setting the variables without it applies `agent:ready` but starts nothing; the
> Issue then waits like a human-ready Issue whose label event was lost (remove and re-apply the
> label). The updated caller template ships inputs and job together.

### 2.2 Pilot projects stay as they are

`demo-api` and `demo-api-2` consume FlowForge at `v0.1.0` (callers pinned to the full SHA, module
`?ref=v0.1.0`): nothing in v0.2.0 reaches them until their owner bumps the pins. After a bump, with
no autonomy input set, they stay `SUPERVISED` with the v0.1.0 Issue output (§2 table). The only
visible addition is the `agent:manual` label, created at their next approved `apply`; it changes
no behaviour by itself.

------

## 3. ⚖️ Risk classification

| Level | Examples | Behaviour in `SEMI_AUTO` (Q5) |
|---|---|---|
| `LOW` | Tests only; documentation fixes; localised refactoring with no functional change | **Automatic start allowed** when every gate of §4 passes |
| `MEDIUM` | New feature; API change; functional evolution explicitly decided by the owner; any bug fix | **Human validation** (`agent:ready` by a human) |
| `HIGH` | Authentication / authorisation; secrets, tokens, permissions; infrastructure, Terraform; CI/CD workflows; deletion or migration of data; security changes | **Human validation** |

### 3.1 How the level is computed (fail-closed, Q6)

```text
proposed  = Refiner output `risk_level`            (LLM, may be wrong or manipulated)
floor     = max(impact_floor, type_floor, keyword_floor)   (deterministic, bash + jq)
effective = max(proposed, floor)                   LOW < MEDIUM < HIGH; missing/unknown ⇒ HIGH
```

| Deterministic floor | Rule |
|---|---|
| `impact_floor` | `COMPLIANT` → `LOW`; `EXTENDS`, `NEW_FEATURE` → `MEDIUM`; `MODIFIES` → `HIGH`; anything else is not `READY` and not evaluated |
| `type_floor` | From the refined title's Conventional Commit type: `test`, `docs`, `refactor` (optional scope, no `!`) → `LOW`; `ci`, `build` → `HIGH`; any other type (`feat`, `fix`, `perf`, `chore`, …) or an unparsable title → `MEDIUM` |
| `keyword_floor` | `HIGH` if a fixed list of word prefixes (case-insensitive, matched at a word start: `\b<term>`) matches the refined `title`, `goal`, `scope`, `acceptance_criteria`, `references`, `spec_changes`, **or** the `constraints`, `notes_for_agents` and original request **minus their prohibition clauses** (below) (English and French terms, path fragments): `authent`, `authoriz`, `autoris`, `login`, `password` / `mot de passe`, `token` / `jeton`, `secret`, `credential`, `permission`, `role`, `oauth`, `jwt`, `session`, `security` / `sécurité`, `crypt`, `tls`, `ssl`, `cve`, `vulnerab`, `terraform`, `.tf`, `infra`, `.github/`, `workflow`, `pipeline`, `ci/cd`, `deploy`, `docker`, `migration` / `migrat`, `delete` / `suppression`, `drop`, `truncate`, `purge`, `schema`, `database` / `base de données`. Otherwise `LOW` |

- The keyword list lives in `flowforge-refine.sh` next to the validator, as one array, and is tested.
- **Prohibition clauses** (Prompt 44.2B.1, from `demo-api` #63: the Refiner copied *Do not modify
  `.github/workflows/`* from `CLAUDE.md` into the constraints, which raised a tests-only request to
  `HIGH`). In the constraints, the notes and the original request, each clause (cut at `.` `;` `,`
  `:` `!` `?` before a space, and at line ends) that **opens** with a ban on a change — *do not /
  don't / never / must not / should not / ne pas / ne jamais* + *modify, change, edit, touch, alter,
  update, rewrite, remove, delete* (or the French verbs), *no change(s) / without changes / aucune
  modification / sans modifier* — is not scanned, **unless** it holds a connective that may carry a
  second operation (*but, unless, except, instead, however, then, and, also, plus, mais, sauf,
  sinon, puis, et, aussi, ensuite, plutôt*). Anything else is scanned, so ambiguity stays `HIGH`:
  *Do not forget to update the workflow*, *Do not modify X, update the workflow*, *… unless needed*.
  A list of protected paths after one ban (*Do not modify src/, .github/ or terraform/*) is cut at
  its commas and stays `HIGH` (a false positive): one ban per clause. The positive fields (title,
  goal, scope, criteria, references, contract changes) are always scanned whole, a negation there
  included, so the Refiner cannot hide a change by rewording it. Rules: `FLOWFORGE_RISK_BAN` /
  `FLOWFORGE_RISK_BAN_BREAK` in `flowforge-refine.sh`, tested.
- Each floor is deliberately coarse: a **false positive** costs one human click (the v0.1.0 path);
  a false negative is what the floors exist to reduce. Matched words and types are recorded (§5.4).
- The LLM can **raise** the level (it sees the code), never **lower** it below the floor. The title
  type is also written by the LLM, but it can only **narrow** the automatic path (a `LOW` type is
  one more condition, never a sufficient one).
- Strengthening stays inside these three tables (new words, types, impacts): no rule engine.

> 💡 **Note**: the floors are a safety net, not a proof. A HIGH-risk change described with a
> `test:` / `docs:` / `refactor:` title, a `LOW` proposal and none of the keywords would pass.
> Residual risk is bounded by what stays human — the Reviewer, the GitHub approval and the merge
> (§7) — and by the owner having both opened the Issue and dispatched the Refiner (G9).

------

## 4. 🧮 Decision rules

The decision is computed by one function, `flowforge_autonomy_decide`, **after**
`flowforge_refine_validate` succeeded, from: `refinement.json`, the mode and owner inputs, the
local SPEC check of the checked-out default branch, the Issue JSON and the comments already read,
`github.triggering_actor`, and one read-only label lookup. No LLM. Every gate is evaluated (no
short-circuit) so the trace lists **all** failed gates.

| Gate | Condition to pass | Fails ⇒ | Reason code |
|---|---|---|---|
| G1 | `verdict == READY` | `NO_START` (Issue is `agent:needs-clarification`, or unchanged when `BLOCKED`) | `D-VERDICT` |
| G2 | `mode == SEMI_AUTO` | `HUMAN_REQUIRED` | `D-MODE` |
| G3 | `spec_present` and `flowforge_spec_check SPEC.md` = `PASS` on the default branch | `HUMAN_REQUIRED` | `D-SPEC` |
| G4 | `spec_impact == COMPLIANT` and `spec_changes == []`: the automatic path never changes `SPEC.md` | `HUMAN_REQUIRED` | `D-IMPACT` |
| G5 | ≥ 1 cited `F-/R-/S-` identifier, and **every** cited identifier exists as a heading in `SPEC.md` | `HUMAN_REQUIRED` | `D-REFS` |
| G6 | `acceptance_criteria` and `definition_of_done` non-empty (already enforced for `READY`; re-checked, fail closed) | `NO_START` | `D-INCOMPLETE` |
| G7 | **Explicitness (#58 rule)**: `open_questions == []` (no non-blocking default either), `assumptions == []`, no `[recommended]` tag in `acceptance_criteria` | `HUMAN_REQUIRED` | `D-IMPLICIT` |
| G8 | `effective` risk is `LOW` and `proposed` is a known level | `HUMAN_REQUIRED` | `D-RISK-MEDIUM` / `D-RISK-HIGH` / `D-RISK-UNKNOWN` |
| G9 | **Owner only (Q3)**: `autonomy_owner` set; the Issue author is a `User` whose login equals it; `github.triggering_actor` (who dispatched the Refiner) equals it; every human comment given to the Refiner was written by it | `HUMAN_REQUIRED` | `D-OWNER` |
| G10 | **Not from Notion (Q2)**: the Issue body (including the quoted *Original request*) holds no `flowforge:notion-page-id=` marker | `HUMAN_REQUIRED` | `D-NOTION` |
| G11 | **No opt-out (Q4)**: the Issue does not carry `agent:manual` (checked in the refine job **and** re-checked by the publish job right before `agent:ready`), and the label exists on the repository | `HUMAN_REQUIRED` | `D-MANUAL` / `D-MANUAL-MISSING` |
| G12 | No error while evaluating G1–G11 | `HUMAN_REQUIRED` | `D-ERROR` |

**Result** — one of three values:

| Decision | Meaning | Labels after publish | Developer |
|---|---|---|---|
| `AUTO_START` | G1–G12 pass, mode `SEMI_AUTO` | `agent:ready` (set by the publish job, `GITHUB_TOKEN`) | started by the same run |
| `HUMAN_REQUIRED` | `READY`, but at least one of G2–G5, G7–G12 fails | none (as v0.1.0) | only after a human `agent:ready` |
| `NO_START` | Not `READY` (G1) or required data missing (G6) | `agent:needs-clarification`, or unchanged | none until a new refinement |

### 4.1 The LOW start rule, in one place

The Developer starts without a human **if and only if all** of these hold:

1. the target is `SEMI_AUTO` in its Terraform state, with an owner declared;
2. the owner opened the Issue **and** dispatched the Refiner, and no one else commented on it;
3. the Issue did not come from Notion and does not carry `agent:manual`;
4. the Refiner returned `READY`, validated by `flowforge_refine_validate`;
5. `SPEC.md` passes the contract check and every cited `F/R/S` item exists;
6. the request is `COMPLIANT` and changes nothing in `SPEC.md`;
7. nothing is implicit: no open question, no assumption, no `[recommended]` criterion;
8. acceptance criteria and Definition of Done are present;
9. the effective risk is `LOW`: proposal `LOW`, title type `test` / `docs` / `refactor`, no
   sensitive keyword;
10. no error occurred while checking 1–9.

### 4.2 Required cases

| Case | Gates | Decision |
|---|---|---|
| Unknown classification | G8 `D-RISK-UNKNOWN` | `HUMAN_REQUIRED` |
| Ambiguous request | blocking question ⇒ `NEEDS_CLARIFICATION` (G1); non-blocking question or default ⇒ G7 | `NO_START` / `HUMAN_REQUIRED` |
| Contradiction with `SPEC.md` | `CONTRADICTS` is never `READY` (validator) | `NO_START` (blocked until arbitration) |
| Acceptance criteria missing | validator refuses `READY` (run `FAILED`), G6 re-checks | nothing published / `NO_START` |
| DoD missing | same | nothing published / `NO_START` |
| Risk `MEDIUM` or `HIGH` | G8 (and G4 for contract changes) | `HUMAN_REQUIRED` |
| Mode `SUPERVISED` | G2 | `HUMAN_REQUIRED` |
| Notion request | G9 (Bridge author) and G10 (marker) | `HUMAN_REQUIRED` |
| `agent:manual` | G11 | `HUMAN_REQUIRED` |
| `SEMI_AUTO` + `LOW`, owner, explicit | all pass | `AUTO_START` |

### 4.3 Why `READY` is not enough (#58)

`READY` means "no **blocking** question". It allows non-blocking questions with defaults,
`[recommended]` criteria and assumptions — each one a decision a human silently accepts by
applying `agent:ready` ([issue-contract §4](issue-contract.md#4--provenance-tags)). Gate G7
removes that silent acceptance from the automatic path: an Issue starts on its own only when
every requirement is `[provided]` or `[observed]`, nothing is assumed and nothing is left to a
default. G4 adds that the contract itself never changes without a human. #58 itself
(`NEW_FEATURE`, two non-blocking questions, a conditional contract change) fails G4, G7 and G8.
The rules are mechanical (tags, enums and array lengths in `refinement.json`), so they do not
depend on the model judging its own uncertainty.

------

## 5. 🚦 State transitions

### 5.1 Flows

```text
SUPERVISED
  human dispatch ─► Refiner ─► READY ─► decision HUMAN_REQUIRED (D-MODE) ─► no label
                                         ─► human applies agent:ready ─► flowforge-agent.yml ─► Developer

SEMI_AUTO, LOW, owner, all gates pass
  owner dispatch ─► Refiner ─► READY ─► decision AUTO_START
                    publish: body + comment, re-check agent:manual, agent:ready (GITHUB_TOKEN, triggers nothing)
                    caller job `develop` (needs: refine, if autostart) ─► agent-develop.yml ─► Developer
                    ─► Draft PR (head_sha) ─► caller job `review` (needs: develop, if head_sha)
                    ─► agent-review.yml (that exact delivery, once) ─► verdict ─► human validation, human merge

SEMI_AUTO, MEDIUM / HIGH / Notion / agent:manual / not the owner / any failed gate
  dispatch ─► Refiner ─► READY ─► decision HUMAN_REQUIRED (reasons) ─► no label
                                   ─► human applies agent:ready (as v0.1.0)

Contradiction / missing decision
  Refiner ─► NEEDS_CLARIFICATION (CONTRADICTS | NEEDS_DECISION) ─► agent:needs-clarification
         ─► human arbitration in a comment ─► human dispatches the Refiner again
         ─► READY + MODIFIES ─► HUMAN_REQUIRED (G4, G8) ─► human agent:ready
```

Downstream of `agent:ready` nothing changes: `agent:running` → `agent:review` / `agent:blocked`
→ human merge → `agent:done` ([architecture §2.6](architecture.md#26-issue-label-lifecycle-phase-41)).
The review cycle stays `workflow_dispatch` (open decision, architecture §6): after a
`REQUEST_CHANGES` of the automatic review (§14), a human dispatches it for the bounded Iterator loop.

### 5.2 Who does what

| Step | Component | Trigger | Token |
|---|---|---|---|
| Refinement | Refiner agent (read-only) | human `workflow_dispatch` of `flowforge-refine.yml` | read-only `GITHUB_TOKEN` + Claude |
| Risk proposal | Refiner agent (`risk_level`, `risk_reasons`) | same run | — |
| Decision | `flowforge_autonomy_decide`, refine job, after validation | same run | read-only `GITHUB_TOKEN` (label lookup only) |
| `agent:ready` | publish job, via `flowforge_set_state`, **last write**, only on `AUTO_START` | same run | `GITHUB_TOKEN` `issues: write` (already granted) |
| Developer start | target caller job `develop`: `needs: refine`, `if: needs.refine.outputs.autostart == 'true'`, `uses: agent-develop.yml@<SHA>` | same run | the permissions `flowforge-agent.yml` already grants to `develop` |
| `agent:manual` | a human with triage access, at any time | — | — |
| Project card | existing events `refine-ready` then `develop-started` | same run | App token, Project only |
| Review (Prompt 45, §14) | target caller job `review`: `needs: [refine, develop]`, `if:` autostart and `needs.develop.outputs.head_sha != ''`, `uses: agent-review.yml@<SHA>` with the expected delivery | same run | the permissions `flowforge-review.yml` already grants to `review` |

The refine job's permissions are unchanged (read-only, Claude token). The new `develop` caller
job gets **exactly** the permissions and secrets of `flowforge-agent.yml` — no permission is
created; it is the same job reached through a second door.

`agent:manual` is **not** a state label: it is not in `FLOWFORGE_STATE_LABELS`, so
`flowforge_set_state` never adds or removes it, the "one state label" rule is unchanged, and the
Project / Notion syncs ignore it. It only blocks the automatic path; a human applying
`agent:ready` on such an Issue is the validation it asks for. It may stay on the Issue.

### 5.3 Idempotence and double starts

| Risk | Protection (existing unless marked new) |
|---|---|
| Two Refiner runs on the same Issue | `concurrency: flowforge-refine-<repo>-<issue>` serialises them; the second fails `flowforge_refine_preconditions` (Issue carries `agent:ready` / `agent:running`) before Claude runs |
| Run re-run ("Re-run all jobs") | Same precondition: an Issue with a state other than `agent:needs-clarification` is never refined again |
| Re-run of the `develop` job only | `agent-develop.yml` refuses an Issue without `agent:ready` and an existing `agent/<n>-*` branch; concurrency group per Issue |
| `agent:ready` set by the publish job fires `flowforge-agent.yml` | Impossible with `GITHUB_TOKEN`; **new test** asserts the publish job never uses the App token for labels |
| Human re-applies `agent:ready` during the automatic run | `labeled` only fires on add; a remove + add queues behind the same concurrency group, then fails on the existing branch / missing label |
| Issue edited between Refiner read and publish | Existing digest check: nothing published, no label, `autostart` not set |
| `agent:manual` added while the Refiner runs | **New**: the publish job re-reads the Issue just before `agent:ready`; the label wins, decision downgraded to `HUMAN_REQUIRED (D-MANUAL)` |
| Label `agent:ready` missing on the repository | `flowforge_set_state` only warns; **new**: the publish job re-reads the Issue and sets `autostart=true` only if the label is really present |

`autostart` is set **only** by a successful publish job, after the label is verified; any earlier
failure leaves it empty, and the `develop` job is skipped. The same holds one step later for the
automatic review (§14.2): `head_sha` is empty unless this run delivered, and the `review` job is
skipped.

### 5.4 Trace of the decision

| Where | Content |
|---|---|
| `refinement.json` (`schema_version: 3`) | new workflow-written object `autonomy` (§10.2), in every mode |
| Run summary | gates table (pass / fail, reason), in every mode |
| Refinement record (`SEMI_AUTO` only) | one line per entry: `- Autonomy: SEMI_AUTO · risk LOW (proposed LOW, floor LOW) · AUTO_START` or `… · HUMAN_REQUIRED (D-IMPLICIT, D-RISK-HIGH: terraform)` |
| FlowForge Refiner comment (`SEMI_AUTO` only) | `AUTO_START`: "The Developer was started automatically (`SEMI_AUTO`, `LOW`). The merge stays human." `HUMAN_REQUIRED`: today's text plus the failed gates in plain words |
| GitHub timeline | `github-actions` added `agent:ready`; the `develop` job in the same run |

The record states the **decision**; the label is the **effect**. If the label write failed, the
record says `AUTO_START` while the Issue has no label and no Developer ran — the run failure
explains it (§8).

------

## 6. 🧩 Component responsibilities

| Component | v0.2.0 responsibility | Never |
|---|---|---|
| Refiner agent | Refines; proposes `risk_level` + `risk_reasons` | Applies labels, decides the start, lowers a floor |
| `flowforge-refine.sh` | Validates (schema v3), computes floors and decision, renders the trace | Writes to GitHub, reads Notion |
| `agent-refine.yml` refine job | Runs the local SPEC check and the decision; outputs it | Gets a write token |
| `agent-refine.yml` publish job | Publishes, re-checks `agent:manual`, applies `agent:ready` on `AUTO_START`, verifies it, outputs `autostart` | Uses the App token for labels |
| Target `flowforge-refine.yml` | Passes mode and owner; holds the `develop` job | Any logic beyond `if:` on the output |
| `target-repository` module | Creates `agent:manual`; creates the two variables when its inputs are set | Holds secrets; enables autonomy by default |
| `agent-develop.yml` | Unchanged: same preconditions, SPEC gate, delivery | Starts without `agent:ready` |
| Reviewer / Iterator / cycle / lifecycle | Unchanged; iteration bound `max_iterations = 3` kept | Merge, approve, mark ready |
| Ruleset (Terraform) | Unchanged: PR + ≥ 1 human approval, no force push, no FlowForge bypass | — |
| Owner | Enables `SEMI_AUTO` in Terraform; opens and dispatches LOW Issues; arbitrates; validates MEDIUM / HIGH / Notion / `agent:manual`; reviews, approves and merges | — |

------

## 7. 🔐 Security protections

- `SUPERVISED` by default; `SEMI_AUTO` only through reviewed Terraform in the target's state,
  with a named owner.
- The trigger stays a human `workflow_dispatch` on one Issue; only the owner's own dispatch on the
  owner's own Issue can lead to an automatic start.
- No start on missing data, invalid `SPEC.md`, open arbitration, contradiction, contract change,
  implicit decision, `MEDIUM` / `HIGH` / unknown risk, Notion origin, `agent:manual`, or any
  author, dispatcher or commenter other than the owner.
- No permission widened: refine job read-only; publish job keeps `issues: write`; `develop` reuses
  the Developer's existing grant; Terraform uses the maintainer token it already uses. No new
  secret, App permission or workflow.
- No implicit `SPEC.md` change: the automatic path is `COMPLIANT` only (G4), so the Developer has
  no contract change to make; any contract change goes through a human.
- Merge remains human: ruleset approval ≥ 1, author cannot approve its own PR, no FlowForge
  workflow submits a review, merges or enables auto-merge ([architecture §2.7](architecture.md#27-human-merge-gate-phase-41)).
- Prompt injection: Issue text can try to make the Refiner say `LOW` or write a `test:` title; it
  cannot remove a keyword floor, an impact floor, a tag check, or the owner / Notion / opt-out
  checks, which run in bash on data the model does not control.
- Trust boundary unchanged: write access to the target. A writer could already run arbitrary
  workflows from a branch in v0.1.0; v0.2.0 adds no capability beyond that.

### 7.1 Deactivation

| Scope | How | Effect |
|---|---|---|
| One Issue | Add `agent:manual` (triage access) | Immediate: `HUMAN_REQUIRED (D-MANUAL)` on the next decision, even mid-run before publish |
| One target, normal | Module input `autonomy_mode = "SUPERVISED"` (or `null`) + approved `apply` | `HUMAN_REQUIRED (D-MODE)` from the next Refiner run |
| One target, emergency | `gh variable set FLOWFORGE_AUTONOMY_MODE -R <target> --body SUPERVISED` | Immediate. **Then** make the same change in Terraform **before any `apply`**: otherwise the next `apply` restores `SEMI_AUTO` (the `plan` shows the drift) |
| A run in progress | Cancel it in Actions | Stops the `develop` job; existing Developer handling applies |

No caller change is needed to go back.

### 7.2 Limits accepted for the POC

| Limit | Why acceptable |
|---|---|
| The floors can miss a sensitive change | Human review + approval + merge remain; false positives only cost the v0.1.0 path |
| `refactor` "localised" is not measured | `LOW` only with `COMPLIANT` and explicit criteria; the Reviewer checks behaviour is unchanged |
| An Issue body edited by another writer before the run is not detected (only edits during the run) | Needs write access, the same trust boundary as v0.1.0 |
| Caller duplication: `develop` inputs (`setup_uv`, `allowed_tools`) repeated in two callers | Thin callers, no logic; checked by R13 |

------

## 8. 🔧 Error handling

| Failure | Effect | Developer |
|---|---|---|
| Error inside the decision (jq, missing field, SPEC read, label lookup) | `HUMAN_REQUIRED (D-ERROR)`, `READY` still published — falls back to v0.1.0 | no |
| SPEC check `FAILED` / `ERROR` | `HUMAN_REQUIRED (D-SPEC)`; the Developer gate would refuse anyway | no |
| Validator rejects the output | run fails, nothing published (as today) | no |
| Publish fails before the label (digest, API) | run fails, `autostart` empty, `develop` skipped | no |
| `agent:manual` found at the publish re-check | no label, `HUMAN_REQUIRED (D-MANUAL)`, `autostart` empty | no |
| Label write fails or label absent after write | publish fails / `autostart` not set | no |
| `develop` fails at preconditions or SPEC gate | Issue keeps `agent:ready` (as today); human fixes and re-applies | no |
| `develop` fails after start | existing Developer handling (`agent:blocked` / no state) | stopped |
| Project sync error | warning only (best-effort, unchanged) | unaffected |

Rule: **every error before the label is fail-closed to `SUPERVISED` behaviour**; after the label,
the Developer's existing error handling applies.

------

## 9. 🧪 Validation scenarios

Offline scenarios run in `tests/refiner.sh` (fixtures of `refinement.json`, Issue JSON, comments,
a `SPEC.md`, a `gh` stub) and the module's `terraform test`. Live scenarios run on `demo-api`
(reference project) **without changing its behaviour** (§2.2): a temporary caller branch pinned
to the feature branch passes the autonomy inputs explicitly (as in Prompt 38), on dedicated test
Issues; `main`, its callers and its Terraform variables are not touched; the branch is deleted
afterwards. Live `AUTO_START` needs `agent:manual` on `demo-api` (one approved, additive `apply`).

| # | Setup | Expected | Evidence |
|---|---|---|---|
| S1 | `SUPERVISED`, LOW, explicit `READY` by the owner | `HUMAN_REQUIRED (D-MODE)`; no label; `develop` skipped; Issue body and comment identical to v0.1.0 | test; live: `autonomy.decision` in the artifact, run summary, `develop` skipped |
| S2 | `SEMI_AUTO`, owner author + dispatcher, `test:` title, `COMPLIANT`, `LOW`, no question / assumption / `[recommended]`, no `agent:manual` | `AUTO_START`; `agent:ready` by `github-actions`; `develop` runs → Draft PR | record line; timeline label event; same run id holds `develop`; card Ready → Developing; PR Draft and unmerged |
| S3 | `SEMI_AUTO`, `NEW_FEATURE` / `EXTENDS`, explicit contract, all `[provided]` | `HUMAN_REQUIRED (D-IMPACT, D-RISK-MEDIUM)` — **Q5 supersedes the initial "automatic start"** | test; no label |
| S4 | `SEMI_AUTO`, request mentions a token / Terraform / workflow, or title `ci:`, proposal `LOW` | `HUMAN_REQUIRED (D-RISK-HIGH: <word or type>)` | `autonomy.risk_floor_reasons`; no label |
| S5 | `SEMI_AUTO`, contradicts a `CONFIRMED` `R-xxx` | `NEEDS_CLARIFICATION`, `NO_START`, `agent:needs-clarification` | validator still refuses a forged `READY` + `CONTRADICTS` (test) |
| S6 | `SEMI_AUTO`, `NEEDS_DECISION`; then answer → `MODIFIES` | `NO_START`, then `HUMAN_REQUIRED (D-IMPACT, D-RISK-HIGH)` | two record entries; never `AUTO_START` |
| S7 | `SEMI_AUTO`, incomplete data: non-blocking question, `[recommended]` criterion, assumption, unknown `R-999`, `risk_level` missing, owner input empty | `HUMAN_REQUIRED` with `D-IMPLICIT` / `D-REFS` / `D-RISK-UNKNOWN` / `D-OWNER`; missing AC / DoD → validator `FAILED` | one test per gate; all reasons listed together |
| S8 | Same Issue dispatched twice; run re-run; `develop` re-run | one branch, one Draft PR, one Developer run that writes | second run fails preconditions before Claude; `agent-develop` refuses (branch exists / no label) |
| S9 | Decision error; label lookup error; label write error; Issue edited during run | no `agent:ready`, `develop` skipped | `D-ERROR` in record, or failed publish + empty `autostart` (`gh` stub) |
| S10 | S2 setup, then mode set back to `SUPERVISED` (Terraform input, and separately the emergency `gh variable set`) | `HUMAN_REQUIRED (D-MODE)` on a new Issue | record line; `develop` skipped; module test: input `SUPERVISED` / `null` |
| S11 | `SEMI_AUTO`, S2-like Issue submitted from Notion (Bridge author, marker), dispatched by the owner | `HUMAN_REQUIRED (D-OWNER, D-NOTION)` | test with a Bridge-authored fixture; marker kept in *Original request* still detected |
| S12 | `SEMI_AUTO`, S2-like Issue carrying `agent:manual`; and `agent:manual` added during the run | `HUMAN_REQUIRED (D-MANUAL)` in both cases; no `agent:ready` | test; publish re-check (`gh` stub returns the label on the second read) |
| S13 | `SEMI_AUTO`, S2-like Issue opened by a collaborator, or dispatched by one, or with a collaborator comment | `HUMAN_REQUIRED (D-OWNER)` | test, one case each |

Static checks (offline): publish job never uses the App token for `agent:ready`; `develop` caller
job grants exactly the Developer's permissions; inputs default to `SUPERVISED` / empty owner;
module creates no variable when inputs are `null` and rejects other values; `actionlint` clean.

------

## 10. 🛠️ Minimal implementation plan (Prompt 43)

### 10.1 Changes

| # | File | Change |
|---|---|---|
| 1 | `agents/refiner.md` | §5.5 *Risk proposal*: `risk_level` (`LOW` / `MEDIUM` / `HIGH`, HIGH when unsure) and `risk_reasons`; the proposal authorises nothing |
| 2 | `docs/issue-contract.md` | §5: `READY` ≠ start authorisation; §6: `agent:ready` set by a human, or by the Refiner **workflow** on `AUTO_START`; `agent:manual`; §7: record line *Autonomy* |
| 3 | `.github/scripts/flowforge-refine.sh` | schema v3 in the validator (`risk_level`, `risk_reasons`); `FLOWFORGE_RISK_KEYWORDS`; floors; `flowforge_autonomy_decide`; record line and comment text (`SEMI_AUTO` only) |
| 4 | `.github/workflows/agent-refine.yml` | inputs `autonomy_mode` (default `SUPERVISED`), `autonomy_owner` (default empty); JSON schema fields; step *Decide autonomy* (local `flowforge_spec_check`, label lookup, decide, `autonomy` in `refinement.json`); publish: `agent:manual` re-check, label last + verify; outputs `autostart`, `base_branch` |
| 5 | `examples/target-repository/flowforge-refine.yml` | pass both inputs; add job `develop` (`needs: refine`, `if:` on `autostart`, same `with` / `permissions` / `secrets` as `flowforge-agent.yml`) |
| 6 | `terraform/modules/target-repository` | label `agent:manual` in the default label map; inputs `autonomy_mode` / `autonomy_owner` (default `null`, `validation`); two `github_actions_variable` resources created only when set; README; `terraform test` cases (null ⇒ none, `SEMI_AUTO` without owner rejected) |
| 7 | `tests/refiner.sh` | S1–S13 offline + static checks |
| 8 | Docs | `docs/architecture.md` §2.14 + §5.8 (schema v3); `docs/target-onboarding.md`: inputs, caller table, **R7** = 7 `agent:*` labels, **R12** allows exactly the two autonomy variables when they are in the target's state, **R19** "autonomy variables are repository-level only, in the target's Terraform state, owner = the repository's human owner"; this document's status |

`agent-develop.yml`, Reviewer, Iterator, cycle, lifecycle, Notion workflows: **unchanged**.
`demo-api` / `demo-api-2`: **unchanged** (pinned to `v0.1.0`, §2.2).

### 10.2 `refinement.json` v3 additions

```json
{
  "schema_version": 3,
  "risk_level": "LOW",
  "risk_reasons": ["tests only, no behaviour change `[observed]`"],
  "autonomy": {
    "mode": "SEMI_AUTO",
    "owner": "repository-owner-login",
    "proposed_risk": "LOW",
    "risk_floor": "LOW",
    "risk_floor_reasons": [],
    "effective_risk": "LOW",
    "spec_check": "PASS",
    "gates": {"G1": true, "G2": true, "G3": true, "G4": true, "G5": true, "G6": true,
              "G7": true, "G8": true, "G9": true, "G10": true, "G11": true, "G12": true},
    "reasons": [],
    "decision": "AUTO_START"
  }
}
```

`risk_level` / `risk_reasons` come from the agent; `autonomy` is written by the workflow only,
like the fields before `verdict` (architecture §5.8). The publish job may downgrade `decision`
to `HUMAN_REQUIRED` (G11 re-check); it never upgrades it.

### 10.3 Order and live validation

1. Script + tests (offline, S1–S13). 2. Module + `terraform test`. 3. Workflow + caller template.
4. Docs. 5. Live on `demo-api` from a temporary caller branch (§9): S1, then S2 / S4 / S7 / S12 /
S13 with explicit inputs, then S10; `demo-api` `main` and `demo-api-2` untouched. 6. Tag `v0.2.0`
after merge, on the maintainer's go-ahead.

Owner approvals needed during Prompt 43: the additive `apply` creating `agent:manual` on
`demo-api` (for live `AUTO_START`), and any live run that starts a Developer.

------

## 11. ✅ Owner decisions (2026-10-22)

| # | Question | Decision | Where |
|---|---|---|---|
| Q1 | How is the mode configured? | `FLOWFORGE_AUTONOMY_MODE` managed **by Terraform, in the target's state** (with `FLOWFORGE_AUTONOMY_OWNER`, needed by Q3) | §2.1, §7.1, §10.1 #6 |
| Q2 | Notion-submitted Issues? | **Always human validation** before development | G9, G10; S11 |
| Q3 | Who may benefit from automatic start? | **The repository owner only** (author, dispatcher and only commenter) | G9; S13 |
| Q4 | Per-Issue opt-out? | **Label `agent:manual`** forces human validation | G11, §5.2, §7.1; S12 |
| Q5 | Which levels start automatically? | **`LOW` only**; `MEDIUM` and `HIGH` need human validation | §3, G4, G8; S3 |
| Q6 | Classification rules? | **Deterministic, fail-closed**; strengthened without a rule engine: title-type floor added, SPEC impact floor, keyword floor | §3.1 |

Constraints restated by the owner, all held: `SUPERVISED` default (§2); `READY` never sufficient
(§4.3); merge exclusively human (§7); no extra GitHub permission (§5.2, §7); easy deactivation
(§7.1); pilots unchanged (§2.2).

------

## 12. ✅ Acceptance criteria coverage

| Criterion | Covered by |
|---|---|
| AC-01 modes defined | §2 |
| AC-02 `SUPERVISED` = v0.1.0 | §2 table (same labels, body, comment), §2.2, S1 |
| AC-03 explicit LOW / MEDIUM / HIGH | §3 |
| AC-04 verifiable decisions | §4 gates with reason codes, §5.4 trace, §10.2 |
| AC-05 LLM classification alone cannot authorise | §3.1 floors, G2–G12, §4.1 |
| AC-06 ambiguity and contradiction block | G1, G7, §4.2, S5–S7 |
| AC-07 HIGH stays human | §3, G8, S4 (MEDIUM too, Q5: S3) |
| AC-08 merge human | §7, §6 |
| AC-09 idempotence and errors | §5.3, §8, S8, S9 |
| AC-10 reuse of the architecture | §0, §5.2, §10.1 (no new workflow / component) |
| AC-11 scenarios S1–S10 | §9 (plus S11–S13 for Q2–Q4) |
| AC-12 return to `SUPERVISED` | §7.1, S10 |
| Owner: six decisions integrated | §11 |
| Owner: explicit LOW start rule | §4.1 |
| Owner: MEDIUM and HIGH human | §3, G8 |
| Owner: Notion never starts automatically | G9, G10, S11 |
| Owner: idempotence and security kept | §5.3, §7 (unchanged rules, three new checks) |

------

## 13. 🛠️ Implementation notes (Prompt 43)

Where the implementation adjusts §3–§10, the stricter reading was kept (fail-closed):

| Point | Contract | Implemented | Why |
|---|---|---|---|
| G7 scope of `[recommended]` / `[assumption]` | acceptance criteria | **every** refined field (context, scope, out of scope, criteria, constraints, references, notes, SPEC references / changes, DoD, goal) | a recommended decision outside the criteria is still a decision nobody took (#58) |
| G5 cited items | ≥ 1 in the references, all exist | ≥ 1 in `spec_references`; every `F/R/S-nnn` cited in any refined field must head a `SPEC.md` heading | a criterion citing an unknown item is a missing reference |
| G9 comments | every human comment by the owner | **every** comment except FlowForge's own Refiner comment, all pages (bots included) | a bot comment (e.g. an earlier Developer stop) also means "not only the owner" |
| G9 logins | equal | case-insensitive (GitHub logins are) | — |
| Decision step | separate step *Decide autonomy* | inside *Validate and render refinement*, after validation, before rendering | the record line and comment depend on the decision |
| SPEC check (G3) | default branch | run in *Build Refiner prompt*, **before** the agent, as the step outputs `spec_check` / `spec_ids` | the agent cannot influence it |
| `gates` | booleans | `{result: PASS\|BLOCKED, code, detail}` per gate, `reasons` = blocked codes (G8 with its words), plus `would_auto_start` (all gates but G2) | traceable, and `SUPERVISED` can be evaluated before enabling `SEMI_AUTO` |
| `risk_level` / `risk_reasons` | schema v3 in the validator | required by the agent's JSON schema; **not** required by `flowforge_refine_validate` (missing or unknown ⇒ `D-RISK-UNKNOWN`) | an autonomy problem never fails a valid refinement (§8); older outputs stay valid |
| `SEMI_AUTO` without owner | Terraform `validation` | resource `precondition` (plan fails) | cross-variable validation needs Terraform ≥ 1.9; the module supports ≥ 1.6 |
| Publish re-check | before `agent:ready` | first read (before any write) **and** a fresh read right before the label; on `agent:manual` the body and comment are re-rendered and republished with `D-MANUAL` | the trace never claims a start that did not happen because of the opt-out |
| Workflow outputs | `autostart`, `base_branch` | also `autonomy_decision`, `effective_risk`, `autonomy_reasons` | report the decision to the caller |

Recovery after a failure **after** `agent:ready` was applied (label read-back failed, run
cancelled before `develop`): the Issue keeps `agent:ready`, nothing runs, and any re-run fails the
Refiner preconditions (no second refinement, no double start). A human removes and re-applies
`agent:ready` to start the Developer through `flowforge-agent.yml`, as for a lost label event.

### 13.1 Live validation plan (`demo-api`, next prompt)

From a temporary `demo-api` caller branch pinned to this branch's SHA, dispatched with
`gh workflow run flowforge-refine.yml --ref <branch>` and **explicit** inputs (no repository
variable, `demo-api` `main` and Terraform untouched, `demo-api-2` untouched), on dedicated Issues:

| Order | Scenario | Inputs | Expected | Developer may start |
|---|---|---|---|---|
| 1 | S1 | none (`SUPERVISED`) | `HUMAN_REQUIRED (D-MODE)`, `develop` skipped, body / comment as v0.1.0 | no |
| 2 | S4, S7, S13 | `SEMI_AUTO` + owner | `HUMAN_REQUIRED` with the expected codes | no |
| 3 | S12 | `SEMI_AUTO` + owner, Issue with `agent:manual` | `HUMAN_REQUIRED (D-MANUAL)` | no |
| 4 | S2 | `SEMI_AUTO` + owner, `test:` request | `AUTO_START`, `agent:ready` by `github-actions`, `develop` → Draft PR, merge human | **yes** |
| 5 | S10 | back to no input | `HUMAN_REQUIRED (D-MODE)` | no |

Two owner approvals, each asked separately: **A — Terraform**: the `demo-api` `plan` showing only
the additive `agent:manual` label, then the `apply` (needed before 3 and 4; without it every
decision is `D-MANUAL-MISSING`); **B — Developer**: before each run that can reach `AUTO_START`
(order 4), with the Issue, mode, expected risk and decision, and the workflows that may start
(`flowforge-refine.yml` jobs `refine`, `publish`, `develop` → `agent-develop.yml`). The temporary
branch is deleted afterwards; `SEMI_AUTO` is never left enabled on `demo-api`.

## 14. 🔁 Automatic review after an automatic start (Prompt 45)

The L3 run on `demo-api` #63 (run `40004574629`) delivered Draft PR #64, but no Reviewer ran:
`flowforge-review.yml` ignores PR events whose actor is a bot (#34), and the App opens the PR.
That guard stays. The review is chained **inside the same refine caller run**, like the
Developer: no event, no new workflow, agent or permission.

### 14.1 Mechanism

| Step | Where | What |
|---|---|---|
| Delivery reference | `agent-develop.yml`, step *Push branch and open Draft PR* then *Record delivery* (best-effort) | records the pushed commit, then outputs `head_sha` only if this run pushed **and** opened the PR, and the PR read back is `OPEN`, draft, at that commit; any doubt or read error → empty |
| Start | target caller job `review` | `needs: [refine, develop]`, `if: autostart == 'true' && develop.head_sha != '' && develop.pull_request != ''`, never `always()`: a failed or skipped Developer skips it |
| Delivery check | `agent-review.yml` *Resolve pull request context*, when `expected_head_sha` is set | PR on `expected_head_branch` and closing exactly `expected_issue_number`, else **fails** (nothing reviewed); head ≠ `expected_head_sha` or not draft → `NO_OP DELIVERY_CHANGED`; a FlowForge review comment (by `github-actions[bot]`, marker) of that commit → `NO_OP ALREADY_REVIEWED`; comment history unreadable → fails |
| Review | existing Reviewer, unchanged | SPEC.md, criteria, DoD, evidence, scope; one PR comment |
| Result | existing jobs | `APPROVE`: card *Review → Human validation*, PR stays Draft, merge human. `REQUEST_CHANGES` / `BLOCKED`: comment only, no Iterator (a human dispatches `flowforge-review-cycle.yml`). Technical failure: the run fails, the PR and `agent:review` stay, a human dispatches `flowforge-review.yml` |

Without `expected_head_sha` (manual dispatch, PR events from humans, the review cycle) nothing
changes: no check, a human can always review again.

### 14.2 Idempotence

| Case | Outcome |
|---|---|
| Re-run all jobs | Refiner preconditions refuse (`agent:review`): `develop` and `review` skipped |
| Re-run of `develop` | `agent-develop.yml` refuses (no `agent:ready`, branch exists): `review` skipped |
| Re-run of `review` after a verdict | `NO_OP ALREADY_REVIEWED` (same commit already reviewed, whatever the verdict) |
| Re-run of `review` after a technical failure | Reviews (no verdict was published) |
| Review already in progress | Per-PR concurrency group queues the second; it then finds the first verdict: `NO_OP ALREADY_REVIEWED` |
| PR reviewed by hand before | Same commit: `NO_OP ALREADY_REVIEWED`; new commit: `NO_OP DELIVERY_CHANGED` |
| PR closed / merged before | Existing `NO_OP` (`PR_ALREADY_CLOSED` / `PR_ALREADY_MERGED`) |
| PR number or commit not reliable | `head_sha` empty: `review` skipped, human path |

### 14.3 E2E protocol (not run in Prompt 45)

On a **new** LOW request, PR #64 untouched. Each live step needs the owner's go-ahead.

1. FlowForge PR merged → full merge SHA. `demo-api` branch `test/phase9-semi-auto-e2e`: add a
   `review` job identical to `examples/target-repository/flowforge-refine.yml` (gated also by
   `inputs.allow_develop`), the Reviewer `setup_uv` / `allowed_tools` of `demo-api`'s
   `flowforge-review.yml`, all three pins on the new SHA; actionlint; push the branch only.
2. New Issue by the owner, tests only, every decision written (lesson of #63: "Only `<file>` may be
   added or modified. No other repository file may change."), e.g. a test for `S-002`.
3. L1 `SUPERVISED`, `allow_develop=false`: only `D-MODE`, `would_auto_start: true`; else stop.
4. L3' `SEMI_AUTO`, `allow_develop=true`, dispatched once. Expected, in **one** run: G1–G12 PASS,
   `AUTO_START`, `develop` → Draft PR, `head_sha` set, `review` → verdict, card
   *Review → Human validation* on `APPROVE`.
5. Evidence: run id, jobs, `refinement.json`, Developer summary (*Delivered commit*), Reviewer
   artifact and comment (*Reviewed commit* = `head_sha`), label timeline, card, PR still Draft and
   unmerged, no second Developer / Reviewer run.
6. L4' "Re-run all jobs": refused, nothing new. Optional: re-run of the `review` job alone →
   `NO_OP ALREADY_REVIEWED`.
7. Stop conditions: any gate other than expected, `review` skipped with `head_sha` set, a second
   review, a write outside the PR comment, any change of `main` or the ruleset → stop, keep
   evidence, no recovery. Rollback: cancel the run, close the Draft PR without merging, remove a
   left `agent:*` label, delete the test branch at the end.

------

> **Document created on**: 2026-10-21
> **Author**: xgueret, with Claude Code
> **Version**: 0.4 (Prompt 45 automatic review, §14)
