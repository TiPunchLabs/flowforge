# 📥 FlowForge — GitHub → Notion status feedback

> Phase 7, Prompt 34. How the state of a submitted Need's GitHub Issue is mirrored back on the
> Need in Notion, so that a contributor who works in Notion sees where their need stands without
> reading labels, workflows or the GitHub Project.
>
> **Prerequisites**: [model.md](model.md) (§9, §12, §13, §15), [submission.md](submission.md)
> (the Need ↔ Issue correlation it creates), [synchronization.md](../github-projects/synchronization.md)
> (how the workflows write the Project card that this feedback reads).

------

## 🧠 Mental Model

```text
 target repository (unchanged, no Notion token)
   FlowForge workflows ──write──► GitHub Project card (Status, Attention)    ◄── source of truth
   lifecycle (merge / close) ───► Issue state, closing pull request

 FlowForge repository — notion-sync.yml  (schedule */10 min + workflow_dispatch)
   1. Read the Needs        NOTION_TOKEN        Needs whose GitHub Issue is set
                                                 + Notion-side correlation checks
   2. Read GitHub state     Bridge App token    Issue, Project item, closing PRs
                            (read-only)          + GitHub-side correlation checks
   3. Write to Notion       NOTION_TOKEN        only the properties that differ
   4. Report                none                step summary, red on FAILED

 Notion = a read-only mirror. Nothing in Notion is ever read back to act on GitHub.
```

> **Analogy**: a departure board. The board (Notion) never moves a plane; it re-reads the
> control tower (GitHub Project) and repaints only the lines that changed.

------

## 📑 Table of contents

1. [Architecture and transport](#1--architecture-and-transport)
2. [Why a central reconciler](#2--why-a-central-reconciler)
3. [Sources of truth](#3--sources-of-truth)
4. [Correlation and anti-corruption](#4--correlation-and-anti-corruption)
5. [Mapping](#5--mapping)
6. [Results, errors and Integration status](#6--results-errors-and-integration-status)
7. [Idempotence and event order](#7--idempotence-and-event-order)
8. [Permissions and credentials](#8--permissions-and-credentials)
9. [Security](#9--security)
10. [Running it](#10--running-it)
11. [Tests](#11--tests)
12. [Limitations](#12--limitations)

------

## 1. 🏗️ Architecture and transport

| Element | Where | Role |
|---|---|---|
| [`.github/workflows/notion-sync.yml`](../../.github/workflows/notion-sync.yml) | FlowForge only | the reconciler: `schedule` every 10 min + `workflow_dispatch` (optional `notion_page_id`) |
| [`.github/scripts/flowforge-notion-sync.sh`](../../.github/scripts/flowforge-notion-sync.sh) | FlowForge only | collect, read GitHub, decide (pure function), apply, report; reuses the Notion API wrapper of `flowforge-notion.sh` |
| Environment `notion-bridge` | FlowForge repo | `NOTION_TOKEN`, `NOTION_BRIDGE_PRIVATE_KEY`, `NOTION_BRIDGE_APP_CLIENT_ID` (same as submission) |
| Target repositories | — | **nothing**: no caller, no secret, no variable |

**Transport chosen: pull.** FlowForge reads the current state of GitHub; targets send nothing.
The job runs in one place, with one Notion credential, and a target becomes eligible through
the same onboarding as the submission (§8.3).

------

## 2. 🤔 Why a central reconciler

Mechanisms audited against the existing architecture:

| Option | What it needs | Verdict |
|---|---|---|
| Write Notion from the reusable workflows (`workflow_call`) | they run in the **caller's** context: the Notion token would have to be a secret of every target | ❌ distributes `NOTION_TOKEN` |
| Target → FlowForge `repository_dispatch` / `workflow_dispatch` | a token able to dispatch on FlowForge (`contents: write` or `actions: write`) in every target workflow; event ordering, lost events and replays to handle | ❌ new cross-repo write power, event-ordering problems |
| Target-side `flowforge-notion.yml` caller | a Notion secret per target | ❌ same as row 1 |
| **Central reconciler in FlowForge (pull)** | read access to the Issue, its Project card and its PRs | ✅ no target change, token in one place, level-triggered (replays and order do not matter) |

The model already recommended this shape ([model.md §12](model.md#12--status-feedback-github--notion)).
Cost: latency (≤ ~10 min plus GitHub's schedule jitter) and very short states can be skipped
by the schedule (§12).

------

## 3. 📌 Sources of truth

| Fact | Source | Never from |
|---|---|---|
| Operational status, Attention | **GitHub Project** `FlowForge Development` card of the Issue (written by the workflows, [synchronization.md](../github-projects/synchronization.md)) | labels alone, Issue text, Notion |
| Closed vs Done | Issue `state` + `state_reason` (REST) | the Project alone (a not-planned Issue is archived from the board) |
| Pull request | `closedByPullRequestsReferences` of the Issue (GraphQL), same repository only | Issue / PR text |
| Completed at | `mergedAt` of the merged closing PR, else Issue `closed_at` | the run time |
| Which Need / which repository | the Need's `GitHub Issue` + `Target repository` (Notion), confirmed by the Issue's author and marker (GitHub) | any free text |

------

## 4. 🔗 Correlation and anti-corruption

Deterministic in both directions; no title, fuzzy search, text or `Need ID` lookup.

| # | Check | Side | On failure |
|---|---|---|---|
| 1 | page is a live Need of `FlowForge Needs` with `GitHub Issue` set | Notion | `REFUSED`, **never written** |
| 2 | `GitHub Issue` is exactly `https://github.com/<owner>/<repo>/issues/<n>` (no query, fragment, PR URL, other host) | Notion | `REFUSED` |
| 3 | exactly one `Target repository`, a live row of `FlowForge Repositories` | Notion | `REFUSED` |
| 4 | its `GitHub repository` equals the Issue URL's repository | Notion | `REFUSED` |
| 5 | `FlowForge enabled` = true | Notion | `REFUSED` |
| 6 | repository in [`config/notion-allowlist.json`](../../config/notion-allowlist.json) | Git | `REFUSED` |
| 7 | the Issue exists and is an Issue, not a PR | GitHub | `REFUSED` |
| 8 | the Issue was **created by the Notion Bridge** and carries the marker `<!-- flowforge:notion-page-id=<this page> -->` | GitHub | `REFUSED` |

Checks 1–6 run **before any GitHub call**. Check 8 closes the loop: a Need whose `GitHub Issue`
was edited to point at another Need's Issue, or at any human-authored Issue, is refused. The
write target is always the page ID the Need was read from; the Project card is the one of the
Project ID in [`config/github-project.json`](../../config/github-project.json) (cards of other
Projects are ignored).

------

## 5. 🗺️ Mapping

### 5.1 FlowForge Status

| GitHub / FlowForge | Notion `FlowForge Status` |
|---|---|
| Issue **closed as not planned** or **duplicate** | `Closed` |
| Issue **closed as completed** (merge with `Closes #n`, or by hand) | `Done` |
| Open Issue, Project `Status` ∈ `Backlog`, `Refining`, `Ready`, `Developing`, `Review`, `Iteration`, `Human validation`, `Done` | same value |
| Open Issue, no card in the FlowForge Project yet, or an unknown `Status` | **kept** (the submission set `Backlog`) |

`Human validation` is never translated into `Done`; only a closed Issue is `Done`. Backward
moves are mirrored too (`Human validation → Review`, PR closed unmerged `→ Backlog`, reopened
`Done → Backlog`). `Draft` is never written.

### 5.2 Attention

Mirror of the Project `Attention` (empty clears it); kept when there is no card. The values come
from the workflows' own events (kanban-model.md §11), so transient incidents never reach it:

| FlowForge outcome | Attention |
|---|---|
| Refiner `NEEDS_CLARIFICATION` | `Needs clarification` |
| Refiner / Developer / cycle `BLOCKED` | `Blocked` |
| Review cycle `MAX_ITERATIONS_REACHED` | `Max iterations` |
| technical failure of an agent run | `Failed` |

### 5.3 Pull request

1. Closing PRs of the **same repository** only (a fork's or another repository's PR is ignored).
2. A **merged** PR wins (latest `mergedAt`), else the **latest open** PR, else none.
3. The URL is **rebuilt** as `https://github.com/<allowlisted repo>/pull/<number>`, never copied.
4. No candidate: a valid link already in Notion is **kept** (never cleared); an invalid value
   (other host, other repository, query string…) is cleared.

### 5.4 Completed at, Last synced

- `Completed at`: set only for `Done` (merge time, else close time); cleared if the Need leaves
  `Done` (reopened). Not set for `Closed`.
- `Last synced`: UTC (`…Z`), stamped by **every** write, and only by a write (§7).

------

## 6. 🧾 Results, errors and Integration status

| Result | Meaning | Notion write | Run |
|---|---|---|---|
| `UPDATED` | at least one property differed | the differing properties + `Integration status = OK` + `Integration message = SYNCED: …` + `Last synced` | green |
| `UNCHANGED` | Notion already matches GitHub | **none** | green |
| `REFUSED` | correlation or data invalid (§4) | `Integration status = Error`, `Integration message = REFUSED: <reason>` only — never `FlowForge Status`, `Attention`, `Pull request`, `Completed at`; written once, not rewritten while unchanged; **nothing at all** for check 1 | green (notice) |
| `FAILED` | technical: Notion / GitHub API error, no Bridge token, write-back error | `Error` + `FAILED: <reason>` if Notion still accepts writes; otherwise summary and logs only | **red** |

`Integration status` is the health of the sync, never the FlowForge state: `Developing` + `OK`
means "agents are working and the last sync succeeded". A failure keeps the last known
`FlowForge Status` (model §15). The next successful sync resets `Error` to `OK`
(`SYNCED: Notion matches GitHub.` when nothing else changed).

Messages (≤ 1900 characters, no stack trace, no payload):

```text
SYNCED: FlowForge status updated to Developing.
SYNCED: FlowForge status updated to Review. Pull request #52 linked.
SYNCED: Need reached Human validation.
SYNCED: Need completed.
SYNCED: Need closed (Issue closed as not_planned).
REFUSED: GitHub Issue repository TiPunchLabs/demo-api does not match the Target repository (TiPunchLabs/test-repo-a).
FAILED: Reading the Project card / pull requests of TiPunchLabs/demo-api#47 failed: HTTP 502 …
```

The step summary has one row per Need: Need, Repository, Issue, Previous status, New status,
Pull request, Result, Notion write-back (`OK` / `none` / `FAILED`), Message.

------

## 7. 🔁 Idempotence and event order

- **Level-triggered, not event-driven.** Each run reads the *current* state and computes the
  target values from scratch: a duplicated, replayed or out-of-order workflow event cannot
  reach Notion, because no event reaches Notion — only the state the Project sync already
  guarded (its stale guard, synchronization.md §4).
- **No write when nothing differs**, so a rerun is `UNCHANGED` and `Last synced` keeps the time
  of the last real change. Dates are compared normalised (Notion returns `….000+00:00`).
- **No deletion**: a valid PR link is never removed; no Need is created; `GitHub Issue`, `Title`,
  `Need`, `Priority`, `Project`, `Target repository` are never written.
- **One reconciler at a time** (`concurrency: notion-sync`). The submission writes only Needs
  without a `GitHub Issue` and the fields it owns; the window where both touch a Need is the
  submission's final write, after which the sync starts from that state.
- Race inside a run (the Project changes between the read and the write): the next run corrects
  it; a stale value lives at most one interval.

------

## 8. 🔐 Permissions and credentials

| Identity | Used by | Permissions (token) | Change for Prompt 34 |
|---|---|---|---|
| `NOTION_TOKEN` (internal integration *FlowForge Notion Runtime*) | steps *Read the Needs*, *Write to Notion* only | *Read content* + *Update content* on the 3 FlowForge databases | **none** |
| *FlowForge Notion Bridge* App | step *Read GitHub state* only | token minted with `issues: read`, `pull-requests: read`, `organization-projects: read` | App gains **read-only** *Pull requests* and *Organization → Projects*; the submission token stays `issues: write` only |
| FlowForge App | — | — | **none** (its key is not copied anywhere) |
| `GITHUB_TOKEN` of `notion-sync.yml` | checkout | `contents: read` | — |

Why the Bridge App needs more read access: the FlowForge Project is a **private organization
Project** — no repository token can read it — and on a private target the closing PRs need
*Pull requests: read*. Reusing the FlowForge App was rejected: it would put a second copy of a
key with `contents`/`pull requests: write` on every target into `notion-bridge`. The Bridge App
still cannot push, open PRs, merge, run workflows or write a Project.

**Setup (once)**, in the App settings of *FlowForge Notion Bridge* → *Permissions*:

1. *Repository permissions* → **Pull requests: Read-only**.
2. *Organization permissions* → **Projects: Read-only**.
3. Save, then accept the new permissions on the installation (*Organization settings → GitHub
   Apps → FlowForge Notion Bridge → Review request*). Until accepted, the read step reports
   `FAILED` with GitHub's reason.

Other rules: `NOTION_TOKEN` never reaches a target, a GitHub step, or Claude (no agent runs in
this workflow); the environment `notion-bridge` is limited to `main`; the Bridge token is
revoked by the action's post step; tokens are sent as headers (Notion via a file descriptor),
never logged.

------

## 9. 🛡️ Security

- Issue / PR **title and body are never read** into a decision, except the exact marker check
  (`contains` on the page's own marker, Bridge-authored Issues only). A forged marker for
  another page, a Notion URL or a PR URL in the text changes nothing (tested).
- The destination page, repository and properties are computed from the Need's own page ID and
  relations, the allowlist (Git) and the Project ID file (Git) — never from free text.
- Only integration-owned properties are written (model §13); the PATCH body is built by `jq`
  from fixed property names.
- `${{ }}` is never interpolated in `run:`; the optional input is normalised to a page ID first.
- No agent, no Claude, no write to GitHub in this workflow.

------

## 10. ▶️ Running it

- **Automatic**: every 10 minutes from `main` (GitHub may delay scheduled runs).
- **On demand** — all Needs, or one:

```bash
# All submitted Needs
gh workflow run notion-sync.yml -R TiPunchLabs/flowforge
# One Need (page ID or URL)
gh workflow run notion-sync.yml -R TiPunchLabs/flowforge -f notion_page_id=<page id>
```

Onboarding a new target needs nothing beyond the submission's onboarding
([submission.md §8.4](submission.md#84-onboarding-a-new-target)): allowlist entry, Bridge App
installed on the repository, `FlowForge Repositories` row enabled, Project sync enabled for the
target (otherwise only Closed / Done are mirrored, see §12).

------

## 11. 🧪 Tests

[`tests/notion-sync.sh`](../../tests/notion-sync.sh) (pre-commit hook `notion-sync`), against the
real helper and workflow, Notion and GitHub stubbed:

| Area | Cases |
|---|---|
| Mapping | the 8 Project statuses, Closed (not planned, duplicate), Done (merged / closed by hand), no card, unknown status, reopened Done, replay |
| Attention | Needs clarification, Max iterations, Failed, cleared, no card |
| Pull request | present, absent, already known, closed unmerged (kept), merged preferred, latest open, other repository, 4 invalid URLs |
| Correlation | linked, no `GitHub Issue`, repository mismatch, disabled, not allowlisted, non-canonical URL, other Need's marker, non-Bridge author, deleted Issue, other database, page not found, trashed |
| Security | instruction in title, injection + forged marker + PR URL in body, Notion URL in title; only the correlated page written |
| Idempotence | same state twice (no write, `Last synced` kept), Done twice (Notion date format), refusal not rewritten, Error recovered |
| Failures | Notion down, write-back error, GitHub error, no Bridge token, one refused Need among others |
| Workflow | triggers, `permissions: {}`, environment, concurrency, no `${{ }}` in `run:`, read-only token, credential separation per step, nothing in `examples/` |

------

## 12. ⚠️ Limitations

| Limitation | Note |
|---|---|
| Latency ≤ ~10 min + schedule jitter; a state shorter than the interval (e.g. `Developing`) may never appear in Notion | by design; `workflow_dispatch` forces a sync |
| Needs the target's Project sync (`project_number` opt-in); without a card only `Closed` / `Done` (Issue state) are mirrored | documented in onboarding |
| One GitHub owner per token (the reconciler mints for `github.repository_owner`) | POC: all targets are `TiPunchLabs/*` |
| A closed-unmerged PR stays linked until a new PR exists | intentional: a valid link is never cleared |
| A human can still edit the Issue body (marker) or Notion integration fields; the next sync overwrites Notion, an edited marker makes the Need `REFUSED` | accepted |
| Each run reads every submitted Need (no incremental cursor) | fine at POC scale (Notion 3 req/s) |

------

> **Document created on**: 2026-10-14
> **Author**: FlowForge maintainers (with Claude Code)
> **Version**: 1.0 — Phase 7, Prompt 34
