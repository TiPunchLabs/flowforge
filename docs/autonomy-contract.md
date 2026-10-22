# 🎛️ FlowForge — Autonomy contract (v0.2.0)

> **Status**: **design only** (Phase 9, Prompt 42). Nothing described here is implemented: no
> workflow, agent, script, Terraform or target was changed. Implementation is Prompt 43 (§10).
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
                                        all gates PASS ──► agent:ready (GITHUB_TOKEN) ─► Developer,
                                                           started by the SAME run (caller job)
                                        any gate fails  ──► same as today: wait for a human

 The LLM proposes a risk level. The workflow can only RAISE it (keyword floor, SPEC impact),
 never lower it. READY is necessary, never sufficient. The merge is always human (ruleset).
```

> **Analogy**: the Refiner is the person who fills the work order; the autonomy check is the
> checklist at the counter. A complete, low-risk order goes straight to the workshop; anything
> unusual, incomplete or sensitive goes to the manager's desk — exactly where it goes today.

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
11. [Open questions for the owner](#11--open-questions-for-the-owner)

------

## 0. 📖 Analysis of v0.1.0 (what exists)

| Question | Answer in v0.1.0 | Where |
|---|---|---|
| Where is the human gate before development? | A human applies `agent:ready` on the refined Issue. Applying it also accepts every `[recommended]` item as a requirement | [issue-contract §4, §6](issue-contract.md#6--labels-and-states), [refiner §7.2](../agents/refiner.md#72-labels) |
| Who decides an Issue is `READY`? | The Refiner **agent** proposes the verdict; `flowforge_refine_validate` (`.github/scripts/flowforge-refine.sh`) rejects any output that breaks the checkable rules (no blocking question, required sections filled, every criterion tagged, `READY` never with `CONTRADICTS` / `NEEDS_DECISION`, references / contract changes / DoD present) | `agent-refine.yml` step *Validate and render refinement* |
| How is the Developer started? | `issues: labeled` with `agent:ready` in the target caller `flowforge-agent.yml` → `agent-develop.yml`. A label set with `GITHUB_TOKEN` starts nothing (GitHub rule); a label event sent by a bot is refused before any state change | `agent-develop.yml` step *Resolve issue context* |
| What stops an ambiguous or contradictory request? | Validator (above); Refiner `NEEDS_CLARIFICATION` → `agent:needs-clarification`; Ready definition R1–R9; SPEC gate `PASS` required before `agent:running`; the Developer stops (`agent:blocked`) on a contradiction it finds | `flowforge-refine.sh`, `flowforge-spec.sh`, `agents/developer.md` §4.1 |
| What does it NOT stop? | Implicit functional decisions inside a `READY`: on `demo-api` #58 the route path and the counting of completed tasks were **non-blocking** questions with defaults, and one contract change was conditional ("update section 1 only if needed"). A human accepted them with `agent:ready`. Without that human, they would be decided by nobody | [phase8-spec-refinement](milestones/phase8-spec-refinement.md) §3.2, §8 |
| Reusable mechanisms | `refinement.json` (structured, workflow-validated); the two-job Refiner (read-only agent / `issues: write` publish); `flowforge_set_state` (one state label, idempotent); the digest + precondition re-read in `publish`; `flowforge-spec.sh` local check; per-Issue concurrency groups; the Developer's precondition (Issue open, carries `agent:ready`, branch absent); reusable-workflow outputs; org/repo Actions variables; the Project sync events `refine-ready` → `develop-started` | — |

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
| Two modes, `SUPERVISED` (default, = v0.1.0) and `SEMI_AUTO` (explicit, per target) | An `AUTO` mode, automatic refinement on Issue opened, Notion-triggered starts |
| Start the Developer without a human **only** when every deterministic gate passes | Letting the LLM authorise anything on its own |
| Three risk levels `LOW` / `MEDIUM` / `HIGH`, HIGH always human | Path-level diff analysis, a policy engine, a permission system |
| Keep every existing protection: human merge, ruleset, iteration bound, one state label | Automatic review cycle start, auto-merge, marking PRs ready, deployment |
| A trace of every decision in the Issue and the run | A new component, dependency, label or secret |
| One-step return to `SUPERVISED` | Per-Issue overrides (see §11 Q4) |

------

## 2. 🔀 Autonomy modes

| Mode | Behaviour | Who enables it |
|---|---|---|
| `SUPERVISED` | **Identical to v0.1.0.** The Refiner publishes; `READY` leaves no state label; only a human applying `agent:ready` starts the Developer. The decision is still computed and recorded (`would AUTO_START` / `HUMAN_REQUIRED`) so that SEMI_AUTO can be evaluated before it is turned on | default |
| `SEMI_AUTO` | After a `READY`, the publish job applies `agent:ready` itself **when all gates of §4 pass**, and the same workflow run starts the Developer. Otherwise identical to `SUPERVISED` | target owner, explicitly |

### 2.1 Configuration

- One **repository** Actions variable on the target: `FLOWFORGE_AUTONOMY_MODE` = `SEMI_AUTO`.
  Repository level on purpose: autonomy is a per-project decision, and repository variables are
  only writable by repository administrators.
- The refine caller passes it as a new typed input of `agent-refine.yml`:
  `autonomy_mode: ${{ vars.FLOWFORGE_AUTONOMY_MODE || 'SUPERVISED' }}`.
- **Absent, empty or any other value ⇒ `SUPERVISED`** (exact, case-sensitive match on
  `SEMI_AUTO`; a different value adds a warning to the run summary). Fail-safe.
- An older caller that does not pass the input gets the input default `SUPERVISED`: upgrading
  FlowForge never turns autonomy on by itself.
- Must **not** be set at organization level (it would enable every target at once). The
  readiness checks get a dedicated row (§10, R19) and R12 ("no repository override") must allow
  this one variable.

> ⚠️ **Warning**: a target can only be `SEMI_AUTO` if its refine caller also has the `develop`
> job (§5.2). Setting the variable without it applies `agent:ready` but starts nothing; the
> Issue then waits like a human-ready Issue whose label event was lost (remove and re-apply the
> label). The updated caller template ships both together.

------

## 3. ⚖️ Risk classification

| Level | Examples | Behaviour in `SEMI_AUTO` |
|---|---|---|
| `LOW` | Tests only; documentation fixes; localised refactoring with no functional change (`spec_impact = COMPLIANT`) | Automatic start allowed |
| `MEDIUM` | New feature; API change; functional evolution the owner explicitly decided (`EXTENDS`, `NEW_FEATURE`) | Automatic start allowed **only if the contract is explicit** (§4, gate G9) |
| `HIGH` | Authentication / authorisation; secrets, tokens, permissions; infrastructure, Terraform; CI/CD workflows; deletion or migration of data; security changes | **Human validation always** |

### 3.1 How the level is computed

```text
proposed  = Refiner output `risk_level`            (LLM, may be wrong or manipulated)
floor     = max(impact_floor, keyword_floor)       (deterministic, bash + jq)
effective = max(proposed, floor)                   LOW < MEDIUM < HIGH; missing/unknown ⇒ HIGH
```

| Deterministic floor | Rule |
|---|---|
| `impact_floor` | `COMPLIANT` → `LOW`; `EXTENDS`, `NEW_FEATURE` → `MEDIUM`; `MODIFIES` → `HIGH` (sensitive change of the functional contract stays human, §5 of the prompt); anything else → not `READY`, not evaluated |
| `keyword_floor` | `HIGH` if a fixed list of word prefixes (case-insensitive, matched at a word start: `\b<term>`) matches the refined `title`, `goal`, `scope`, `acceptance_criteria`, `constraints`, `references`, `spec_changes`, `notes_for_agents` **or** the original request (English and French terms, path fragments): `authent`, `authoriz`, `autoris`, `login`, `password` / `mot de passe`, `token` / `jeton`, `secret`, `credential`, `permission`, `role`, `oauth`, `jwt`, `session`, `security` / `sécurité`, `crypt`, `tls`, `ssl`, `cve`, `vulnerab`, `terraform`, `.tf`, `infra`, `.github/`, `workflow`, `pipeline`, `ci/cd`, `deploy`, `docker`, `migration` / `migrat`, `delete` / `suppression`, `drop`, `truncate`, `purge`, `schema`, `database` / `base de données`. Otherwise `LOW` |

- The list lives in `flowforge-refine.sh` next to the validator, as one array, and is tested.
- It is deliberately coarse: a **false positive** costs one human click (the v0.1.0 path); a
  false negative is what the floor exists to reduce. Words matched are recorded (§5.4).
- The LLM can **raise** the level (it sees the code), never **lower** it below the floor.

> 💡 **Note**: the floor is a safety net, not a proof. A HIGH-risk change described in words the
> list does not contain, with a `LOW` proposal, would pass. Residual risk is bounded by what
> stays human — the Reviewer, the GitHub approval and the merge (§7) — and by the fact that a
> human with write access dispatched the Refiner on that Issue.

------

## 4. 🧮 Decision rules

The decision is computed by one function, `flowforge_autonomy_decide`, **after**
`flowforge_refine_validate` succeeded, from: `refinement.json`, the mode input, the local SPEC
check of the checked-out default branch, and the Issue JSON already read. No API call, no LLM.
Every gate is evaluated (no short-circuit) so the trace lists **all** failed gates.

| Gate | Condition to pass | Fails ⇒ | Reason code |
|---|---|---|---|
| G1 | `verdict == READY` | `NO_START` (Issue is `agent:needs-clarification` or unchanged when `BLOCKED`) | `D-VERDICT` |
| G2 | `mode == SEMI_AUTO` | `HUMAN_REQUIRED` | `D-MODE` |
| G3 | `spec_present` and `flowforge_spec_check SPEC.md` = `PASS` on the default branch | `HUMAN_REQUIRED` | `D-SPEC` |
| G4 | `spec_impact ∈ {COMPLIANT, EXTENDS, NEW_FEATURE}` (`MODIFIES` = contract change → human; `CONTRADICTS` / `NEEDS_DECISION` cannot be `READY`, G1) | `HUMAN_REQUIRED` | `D-IMPACT` |
| G5 | ≥ 1 cited `F-/R-/S-` identifier, and **every** cited identifier exists as a heading in `SPEC.md` | `HUMAN_REQUIRED` | `D-REFS` |
| G6 | `acceptance_criteria` and `definition_of_done` non-empty (already enforced for `READY`; re-checked, fail closed) | `NO_START` | `D-INCOMPLETE` |
| G7 | **Explicitness (#58 rule)**: `open_questions == []` (no non-blocking default either), `assumptions == []`, no `[recommended]` tag in `acceptance_criteria` nor `spec_changes` | `HUMAN_REQUIRED` | `D-IMPLICIT` |
| G8 | `effective` risk is `LOW` or `MEDIUM`; `proposed` is a known level | `HUMAN_REQUIRED` | `D-RISK-HIGH` / `D-RISK-UNKNOWN` |
| G9 | If `effective == MEDIUM`: `spec_impact ∈ {EXTENDS, NEW_FEATURE}` with `spec_changes` naming at least one new `S-xxx` scenario, or `COMPLIANT` | `HUMAN_REQUIRED` | `D-MEDIUM-CONTRACT` |
| G10 | Issue author is a `User` (not a `Bot`) with `author_association ∈ {OWNER, MEMBER, COLLABORATOR}` (from the Issue JSON; no extra call) | `HUMAN_REQUIRED` | `D-AUTHOR` |
| G11 | No error while evaluating G1–G10 | `HUMAN_REQUIRED` | `D-ERROR` |

**Result** — one of three values:

| Decision | Meaning | Labels after publish | Developer |
|---|---|---|---|
| `AUTO_START` | G1–G11 pass, mode `SEMI_AUTO` | `agent:ready` (set by the publish job, `GITHUB_TOKEN`) | started by the same run |
| `HUMAN_REQUIRED` | `READY`, but at least one of G2–G5, G7–G11 fails | none (as v0.1.0) | only after a human `agent:ready` |
| `NO_START` | Not `READY` (G1) or required data missing (G6) | `agent:needs-clarification`, or unchanged | none until a new refinement |

### 4.1 Required cases

| Case | Gates | Decision |
|---|---|---|
| Unknown classification | G8 `D-RISK-UNKNOWN` | `HUMAN_REQUIRED` |
| Ambiguous request | blocking question ⇒ `NEEDS_CLARIFICATION` (G1); non-blocking question or default ⇒ G7 | `NO_START` / `HUMAN_REQUIRED` |
| Contradiction with `SPEC.md` | `CONTRADICTS` is never `READY` (validator) | `NO_START` (blocked until arbitration) |
| Acceptance criteria missing | validator refuses `READY` (run `FAILED`), G6 re-checks | nothing published / `NO_START` |
| DoD missing | same | nothing published / `NO_START` |
| Risk `HIGH` | G8 | `HUMAN_REQUIRED` |
| Mode `SUPERVISED` | G2 | `HUMAN_REQUIRED` |
| `SEMI_AUTO` + `LOW` | all pass | `AUTO_START` |
| `SEMI_AUTO` + `MEDIUM`, explicit contract | G9 pass | `AUTO_START` |

### 4.2 Why `READY` is not enough (#58)

`READY` means "no **blocking** question". It allows non-blocking questions with defaults,
`[recommended]` criteria and assumptions — each one a decision a human silently accepts by
applying `agent:ready` ([issue-contract §4](issue-contract.md#4--provenance-tags)). Gate G7
removes that silent acceptance from the automatic path: an Issue starts on its own only when
every requirement is `[provided]` or `[observed]`, nothing is assumed and nothing is left to a
default. Everything else goes back to the v0.1.0 path, where a human accepts it. The rule is
mechanical (tags and array lengths in `refinement.json`), so it does not depend on the model
judging its own uncertainty.

------

## 5. 🚦 State transitions

### 5.1 Flows

```text
SUPERVISED
  human dispatch ─► Refiner ─► READY ─► decision HUMAN_REQUIRED (D-MODE) ─► no label
                                         ─► human applies agent:ready ─► flowforge-agent.yml ─► Developer

SEMI_AUTO, LOW / MEDIUM, all gates pass
  human dispatch ─► Refiner ─► READY ─► decision AUTO_START
                    publish: body + comment + agent:ready (GITHUB_TOKEN, triggers nothing)
                    caller job `develop` (needs: refine, if autostart) ─► agent-develop.yml ─► Developer

SEMI_AUTO, HIGH (or any other failed gate)
  human dispatch ─► Refiner ─► READY ─► decision HUMAN_REQUIRED (reasons) ─► no label
                                         ─► human applies agent:ready (as v0.1.0)

Contradiction / missing decision
  Refiner ─► NEEDS_CLARIFICATION (CONTRADICTS | NEEDS_DECISION) ─► agent:needs-clarification
         ─► human arbitration in a comment ─► human dispatches the Refiner again
         ─► READY + MODIFIES ─► HUMAN_REQUIRED (G4) ─► human agent:ready
```

Downstream of `agent:ready` nothing changes: `agent:running` → `agent:review` / `agent:blocked`
→ human merge → `agent:done` ([architecture §2.6](architecture.md#26-issue-label-lifecycle-phase-41)).
The review cycle stays `workflow_dispatch` (open decision, architecture §6).

### 5.2 Who does what

| Step | Component | Trigger | Token |
|---|---|---|---|
| Refinement | Refiner agent (read-only) | human `workflow_dispatch` of `flowforge-refine.yml` | read-only `GITHUB_TOKEN` + Claude |
| Risk proposal | Refiner agent (`risk_level`, `risk_reasons`) | same run | — |
| Decision | `flowforge_autonomy_decide`, refine job, after validation | same run | none (local data) |
| `agent:ready` | publish job, via `flowforge_set_state`, **last write**, only on `AUTO_START` | same run | `GITHUB_TOKEN` `issues: write` (already granted) |
| Developer start | target caller job `develop`: `needs: refine`, `if: needs.refine.outputs.autostart == 'true'`, `uses: agent-develop.yml@<SHA>` | same run | the permissions `flowforge-agent.yml` already grants to `develop` |
| Project card | existing events `refine-ready` then `develop-started` | same run | App token, Project only |

The refine job's permissions are unchanged (read-only, Claude token). The new `develop` caller
job gets **exactly** the permissions and secrets of `flowforge-agent.yml` — no permission is
created; it is the same job reached through a second door.

### 5.3 Idempotence and double starts

| Risk | Protection (existing unless marked new) |
|---|---|
| Two Refiner runs on the same Issue | `concurrency: flowforge-refine-<repo>-<issue>` serialises them; the second fails `flowforge_refine_preconditions` (Issue carries `agent:ready` / `agent:running`) before Claude runs |
| Run re-run ("Re-run all jobs") | Same precondition: an Issue with a state other than `agent:needs-clarification` is never refined again |
| Re-run of the `develop` job only | `agent-develop.yml` refuses an Issue without `agent:ready` and an existing `agent/<n>-*` branch; concurrency group per Issue |
| `agent:ready` set by the publish job fires `flowforge-agent.yml` | Impossible with `GITHUB_TOKEN`; **new test** asserts the publish job never uses the App token for labels |
| Human re-applies `agent:ready` during the automatic run | `labeled` only fires on add; a remove + add queues behind the same concurrency group, then fails on the existing branch / missing label |
| Issue edited between Refiner read and publish | Existing digest check: nothing published, no label, `autostart` not set |
| Label `agent:ready` missing on the repository | `flowforge_set_state` only warns; **new**: the publish job re-reads the Issue and sets `autostart=true` only if the label is really present |

`autostart` is set **only** by a successful publish job, after the label is verified; any earlier
failure leaves it empty, and the `develop` job is skipped.

### 5.4 Trace of the decision

| Where | Content |
|---|---|
| `refinement.json` (`schema_version: 3`) | new workflow-written object `autonomy` (§10.2) |
| Refinement record | one line per entry: `- Autonomy: SEMI_AUTO · risk MEDIUM (proposed LOW, floor MEDIUM: NEW_FEATURE) · AUTO_START` or `… · HUMAN_REQUIRED (D-IMPLICIT, D-RISK-HIGH: terraform)` |
| FlowForge Refiner comment | `AUTO_START`: "The Developer was started automatically (`SEMI_AUTO`). The merge stays human." `HUMAN_REQUIRED`: today's text plus the failed gates in plain words |
| Run summary | gates table (pass / fail, reason) |
| GitHub timeline | `github-actions` added `agent:ready`; the `develop` job in the same run |

The record states the **decision**; the label is the **effect**. If the label write failed, the
record says `AUTO_START` while the Issue has no label and no Developer ran — the run failure
explains it (§8).

------

## 6. 🧩 Component responsibilities

| Component | v0.2.0 responsibility | Never |
|---|---|---|
| Refiner agent | Refines; proposes `risk_level` + `risk_reasons` | Applies labels, decides the start, lowers the floor |
| `flowforge-refine.sh` | Validates (schema v3), computes floor and decision, renders the trace | Calls the network, reads Notion |
| `agent-refine.yml` refine job | Runs the local SPEC check and the decision; outputs it | Gets a write token |
| `agent-refine.yml` publish job | Publishes, then applies `agent:ready` on `AUTO_START`, verifies it, outputs `autostart` | Uses the App token for labels |
| Target `flowforge-refine.yml` | Passes the mode; holds the `develop` job | Any logic beyond `if:` on the output |
| `agent-develop.yml` | Unchanged: same preconditions, SPEC gate, delivery | Starts without `agent:ready` |
| Reviewer / Iterator / cycle / lifecycle | Unchanged; iteration bound `max_iterations = 3` kept | Merge, approve, mark ready |
| Ruleset (Terraform) | Unchanged: PR + ≥ 1 human approval, no force push, no FlowForge bypass | — |
| Human | Enables `SEMI_AUTO`; dispatches the Refiner; arbitrates; approves HIGH / MODIFIES / implicit; reviews, approves and merges | — |

------

## 7. 🔐 Security protections

- `SUPERVISED` by default; `SEMI_AUTO` only by an exact repository variable, written by a repo
  admin.
- The trigger stays a human `workflow_dispatch` on one Issue: in `SEMI_AUTO`, dispatching the
  Refiner is a conditional consent to develop that Issue.
- No start on missing data, invalid `SPEC.md`, open arbitration, contradiction, contract change
  (`MODIFIES`), implicit decision, `HIGH` or unknown risk, or bot / outside author.
- No permission widened: refine job read-only; publish job keeps `issues: write`; `develop` reuses
  the Developer's existing grant. No new secret, label, App permission or workflow.
- No implicit `SPEC.md` change: the Developer changes `SPEC.md` only as `spec_changes` lists
  (refiner §5.4), and G7 forbids `[recommended]` contract changes on the automatic path.
- Merge remains human: ruleset approval ≥ 1, author cannot approve its own PR, no FlowForge
  workflow submits a review, merges or enables auto-merge ([architecture §2.7](architecture.md#27-human-merge-gate-phase-41)).
- Prompt injection: Issue text can try to make the Refiner say `LOW`; it cannot remove a keyword
  floor, a `[recommended]` tag check, or the `MODIFIES` rule, which run in bash on the output.

### 7.1 Return to `SUPERVISED`

Delete the variable (`gh variable delete FLOWFORGE_AUTONOMY_MODE -R <target>`) or set it to
`SUPERVISED`. The next Refiner run computes `HUMAN_REQUIRED (D-MODE)`. Runs already started
are not affected: cancel them in Actions if needed. No caller change is required to go back.

### 7.2 Limits accepted for the POC

| Limit | Why acceptable |
|---|---|
| Keyword floor can miss a sensitive change | Human review + approval + merge remain; false positives only cost the v0.1.0 path |
| Requester comments (answers) can come from anyone who can comment | They feed the Refiner as untrusted data; G7 / G4 / floor still apply; a public target may prefer G10 tightened to `OWNER` (§11 Q3) |
| Notion-submitted Issues (Bridge App author) never auto-start (G10) | Conservative by design (§11 Q2) |
| Caller duplication: `develop` inputs (`setup_uv`, `allowed_tools`) repeated in two callers | Thin callers, no logic; checked by R13 |

------

## 8. 🔧 Error handling

| Failure | Effect | Developer |
|---|---|---|
| Error inside the decision (jq, missing field, SPEC read) | `HUMAN_REQUIRED (D-ERROR)`, `READY` still published — falls back to v0.1.0 | no |
| SPEC check `FAILED` / `ERROR` | `HUMAN_REQUIRED (D-SPEC)`; the Developer gate would refuse anyway | no |
| Validator rejects the output | run fails, nothing published (as today) | no |
| Publish fails before the label (digest, API) | run fails, `autostart` empty, `develop` skipped | no |
| Label write fails or label absent after write | publish fails / `autostart` not set | no |
| `develop` fails at preconditions or SPEC gate | Issue keeps `agent:ready` (as today); human fixes and re-applies | no |
| `develop` fails after start | existing Developer handling (`agent:blocked` / no state) | stopped |
| Project sync error | warning only (best-effort, unchanged) | unaffected |

Rule: **every error before the label is fail-closed to `SUPERVISED` behaviour**; after the label,
the Developer's existing error handling applies.

------

## 9. 🧪 Validation scenarios

Offline scenarios run in `tests/refiner.sh` (fixtures of `refinement.json` + Issue JSON + a
`SPEC.md`), live ones on `demo-api` (reference project) through a temporary caller branch
pinned to the feature branch, as in Prompt 38.

| # | Setup | Expected | Evidence |
|---|---|---|---|
| S1 | `SUPERVISED`, LOW, explicit `READY` | `HUMAN_REQUIRED (D-MODE)`, no label, `develop` skipped | test assertion; live: `autonomy.decision`, record line, run graph shows `develop` skipped |
| S2 | `SEMI_AUTO`, `COMPLIANT`, LOW, no question / assumption / `[recommended]` | `AUTO_START`; `agent:ready` by `github-actions`; `develop` runs → Draft PR | record line; timeline label event; same run id holds `develop`; card Ready → Developing; PR still Draft, unmerged |
| S3 | `SEMI_AUTO`, `NEW_FEATURE`, MEDIUM, `spec_changes` with a new `S-xxx`, all `[provided]` | `AUTO_START` | as S2, plus PR updates `SPEC.md` exactly as listed |
| S4 | `SEMI_AUTO`, request mentions a token / Terraform / workflow, proposal `LOW` | `HUMAN_REQUIRED (D-RISK-HIGH: <word>)` | floor words in `autonomy.risk_floor_reasons`; no label |
| S5 | `SEMI_AUTO`, contradicts a `CONFIRMED` `R-xxx` | `NEEDS_CLARIFICATION`, `NO_START`, `agent:needs-clarification` | validator still refuses a forged `READY` + `CONTRADICTS` (test) |
| S6 | `SEMI_AUTO`, `NEEDS_DECISION`; then answer → `MODIFIES` | `NO_START`, then `HUMAN_REQUIRED (D-IMPACT)` | two record entries; never `AUTO_START` |
| S7 | `SEMI_AUTO`, incomplete data: non-blocking question, `[recommended]` criterion, assumption, unknown cited `R-999`, `risk_level` missing | `HUMAN_REQUIRED` with `D-IMPLICIT` / `D-REFS` / `D-RISK-UNKNOWN`; missing AC / DoD → validator `FAILED` | one test per gate; all reasons listed together |
| S8 | Same Issue dispatched twice; run re-run; `develop` re-run | one branch, one Draft PR, one Developer run that writes | second run fails preconditions before Claude; `agent-develop` refuses (branch exists / no label) |
| S9 | Decision error; label write error; Issue edited during run | no `agent:ready`, `develop` skipped | `D-ERROR` in record, or failed publish + empty `autostart` (test with `gh` stub) |
| S10 | S2 setup, then variable deleted, Refiner on a new Issue | `HUMAN_REQUIRED (D-MODE)` | record line; `develop` skipped |

Static checks (offline): publish job never uses the App token for `agent:ready`; `develop` caller
job grants exactly the Developer's permissions; `autonomy_mode` input default `SUPERVISED`;
`actionlint` clean.

------

## 10. 🛠️ Minimal implementation plan (Prompt 43)

### 10.1 Changes

| # | File | Change |
|---|---|---|
| 1 | `agents/refiner.md` | §5.5 *Risk proposal*: `risk_level` (`LOW` / `MEDIUM` / `HIGH`, HIGH when unsure) and `risk_reasons`; the proposal authorises nothing |
| 2 | `docs/issue-contract.md` | §5: `READY` ≠ start authorisation; §6: `agent:ready` set by a human, or by the Refiner **workflow** on `AUTO_START`; §7: record line *Autonomy* |
| 3 | `.github/scripts/flowforge-refine.sh` | schema v3 in the validator (`risk_level`, `risk_reasons`); `FLOWFORGE_RISK_KEYWORDS`; `flowforge_autonomy_decide`; record line and comment text |
| 4 | `.github/workflows/agent-refine.yml` | input `autonomy_mode` (default `SUPERVISED`); JSON schema fields; step *Decide autonomy* (local `flowforge_spec_check`, decide, `autonomy` in `refinement.json`); publish: label last + verify; outputs `autostart`, `base_branch` |
| 5 | `examples/target-repository/flowforge-refine.yml` | pass `autonomy_mode`; add job `develop` (`needs: refine`, `if:` on `autostart`, same `with` / `permissions` / `secrets` as `flowforge-agent.yml`) |
| 6 | `tests/refiner.sh` | S1–S10 offline + static checks |
| 7 | Docs | `docs/architecture.md` §2.14 + §5.8 (schema v3); `docs/target-onboarding.md` (variable, caller table, R12 exception, **R19** "`FLOWFORGE_AUTONOMY_MODE` is repository-level only and matches the owner's choice"); this document's status |

`agent-develop.yml`, Reviewer, Iterator, cycle, lifecycle, Terraform, Notion: **unchanged**.

### 10.2 `refinement.json` v3 additions

```json
{
  "schema_version": 3,
  "risk_level": "LOW",
  "risk_reasons": ["tests only, no behaviour change `[observed]`"],
  "autonomy": {
    "mode": "SEMI_AUTO",
    "proposed_risk": "LOW",
    "risk_floor": "LOW",
    "risk_floor_reasons": [],
    "effective_risk": "LOW",
    "spec_check": "PASS",
    "gates": {"G1": true, "G2": true, "G3": true, "G4": true, "G5": true, "G6": true,
              "G7": true, "G8": true, "G9": true, "G10": true, "G11": true},
    "reasons": [],
    "decision": "AUTO_START"
  }
}
```

`risk_level` / `risk_reasons` come from the agent; `autonomy` is written by the workflow only,
like the fields before `verdict` (architecture §5.8).

### 10.3 Order and live validation

1. Script + tests (offline, S1–S10). 2. Workflow + caller template. 3. Docs. 4. Live on `demo-api`
from the feature branch: S1 (variable unset), then S2 / S4 / S7 with the variable set, then S10.
`demo-api-2` stays `SUPERVISED`. 5. Tag `v0.2.0` after merge, on the maintainer's go-ahead.

------

## 11. ❓ Open questions for the owner

| # | Question | Proposed default |
|---|---|---|
| Q1 | Should the mode variable be managed by Terraform (`github_actions_variable`, non-secret) in the `target-repository` module, or set by hand? | By hand (`gh variable set`) in v0.2.0; Terraform later if more than two targets use it |
| Q2 | Notion-submitted Issues (Bridge author): always human (G10), or trusted like members? | Always human |
| Q3 | G10: accept `MEMBER` / `COLLABORATOR` authors, or `OWNER` only? | `OWNER`, `MEMBER`, `COLLABORATOR` |
| Q4 | Per-Issue opt-out (e.g. a human label `agent:manual`)? Needs a new label (Terraform) | Not in v0.2.0: don't dispatch the Refiner, or switch the mode |
| Q5 | Allow `MEDIUM` in `SEMI_AUTO` by default, or require a second switch (e.g. `SEMI_AUTO_LOW`)? | Allowed under G9 |
| Q6 | Is the keyword list right for the targets' languages (English + French)? | Yes; extend from live false negatives |

------

> **Document created on**: 2026-10-21
> **Author**: xgueret, with Claude Code
> **Version**: 0.1 (design, Phase 9 — Prompt 42)
