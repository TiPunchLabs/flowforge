# 🔄 FlowForge — GitHub Project synchronisation

> **Status**: implemented (Phase 6, Prompt 28, 2026-10-12). The FlowForge workflows write the
> `Status` and `Attention` of the Issue's card in [`FlowForge Development` #1](https://github.com/orgs/TiPunchLabs/projects/1).
> **One way only**: no card move ever starts an agent. Full E2E on a real agent cycle: Prompt 29.
>
> **Prerequisites**: [kanban-model.md](kanban-model.md) (statuses, transitions, events E1–E22),
> [provisioning.md](provisioning.md) (Project, IDs, App permission),
> [architecture.md §2.10](../architecture.md#210-delivery-identity-flowforge-github-app-issue-34) (FlowForge App).
>
> **Unchanged by this document**: agents and their rules, state labels and their guards,
> Reviewer workflow, review-cycle bound, human merge gate.

------

## 🧠 Mental Model

```text
  real FlowForge event (job start, verdict, delivery, merge)
        │
        ├──► state label            flowforge-state.sh     (unchanged: triggers + guards)
        │
        └──► Project sync step       flowforge-project.sh   (new, best-effort)
                 │  1. Issue node id      ← GITHUB_TOKEN (repository + number)
                 │  2. find-or-add item   ← App token, organization projects: write
                 │  3. decide             ← event table + stale guard (pure, no API)
                 │  4. write Status / Attention (only what differs)
                 ▼
          GitHub Project card           (visual source of truth, read by humans only)

  card moved by a human ──► nothing          (no Project event is a workflow trigger)
```

| Layer | Source of truth of | Written by |
|---|---|---|
| Actions runs, `*.json` results | execution | workflows |
| `agent:*` labels | what may run next | `flowforge-state.sh` (+ `agent:ready` by a human) |
| Project `Status` / `Attention` | where the need is, does a human have to act | `flowforge-project.sh`, humans for human-owned moves |

------

## 📑 Table of contents

1. [Architecture](#1--architecture)
2. [Event mapping](#2--event-mapping)
3. [State machine and stale guard](#3--state-machine-and-stale-guard)
4. [Configuration and opt-in](#4--configuration-and-opt-in)
5. [Authentication and permissions](#5--authentication-and-permissions)
6. [Errors](#6--errors)
7. [Idempotence](#7--idempotence)
8. [Human moves and backward transitions](#8--human-moves-and-backward-transitions)
9. [Tests](#9--tests)
10. [Limitations](#10--limitations)

------

## 1. 🏗️ Architecture

**One helper, sourced like the state helper.** `.github/scripts/flowforge-project.sh` is fetched
by each reusable workflow at `job.workflow_sha` (as `flowforge-state.sh`), so the helper, the
event table and the IDs file always match the workflow version. A composite action is not
usable here: `uses:` cannot be pinned to the called workflow's commit.

| Function | Role |
|---|---|
| `flowforge_project_decide <event> <status> <attention> [force]` | Pure decision (jq), no API: `update`, `unchanged`, `refused`, `skipped` |
| `flowforge_project_sync <issue> <event>` | Resolve the Issue, find-or-add the item, decide, write, log. Never fails the caller |

The conceptual `set_project_status(repository, issue, status)` takes an **event** rather than a
status: the event determines which source statuses are legitimate (§3), and the repository is
always the calling one (`GITHUB_REPOSITORY`).

**Where each sync runs** (one token step + one sync step per hook point; before Claude, also a revoke step):

| Workflow | Job | Step(s) | Events |
|---|---|---|---|
| `agent-refine.yml` | `refine` | after *Resolve Issue context*, before checkout and Claude | `refine-started` |
| | `refine` | `if: failure()` (after the start) | `refine-failed` |
| | `publish` | after *Apply refinement* (`always()`) | `refine-ready`, `refine-needs-clarification`, `refine-blocked`, `refine-failed` |
| `agent-develop.yml` | `develop` | after *Mark issue as running*, before checkout and Claude | `develop-started` |
| | `develop` | after *Enforce Draft PR and set final label* (`always()`) | `develop-delivered`, `develop-stopped`, `develop-failed` |
| `agent-iterate.yml` | `iterate` | after the preconditions (PR open), before checkout and Claude | `iterate-started` |
| | `publish` | after *Render iteration result*, only for a delivered `COMPLETED` / `PARTIAL` | `iterate-completed` |
| `review-cycle.yml` | `project_start` (needs `check`, next to Reviewer #1) | — | `cycle-started` |
| | `project_status` (needs `summary`) | — | `cycle-approved`, `cycle-blocked`, `cycle-max-iterations`, `cycle-failed` |
| `agent-lifecycle.yml` | `terminal_state` | after *Apply terminal state* | `pr-merged`, `pr-closed` |
| `agent-review.yml` (stand-alone) | `project_status` (needs `review` + `publish`, `APPROVE` only) | — | `review-approved` |

A stand-alone review moves the card on `APPROVE` only (Prompt 38.1, A4): `Review → Human
validation`, after its comment is published. `REQUEST_CHANGES` and `BLOCKED` change no status
and no label: the cycle, or a human, decides what follows. The App key reaches only the
`project_status` job, never the `review` job that runs Claude on the PR code. `review-cycle.yml`
passes no `project_number` to its Reviewers, so inside a cycle only its own `project_status`
job writes the result. Both use `flowforge_project_sync_pr` (PR still open, exactly one
closing Issue).

**Which Issue.** Always resolved by GitHub, never parsed from text, with the same guards as the
labels: the Developer's and Refiner's own Issue; for PR events, the single Issue of the calling
repository closed by the PR (`flowforge_pr_issue`), and only while the PR is open (a merge or
close belongs to the lifecycle workflow); for the lifecycle, only the Issue whose label was just
moved; for the Iterator result, the Issue written in `iteration.json` by the workflow. The Issue
node id comes from `repos/<calling repository>/issues/<n>`, so `demo-api#3` can never touch
`other#3`; a pull request number is refused.

------

## 2. 🔀 Event mapping

The real mapping (model §7, §11). "From" lists the allowed sources; *(none)* = Issue not on the
board yet (added by this event) or without a Status.

| # | FlowForge event | Event id | From | To | `Attention` |
|---|---|---|---|---|---|
| E1 | Issue added by a maintainer | `issue-added` (CLI only) | *(none)* | Backlog | empty |
| E2 | Refiner job started (preconditions passed) | `refine-started` | *(none)*, Backlog, Ready (B6), Refining (re-run) | Refining | empty |
| E3 | Refiner `READY` published | `refine-ready` | Refining | Ready | empty |
| E4 | Refiner `NEEDS_CLARIFICATION` published | `refine-needs-clarification` | Refining | Backlog | `Needs clarification` |
| E5 | Refiner `BLOCKED` published | `refine-blocked` | Refining | Backlog | `Blocked` |
| E6 | Refiner technical failure | `refine-failed` | Refining | *(kept)* | `Failed` |
| E7 | Developer started (`agent:running` set) | `develop-started` | *(none)*, Backlog, Ready, Developing (re-run) | Developing | empty |
| E8 | Draft PR delivered (`agent:review`) | `develop-delivered` | Developing | Review | empty |
| E9 | Developer stopped, no PR (`agent:blocked`) | `develop-stopped` | Developing | Backlog | `Blocked` |
| E10 | Developer technical failure, no PR | `develop-failed` | Developing | *(kept)* | `Failed` |
| E11 | Review cycle started | `cycle-started` | Review, Iteration, Human validation (B1) | Review | empty |
| E12 | Iterator #k started (`REQUEST_CHANGES`, budget left) | `iterate-started` | Review | Iteration | empty |
| E13 | Iterator `COMPLETED` / `PARTIAL` pushed | `iterate-completed` | Iteration | Review | empty |
| E14 | Cycle `APPROVED` | `cycle-approved` | Review | Human validation | empty |
| E14b | Stand-alone Reviewer `APPROVE` (comment published) | `review-approved` | Review | Human validation | empty |
| E15 | Cycle `BLOCKED` (Reviewer or Iterator) | `cycle-blocked` | Review, Iteration | Human validation | `Blocked` |
| E16 | Cycle `MAX_ITERATIONS_REACHED` | `cycle-max-iterations` | Review | Human validation | `Max iterations` |
| E17 | Cycle `FAILED` | `cycle-failed` | Review, Iteration | *(kept)* | `Failed` |
| E18 | Cycle `NO_OP` | — | — | *(nothing written)* | — |
| E19 | PR merged by a human (`agent:done`) | `pr-merged` | Human validation | Done | empty |
| E20 | PR closed unmerged (no state label) | `pr-closed` | Review, Iteration, Human validation | Backlog | empty |
| E21 | Issue closed by a human (completed / not planned) | — | — | **manual** (§8) | — |
| E22 | Issue reopened | — | — | **manual** (§8) | — |

`BLOCKED` follows model §3.2: **with a PR the decision is about the PR → `Human validation`;
without a PR it is about the need → `Backlog`**, with `Attention = Blocked`. No `Blocked`
column exists. `APPROVE` is never `Done`: only the human merge (E19) is.

**Backlog (§4 of the brief).** Decided on 2026-10-12: Issues are **not** added on creation.
An Issue enters the board at its first FlowForge event (Refiner or Developer start; the
item is created and placed directly in that event's status), or by hand (UI, or
`sync-issue.sh <repo> <n> issue-added`). This keeps Issues never handed to FlowForge off the
board and adds no `issues` trigger to the targets. Built-in *Auto-add* stays off (provisioning §4).

------

## 3. 🚦 State machine and stale guard

Decision rule of `flowforge_project_decide` (decided on 2026-10-12, refines model §7.2
*Enforcement*):

| Current card | Event target | Decision |
|---|---|---|
| in the event's allowed sources | any | **update** |
| already the target status (and Attention) | same | **unchanged** — no write |
| already the target status, Attention differs | same | **update** (Attention only) |
| unexpected source, target **ahead** in the flow | — | **update** + warning note: a missed event is caught up, execution wins |
| unexpected source, target **behind** or same rank | — | **refused** + warning: stale event, card untouched |
| not a FlowForge status (renamed option…) | — | **refused** |
| status-keeping event (`*-failed`) on a card elsewhere | — | **skipped** — Attention left as is |

Flow ranks: *(none)* 0 · Backlog 1 · Refining 2 · Ready 3 · Developing 4 · Review = Iteration 5 ·
Human validation 6 · Done 7. Legitimate backward moves (B1, B2, B3, B6, T4, T7) are listed as
allowed sources, so they never hit the guard.

```text
  Issue in Review, a late Refiner READY arrives      → refused  (stale: Review is ahead of Ready)
  Issue in Review, PR merged (cycle never run)       → Done     (warning: unexpected source, caught up)
  Issue in Developing, Developer started again       → unchanged (Attention Failed cleared)
  Issue in Done, anything but a reopen               → refused  (Done is the highest rank)
```

**Bypass.** Only the maintainer CLI: `scripts/github-projects/sync-issue.sh <repo> <n> <event> --force`
(`FLOWFORGE_PROJECT_FORCE=1`). Workflows never force.

**Races.** Read-then-write without a lock. Writers of one Issue are already serialised by the
workflows' concurrency groups (one Developer, one Refiner per Issue, one cycle per PR), and the
stale guard rejects the remaining late writes that would move a card backwards.

------

## 4. 📝 Configuration and opt-in

| Value | Where | Notes |
|---|---|---|
| Project ID, field IDs, option IDs | [`config/github-project.json`](../../config/github-project.json) | Generated by `bootstrap.sh`, versioned, fetched at `job.workflow_sha`. No ID in any workflow (tested) |
| Project number (opt-in) | organization variable **`FLOWFORGE_PROJECT_NUMBER`** = `1` — created on 2026-10-12, visible to `demo-api` only (enabling step 1 below) | Callers pass `project_number: ${{ fromJSON(vars.FLOWFORGE_PROJECT_NUMBER \|\| '0') }}`; unset = `0` = sync off |
| App client id | organization variable `FLOWFORGE_APP_CLIENT_ID` (exists) | |
| App private key | organization secret `FLOWFORGE_APP_PRIVATE_KEY` (exists) | |

The helper refuses (warning) when `project_number` differs from the number in the IDs file: a
caller can never write to another Project with these IDs. Status and Attention option IDs are
looked up by name in the IDs file; the event table lives in the helper and is checked against
the IDs file by the tests.

**New reusable workflow inputs** (all optional, default off — existing callers are unaffected):

| Workflow | New inputs / secrets |
|---|---|
| `agent-develop.yml`, `review-cycle.yml` | `project_number` |
| `agent-iterate.yml` | `project_number` (set by `review-cycle.yml` only) |
| `agent-refine.yml`, `agent-lifecycle.yml` | `project_number`, `app_client_id`, secret `app_private_key` |

**Enabling it on a target** (once per target):

1. Organization variable `FLOWFORGE_PROJECT_NUMBER = 1`, visible to the target (*Selected repositories*): add the target to its repository list (exists since 2026-10-12; `demo-api` done).
2. Give the target's existing App variable/secret visibility (already the case for `demo-api`).
3. Copy the updated callers from `examples/target-repository/` (`flowforge-agent.yml`,
   `flowforge-refine.yml`, `flowforge-review-cycle.yml`, `flowforge-lifecycle.yml`).

------

## 5. 🔐 Authentication and permissions

```text
  Claude Code authentication     → Anthropic   CLAUDE_CODE_OAUTH_TOKEN   (agent steps only; unchanged)
  Issue / PR reads for the sync  → GitHub      GITHUB_TOKEN              (job permissions, unchanged scope)
  GitHub Projects writes         → GitHub      FlowForge App token       (organization projects: write ONLY)
```

| Credential | Permission requested | Lifetime | Never |
|---|---|---|---|
| Project token (`actions/create-github-app-token`, `permission-organization-projects: write`) | organization projects: write; repository scope = calling repository (default); no `contents`, `issues`, `pull-requests` | minted just before the sync. **Before Claude**: `skip-token-revoke: true` + step *Revoke Project token* (`if: always()`, `DELETE /installation/token`) right after the sync. **Elsewhere**: revoked by the action's post step at job end | given to Claude; used for labels, code or PRs |
| `GITHUB_TOKEN` | unchanged, except `issues: read` added to `agent-iterate.yml` `publish` (resolve the Issue node id) | job | used to write the Project (it cannot) |
| `CLAUDE_CODE_OAUTH_TOKEN` | — | — | used for anything GitHub |

- **Token dead before Claude.** In the three jobs that run Claude (`refine`, `develop`,
  `iterate`): token → start sync → *Revoke Project token* (`always()`, so even a failed sync
  cannot leave it alive) → checkout and agent; no Project token is minted between the revoke and
  Claude (tested). After Claude, a new token is minted for the result sync, like the delivery
  token (architecture §2.10), and the action revokes it at job end.
- **Anti-loop rule unchanged.** The App still has no `issues` permission (installation:
  `contents`, `metadata`, `organization_projects`, `pull_requests`), so it can never apply
  `agent:ready`; and no Project event can trigger a workflow.
- **Logs.** One line per sync: repository, Issue, reason, previous → new Status and Attention,
  decision and note. No payload, no token (masked by the action, never echoed; tested).

> ⚠️ **Warning — private targets.** The Project token is not given `issues: read`. Adding an
> Issue of a **public** repository (`demo-api`, `flowforge`) works with organization projects
> alone. For a **private** target, check on the first run that `addProjectV2ItemById` succeeds;
> if GitHub requires read access to the Issue, add `permission-issues: read` to the Project
> token steps (it still cannot write labels).

------

## 6. 🔧 Errors

**Policy: visible, auditable, never blocking.** A Project problem never fails or changes an agent
run whose work is delivered (model §6.3, §8).

| Situation | Effect on the run | Effect on the card | Where it is visible |
|---|---|---|---|
| Sync fails (API error, Issue unreadable, item not returned, option missing, IDs file unreadable) | none: helper returns 0, steps are `continue-on-error: true` | unchanged, or partially updated (said so, §6.1) | `::warning::Project sync <repo>#<n> [<event>] failed: <operation> — GitHub: <reason>. …` annotation + `⚠️` line in the job summary (§6.1) |
| No Project token (App not configured, token creation failed) | none | unchanged | warning `no Project token …` |
| `project_number` ≠ IDs file | none | unchanged | warning `does not match the IDs file` |
| Stale event refused / failure event skipped | none | unchanged | warning with the reason |
| Agent technical failure | as today (labels unchanged) | stays, `Attention = Failed` | card + run |
| The run dies before its sync step | as today | unchanged (stale until the next event) | Actions only (model §8 accepts it) |

Every successful sync also writes one line in the job summary, so a run's summary shows the
card transitions it caused.

### 6.1 Failure message format (#44)

Every technical failure produces **one** line, the same in the warning annotation and the job
summary:

```text
Project sync <owner/repo>#<issue> [<event>] failed: <operation> — GitHub: <reason>. <card>; the agent run is not affected.
```

| Part | Content |
|---|---|
| `<operation>` | what the helper was doing, with the transition when it writes: `could not add or read the Project item`, `could not set Status Review → Iteration`, `could not set Attention (none) → Blocked`, `Issue #45 not readable in …`, `no Project token …`, `project_number '…' does not match the IDs file …` |
| `<reason>` | what `gh` (or `jq`) printed: the `gh: ` prefix dropped; a GraphQL JSON body becomes `TYPE: message` per error; several lines joined with ` \| ` in order. Omitted (with `— GitHub:`) when `gh` printed nothing |
| `<card>` | `The card is unchanged`, or `The card is partially updated (Status A → B)` when the Status write succeeded and the Attention write failed |
| fallback | `failed: Unknown GitHub Project sync error.` when nothing at all was printed |

Examples (observed live with the real `gh`, 2026-10-12, harmless bogus IDs):

```text
… [cycle-approved] failed: could not add or read the Project item — GitHub: Could not resolve to a node with the global id of 'PVT_kwDOinvalid000'. The card is unchanged; the agent run is not affected.
… [cycle-blocked] failed: could not set Attention (none) → Blocked — GitHub: Could not resolve to a node with the global id of 'PVTSSF_invalidField0'. The card is unchanged; the agent run is not affected.
```

**How it works.** The helper tags its own messages on stderr (`flowforge: <operation>`,
`flowforge-partial: <write>`); everything else on stderr is the tool's output. The wrapper
(`_flowforge_project_failure`) separates the two instead of keeping the last stderr line (the
cause of #44: `gh` prints GitHub's reason first, the helper's line came last and was the only one
kept).

**Size limits.** At most 5 lines from `gh`, 300 characters per line, 800 for the whole reason;
a cut is marked with `…` (a 6th line becomes ` | …`).

**Sanitization, in the helper itself** (GitHub Actions masking stays on as a second layer):
the exact values of `PROJECT_TOKEN` and `GH_TOKEN` (8 characters or more), GitHub tokens
(`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`), Claude tokens (`sk-ant-`), JWTs (`eyJ….….…`, e.g. an
App JWT), `Authorization: …`, `Bearer …`, `token=` / `token:` values and private key headers are
replaced by `[REDACTED]`, **before** the size limits apply. The helper never runs `set -x`, and
only stderr of the failing calls is read: no request, header or environment is printed.

**Unchanged by #44**: the decision table, the transitions, `update` / `unchanged` / `refused` /
`skipped` lines (exact same text), and the policy: warning + exit 0 in workflows, exit 1 only in
strict mode (`FLOWFORGE_PROJECT_STRICT=1`, the maintainer CLI).

------

## 7. ♻️ Idempotence

| Replay | Result |
|---|---|
| Add an Issue already on the board | `addProjectV2ItemById` returns the existing item: still one item |
| Same event twice (`set Ready` twice, `set Review` twice) | second decision `unchanged`: no write call at all |
| Event whose status is already shown, Attention differs | only `Attention` is written |
| Re-run after `Failed` | same status, `Attention` cleared |

Only the fields that differ are written; clearing `Attention` uses
`clearProjectV2ItemFieldValue`.

------

## 8. 👤 Human moves and backward transitions

| Case | Handled by | Behaviour |
|---|---|---|
| B1 Human validation → Review (human re-dispatches the cycle) | `review-cycle.yml` `project_start` | automatic |
| B2 Review / Iteration / Human validation → Backlog (PR closed unmerged) | `agent-lifecycle.yml` | automatic |
| B3 Backlog (*Needs clarification*) → Refining (Refiner re-run) | `agent-refine.yml` | automatic, Attention cleared |
| B6 Ready → Refining (Refiner re-run before `agent:ready`) | `agent-refine.yml` | automatic |
| B4 Ready → Backlog (human withdraws a not-started Issue) | human | manual card move; the next FlowForge event (`develop-started` from Backlog) is allowed |
| B5 Done → Backlog (Issue reopened), E21 Issue closed (completed → Done, not planned → archive) | human | **manual**: no workflow listens to `issues` events (decision 2026-10-12) |
| "Human asks changes" on a PR in Human validation | human re-dispatches the cycle | B1 |
| Clear `Attention` after deciding | human | visual only; also cleared by the next event |
| Any other card move | human | **visual only, starts nothing**; the next event overwrites it if it is ahead, or is refused if the human moved the card further (repair with `sync-issue.sh … --force`) |

**Project → workflow does not exist.** Project item events (`projects_v2_item`) are
organization webhooks, not Actions triggers; no FlowForge workflow or caller listens to a
Project event (tested statically). Moving `Ready → Developing` does not start the Developer;
moving `Review → Iteration` does not start the Iterator. The only human go stays the label
`agent:ready`.

------

## 9. 🧪 Tests

**Unit and workflow-step tests** — `tests/project-sync.sh`, pre-commit hook `project-sync`, no network:

| Part | Covers |
|---|---|
| A — decision table | every event from its allowed sources; failure events; replays (`unchanged`); stale refusals (12 cases); missed-event catch-up; force; unknown event; unknown status; event table ⊆ IDs file |
| B — GraphQL layer (stub `gh`) | absent Issue added once and set; replay = one item, no second write; full flow Backlog → Done on one item; Attention set/cleared; stale refused without write; force; same number in another repository untouched; Issue read with `GITHUB_TOKEN` and Project calls with the Project token only; PR number refused; errors (no token, wrong number, API failure, unreadable Issue) = warning + summary, exit 0; strict mode; no token in logs |
| E — error observability (#44) | regression: GitHub's reason kept next to the helper's operation (the old `tail -n 1` dropped it); multi-line kept in order; GraphQL JSON `errors[]` → `TYPE: message`; secrets redacted (exact token value, `ghs_`, `github_pat_`, `sk-ant-`, JWT, `Authorization: Bearer`, `token=`); `gh` silent → operation only; nothing at all → `Unknown GitHub Project sync error`; 5-line / 800-character limits with `…`; Status transition named; partial update reported; strict mode exit 1; `update` / `unchanged` / `refused` lines unchanged |
| C — real workflow steps | event chosen from each workflow's outcome (Developer, Refiner, Iterator, cycle, lifecycle); cycle guards (PR merged, 0 or 2 linked Issues); helper and IDs fetched at the pinned commit; token revoke step deletes its token |
| D — static invariants | `project_number` opt-in default 0 everywhere; Project tokens = organization projects only; only start tokens skip the action's revoke; every Project step `continue-on-error`; token → sync → revoke (`always()`) → Claude, no token minted in between; no Project trigger; no hard-coded Project ID; stand-alone Reviewer: `APPROVE` only, after the comment, App key outside the review job, cycle Reviewers get no Project input; callers use the variable, no `secrets: inherit` |

`tests/refiner.sh` was updated: the Refiner caller now passes the App key, and the new checks
assert that the key only feeds `create-github-app-token` steps scoped to organization projects.

**Integration test on the real Project** — `scripts/github-projects/sync-issue.sh` (same helper,
maintainer's `gh` login with the `project` scope, strict mode), results in §9.1.

### 9.1 Integration run (2026-10-12)

Throwaway Issue `TiPunchLabs/flowforge#42` (no `agent:*` label, no workflow run), driven with
`scripts/github-projects/sync-issue.sh` (maintainer `gh` login, scope `project`, strict mode),
card read back with `--show` after every step. One item for the whole run
(`PVTI_lADODh96YM4BmneSzhANpyU`).

| # | Event | Result | Card after |
|---|---|---|---|
| 1 | `issue-added` | update: (none) → Backlog (item created) | Backlog |
| 2 | `issue-added` (replay) | unchanged, same item | Backlog |
| 3 | `refine-started` | update | Refining |
| 4 | `refine-needs-clarification` | update, Attention set | Backlog + Needs clarification |
| 5 | `refine-started` | update, Attention cleared | Refining |
| 6 | `refine-ready` | update | Ready |
| 7 | `develop-started` | update | Developing |
| 8 | `develop-delivered` | update | Review |
| 9 | `cycle-started` | unchanged | Review |
| 10 | `iterate-started` | update | Iteration |
| 11 | `iterate-completed` | update | Review |
| 12 | `refine-ready` (stale) | **refused** + `::warning::`, card untouched | Review |
| 13 | `refine-ready --force` | update (forced from Review) | Ready |
| 14 | `cycle-started` from Ready | update + note "unexpected source, applied" (ahead in the flow) | Review |
| 15 | `cycle-max-iterations` | update, Attention set | Human validation + Max iterations |
| 16 | `cycle-approved` | update, Attention cleared | Human validation |
| 17 | `pr-merged` | update | Done |
| 18 | `no-such-event` | failed, `::warning::`, exit 1 (strict), card untouched | Done |

Cleanup: item deleted (`deleteProjectV2Item`), Issue #42 closed as not planned.

**Not covered by this run** (Prompt 29): the FlowForge App token path in Actions
(`create-github-app-token` with `organization projects: write`, revoke before Claude) and the
hook points in the real workflows, which are covered statically by `tests/project-sync.sh` only.

------

## 10. ⚠️ Limitations

- **The Project never drives the agents** (by design for Phase 6): no Project → workflow path.
- **Validated on a real agent cycle** (Prompt 29, 2026-10-12, [milestone](../milestones/phase6-github-projects-e2e.md)):
  App-token path and hook points of Refiner, Developer, review cycle and lifecycle observed live.
  The Iterator hooks (`iterate-started`, `iterate-completed`) were not reached then (first review `APPROVE`);
  they were observed live in Prompt 29.2 (`demo-api` #45 / PR #46, milestone §17).
- ~~**Sync warnings keep only the last stderr line**~~: fixed (#44, Prompt 29.3): GitHub's reason is
  kept, sanitized and size-limited (§6.1). Checked live with the real `gh` on the maintainer CLI;
  the Actions path runs the same helper but no failure was provoked in Actions.
- **E1 / E21 / E22 are manual**: no `issues` trigger; closing or reopening an Issue does not move
  its card.
- **Best-effort**: a run that dies before its sync step, or a sync that fails, leaves a stale
  card until the next event; there is no reconciliation job (could rebuild cards from labels and
  PR states later, model §6.4).
- **No lock**: two concurrent writers of the same Issue are only prevented by the workflows'
  concurrency groups and the stale guard.
- **`Agent` field not synced**: rejected in the model (§4, derived from `Status`), not created.
  `Repository` is the built-in field: nothing to write.
- **Private targets**: see the warning in §5.
- **Targets must update their callers** to opt in; old callers keep running without sync.
- **No Notion.**

------

> **Document created on**: 2026-10-12
> **Author**: FlowForge maintainers, with Claude Code
> **Version**: 1.0 — Phase 6, Prompt 28
