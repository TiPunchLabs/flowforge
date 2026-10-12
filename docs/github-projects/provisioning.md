# 🛠️ FlowForge — GitHub Project provisioning

> **Status**: provisioned on 2026-10-11 (Phase 6, Prompt 27). The Project exists and represents
> the states; **nothing synchronises it yet** (Prompt 28) and **no card move starts an agent**.
>
> **Prerequisites**: [kanban-model.md](kanban-model.md) (the model), `gh` ≥ 2.40 logged in with
> the `project` scope (`read:project` for `--check`; how to add it: §6.1), `jq`, organization
> member of `TiPunchLabs` allowed to create Projects.

------

## 🧠 Mental Model

```text
  kanban-model.md ──(desired state, hand-copied)──► scripts/github-projects/bootstrap.sh
                                                         │  gh api graphql (your gh login)
                                                         ▼
                                       GitHub Project v2 "FlowForge Development" (#1)
                                                         │  read back
                                                         ▼
                                       config/github-project.json   (IDs for Prompt 28)

  UI only (no API): view grouping "By repository", built-in workflows off   (§4)
```

| Tool | Manages | Why |
|---|---|---|
| Terraform (`integrations/github` 6.13) | repositories, labels, rulesets | Has **no** Projects v2 resource |
| `bootstrap.sh` (GitHub CLI + GraphQL) | Project, fields, options, views, IDs file | Only API that covers Projects v2; idempotent script |
| GitHub UI | view grouping, built-in workflows | Not settable through the API; checked by `--check` |

------

## 1. 🎯 Provisioned Project

| Item | Value |
|---|---|
| Name | `FlowForge Development` |
| Owner | organization `TiPunchLabs` |
| Number | `1` |
| Project ID | `PVT_kwDODh96YM4BmneS` |
| URL | <https://github.com/orgs/TiPunchLabs/projects/1> |
| Visibility | private |
| Short description | set by the script (visual only, labels and runs are the execution truth) |

All IDs (Project, fields, options, views) are in **[`config/github-project.json`](../../config/github-project.json)**,
written by the script from what GitHub returns. They are not secrets.

------

## 2. 🧾 Fields

| Field | Type | Values (in order) | Field ID |
|---|---|---|---|
| `Status` | single select, built in | `Backlog`, `Refining`, `Ready`, `Developing`, `Review`, `Iteration`, `Human validation`, `Done` | `PVTSSF_lADODh96YM4BmneSzhlPvSg` |
| `Attention` | single select, custom | `Needs clarification`, `Blocked`, `Max iterations`, `Failed` (empty = flow proceeds) | `PVTSSF_lADODh96YM4BmneSzhlPvTQ` |
| `Priority` | single select, custom | `P0`, `P1`, `P2`, `P3` | `PVTSSF_lADODh96YM4BmneSzhlPvTU` |
| `Repository`, `Labels`, `Linked pull requests`, `Assignees` | built in | — | not needed |

**Status options** (option IDs are what the sync writes):

| Status | Option ID |
|---|---|
| Backlog | `db53a71c` |
| Refining | `d3aed46f` |
| Ready | `9064c2b3` |
| Developing | `59c911e1` |
| Review | `35db47b4` |
| Iteration | `25b1818f` |
| Human validation | `1199259f` |
| Done | `98236657` |

**Attention options**: `Needs clarification` `242686c6`, `Blocked` `3eb5164d`,
`Max iterations` `c874bd17`, `Failed` `8251300c`.
**Priority options**: `P0` `39e74337`, `P1` `c8186a68`, `P2` `4bd9bff0`, `P3` `bbc9d512`.

Not created, as decided in the model §4: `Agent` (rejected, derived from `Status`),
`Iteration count` and `Risk` (future). `Type` uses the organization Issue types (`Task`, `Bug`,
`Feature`); the API does not expose it as a Project field, so it can only be shown as a column
from the UI (optional).

> 💡 **Note**: the script preserves option IDs by name when it updates options. Renaming an
> option in the UI creates a drift that the script resolves by **replacing** it; it refuses to
> drop an option that still holds items rather than clear their values.

------

## 3. 👁️ Views

| # | View | Layout | Filter | Grouping | Cards / columns shown |
|---|---|---|---|---|---|
| 1 | **Board** | board | — | columns by `Status` (default, verified) | Title, Attention, Priority, Linked pull requests |
| 2 | **Attention** | table | `-no:attention` | — | Title, Status, Attention, Repository, Linked pull requests |
| 3 | **By repository** | table | — | `Repository` (**UI step**, §4) | Title, Status, Attention, Priority, Repository, Labels, Linked pull requests |

> ⚠️ **Correction of the model (§14.4, *Needs a human*)**: Projects filters cannot OR two
> different fields (GitHub docs: *"does not currently support logical OR filters across multiple
> fields"*), so "`Human validation` **or** `Attention` not empty" is not expressible. Minimal
> correction: the view is **`Attention`** (`-no:attention`, every item a human must unblock, any
> column); `APPROVED` items waiting for the merge are the `Human validation` column of *Board*.
> No field, status or transition changes.

------

## 4. 🖱️ Manual UI steps (not available through the API)

Done once, after the first script run, in the [Project](https://github.com/orgs/TiPunchLabs/projects/1).
`bootstrap.sh --check` reports each one until it is done.

| # | Step | Where | Why |
|---|---|---|---|
| U1 | *By repository* → view menu → **Group by: Repository**, then ▾ next to the view name → **Save changes** | view 3 | `groupByFields` is read-only in the API |
| U2 | **Disable** *Item closed* | ⋯ → Workflows | Sets `Done` on any closure, *not planned* included (model §9: not planned is archived, not `Done`). Observed: `demo-api` #33 went to `Done` by itself when added |
| U3 | **Disable** *Pull request merged* | ⋯ → Workflows | PRs are not items (model §2) |
| U4 | **Disable** *Auto-close issue* | ⋯ → Workflows | Closes the Issue when a card reaches `Done`: a card move would act on GitHub, against model §6 |
| U5 | **Disable** *Auto-add sub-issues to project* | ⋯ → Workflows | Items enter by a human or the sync (model §2), never implicitly |

> ⚠️ **Warning — unsaved view changes**: a grouping (or filter, sort, column) changed in the UI is
> only a local draft, shown by a dot next to the view name, until **Save changes** is clicked.
> Unsaved, GitHub keeps the old configuration and `--check` still reports U1 (the view's
> `updatedAt` does not move). Built-in workflows (U2–U5) are saved as soon as they are toggled.

**Native automations — decision** (the six built-in workflows the API returns for this Project).

| # | Built-in workflow | Default | FlowForge | Reason |
|---|---|---|---|---|
| 1 | Item closed | **on** | **off** (U2) | Cannot exclude *not planned* |
| 2 | Pull request merged | **on** | **off** (U3) | No PR items |
| 3 | Auto-close issue | **on** | **off** (U4) | Card move must stay visual |
| 4 | Auto-add sub-issues to project | **on** | **off** (U5) | No implicit items |
| 5 | Pull request linked to issue | off | off | The Developer delivery (E8) writes `Review` |
| 6 | Item added to project | off | off | The sync (Prompt 28) writes `Backlog` with `Attention` |

*Auto-add to project* (per repository) and *Auto-archive items* are not listed by the API for
this Project; they stay unused. Auto-add remains an optional convenience later (model §10).

------

## 5. ▶️ Commands

```bash
# Check only: Project found, fields, options, views, UI steps, IDs file. Exit 1 on any drift.
scripts/github-projects/bootstrap.sh --check

# Create or converge, then rewrite config/github-project.json from GitHub.
scripts/github-projects/bootstrap.sh
```

Behaviour:

- **First run**: creates the Project, sets it private with its description, replaces the
  default `Status` options (an option kept by name keeps its ID, here `Done`), creates `Attention` and `Priority`, turns the
  default view into *Board*, creates the two tables, writes the IDs file, lists the UI steps.
- **Second run** (verified 2026-10-11): no write call, `config/github-project.json` byte-identical,
  still one Project. Only the remaining UI steps are reported.
- **Fails clearly** (exit 1, nothing guessed) on: two open Projects with the title, a field of the
  wrong type or duplicated, two views with the same name, a view field that does not exist, an
  option to remove that still holds items.

------

## 6. 🔐 Authentication and permissions

| Use | Identity | Permission | Stored |
|---|---|---|---|
| Provisioning (this script, by hand) | maintainer's `gh` login (OAuth) | scopes `project` (write) + `read:org`; `read:project` is enough for `--check` | `gh` keyring, never in the repository |
| Workflows today | `GITHUB_TOKEN` / FlowForge App | **none on the Project** | — |
| Sync (Prompt 28) | FlowForge GitHub App (architecture §2.10) | **Organization projects: read and write** (granted 2026-10-12, §6.2); still no `issues` | App private key as Actions secret (already the case) |

`GITHUB_TOKEN` cannot access an organization Project at all, so the sync needs the App (or a
fine-grained PAT with *organization projects: read and write*, not retained: personal and
long-lived).

### 6.1 🔑 `gh` scope for provisioning

The Projects v2 API needs its own OAuth scope: `repo` and `read:org` give no access to a
Project, not even read (`gh` fails with *missing required scopes [read:project]*).

```bash
# Add the scope before running the script (write: bootstrap; read only: --check)
gh auth refresh -h github.com -s project
gh auth refresh -h github.com -s read:project

# Verify
gh auth status          # "Token scopes:" lists project (or read:project)

# Remove it afterwards (least privilege)
gh auth refresh -h github.com -r project
```

The command prints a one-time code and opens a device flow on `https://github.com/login/device`.
`-h github.com` is mandatory when no terminal is attached (e.g. `!` commands in Claude Code),
otherwise `gh` fails with *--hostname required when not running interactively*.

> 💡 **Note**: state on 2026-10-12: the scope was added for Prompt 27 and **removed** afterwards.
> Re-add `read:project` before running `--check`.

### 6.2 🤖 FlowForge App: organization projects permission

Two steps, both by an organization owner. Adding a permission to an App does **not** reach its
existing installations until the organization accepts it.

1. **App** — <https://github.com/organizations/TiPunchLabs/settings/apps/tipunchlabs-flowforge/permissions>
   → *Organization permissions* → **Projects: Read and write** → **Save changes** (confirm
   that installations will be notified). Nothing else changes: **no `Issues` permission**, so
   the App still can never apply `agent:ready` (architecture §2.10).
2. **Installation** — <https://github.com/organizations/TiPunchLabs/settings/installations>
   → *tipunchlabs-flowforge* → **Configure** → banner *requesting new permissions* →
   **Review request** → **Accept new permissions**.

```bash
# Verify the installation (needs read:org)
gh api orgs/TiPunchLabs/installations \
  --jq '.installations[] | select(.app_slug == "tipunchlabs-flowforge") | .permissions'
# expected: {"contents":"write","metadata":"read","organization_projects":"write","pull_requests":"write"}
```

Done and verified on 2026-10-12. Nothing uses the permission yet: the delivery tokens still
request only `contents` + `pull-requests` (Developer) and `contents` (Iterator), so they never
carry it; Prompt 28 decides how the sync requests it.

**Visibility.** Organization members see the Project according to the org's base Project
permission; items of private repositories stay visible only to people who can read them. The
Project accepts Issues from any `TiPunchLabs` repository: no org-wide permission was changed.

------

## 7. 📌 Configuration storage

| Value | Where | Why |
|---|---|---|
| All IDs (Project, fields, options, views) | `config/github-project.json`, versioned, generated | One place, reviewable, diffable; `--check` fails if it drifts from GitHub |
| Project number for the targets' callers | to decide in Prompt 28 (e.g. organization variable `FLOWFORGE_PROJECT_NUMBER`) | Per-target opt-in (model §10) |
| Tokens | never in Git, workflows, logs | Security rules |

The reusable workflows fetch `.github/scripts/*` at `job.workflow_sha`; Prompt 28 can fetch the
IDs file the same way, or resolve IDs by name at run time from the Project number. Either way no
ID is copied into a workflow file.

------

## 8. ✅ Validation (2026-10-11)

| Check | Result |
|---|---|
| Items from 2 repositories | `demo-api` #30, #31, #33 and `flowforge` #34 added |
| Initial placement | #30 `Backlog`, #31 `Ready` + `P2`, #33 `Done` (closed, `agent:done`, merged PR #34 shown as linked PR), `flowforge` #34 `Backlog` |
| Manual moves | #30 `Backlog → Refining → Backlog` + `Attention = Needs clarification` (shown in view *Attention*); #31 `Ready → Backlog → Ready`. All persisted |
| No agent triggered | no Actions run created on `demo-api` nor `flowforge` after the moves; labels of #30, #31, #34 unchanged |
| Idempotence | second run: no write, IDs file unchanged |
| UI steps U1–U5 | done by a maintainer (view grouping saved, the four built-in workflows off); `bootstrap.sh --check` exits 0: *Project conforms to the model* |

------

## 9. ⚠️ Limits

- No synchronisation from the workflows yet (Prompt 28); the board is maintained by hand.
- Card moves never trigger agents: Project item events are not Actions triggers (model §6).
- View grouping and built-in workflows are UI-only (§4); `--check` detects them.
- `Type` (Issue types) cannot be placed on a view through the API.
- The script reads at most 100 items when it guards option removal (enough for the POC).
- Only `demo-api` is an onboarded target; `flowforge` #34 stands in as the second repository.
- No Notion.

------

> **Document created on**: 2026-10-11
> **Author**: FlowForge maintainers, with Claude Code
> **Version**: 1.1 — Phase 6, Prompt 27 (+ `gh` scope, unsaved views, App permission procedure)
