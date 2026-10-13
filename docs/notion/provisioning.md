# 🛠️ FlowForge — Notion space provisioning

> **Status**: provisioned on 2026-10-13 (Phase 7, Prompt 32). The three databases, their
> relations and the six views of the Needs database exist and hold test data. **Nothing is
> integrated**: no submission to GitHub (Prompt 33), no status feedback (Prompt 34), no runtime
> Notion credential, no workflow. Ticking `Submit` does nothing yet.
>
> **Prerequisites**: [model.md](model.md) (the model: source of truth for databases, properties,
> roles, rules), `curl`, `jq`, a Notion personal access token of a FlowForge maintainer (§5).

------

## 🧠 Mental Model

```text
  model.md ──(desired state, hand-copied)──► scripts/notion/bootstrap.sh
                                                  │  Notion API 2026-03-11 (maintainer's token, local only)
                                                  ▼
            page "FlowForge"
              ├── FlowForge Projects      ◄──┐
              ├── FlowForge Repositories  ◄──┤ two-way relations
              └── FlowForge Needs  ──────────┘ + 6 views
                                                  │  read back
                                                  ▼
                                   config/notion.json   (non-secret IDs for Prompts 33/34)

  scripts/notion/seed-test-data.sh ──► 2 Projects, 3 Repositories, 4 Needs (test only)
  UI only (no API): relation limit "1 page", sharing / permissions   (§6)
```

| Tool | Manages | Why |
|---|---|---|
| `bootstrap.sh` (Bash, curl, jq) | databases, data sources, properties, relations, views, IDs file | the API covers all of it since `2026-03-11` (views included); idempotent, `--check` audit |
| `seed-test-data.sh` | Prompt 32 test rows | reproducible, idempotent by title |
| Notion UI | relation limit, sharing, guests | not settable through the API |

------

## 1. 🧭 Provisioning method

| Option | Verdict |
|---|---|
| A. Notion UI by hand | Rejected: ~45 properties and 6 filtered/grouped views, error-prone and not auditable |
| **B. Notion API, scripted** | **Retained**: same pattern as [`scripts/github-projects/bootstrap.sh`](../github-projects/provisioning.md): idempotent, converges by adding only, `--check` reports drift, IDs written to `config/` |
| C. Hybrid | De facto for the two settings the API lacks (§6), reported by every run as `MANUAL:` lines |

Converging **only adds**: a property of the wrong type, an extra property or an extra view is
reported as drift, never changed or deleted (that could destroy data).

------

## 2. 🗄️ Provisioned space

| Item | Value |
|---|---|
| Parent page | `FlowForge` — <https://app.notion.com/p/FlowForge-3f86f28ff5ca81adb505f1760753b14b> (`3f86f28f-f5ca-81ad-b505-f1760753b14b`), created by the maintainer at workspace level |
| API version | `2026-03-11` (one data source per database, view endpoints) |

| Database | Database ID | Data source ID | Role |
|---|---|---|---|
| **FlowForge Projects** | `7665cc44-5321-4359-b451-602aaa200fa8` | `07163865-ee18-4c94-a9ae-17752c5733b5` | products that may receive Needs; maintainers only |
| **FlowForge Repositories** | `e3215970-153a-4973-83bd-6469358ec2e5` | `f749af34-6039-42fd-bd9c-78716eb85688` | controlled picklist of target repositories, each tied to one Project; maintainers only |
| **FlowForge Needs** | `7d1aba29-9887-4699-aaee-d5cc743f0a01` | `9c37ea5a-25d2-4d24-a4e4-3bde345a9a80` | the shared intake, one row per need; every contributor |

All IDs (databases, data sources, property IDs, view IDs) are in
**[`config/notion.json`](../../config/notion.json)**, written by the script from what Notion
returns. They are not secrets: without a credential they grant nothing.

------

## 3. 🧾 Properties

*Req.* = required for the Phase 7 POC (model §5). *Owner* = the only writer (model §13).
Notion has no required-field enforcement: "required" is checked at submission (Prompt 33, §8).

### 3.1 FlowForge Projects

| Property | Type | Req. | Owner / source of truth |
|---|---|---|---|
| `Name` | title | yes | maintainer, Notion |
| `Owners` | people | yes | maintainer, Notion |
| `Active` | checkbox | yes | maintainer, Notion |
| `Repositories` | relation ↔ Repositories `Project` (reverse side) | yes | follows `Repositories.Project` |
| `Needs` | relation ↔ Needs `Project` (reverse side) | — | follows `Needs.Project` |
| `Description` | rich text | — | maintainer, Notion |
| `Documentation` | URL | — | maintainer, Notion |
| `GitHub Project` | URL | — | maintainer; today always `FlowForge Development` #1 |

### 3.2 FlowForge Repositories

| Property | Type | Req. | Owner / source of truth |
|---|---|---|---|
| `Name` | title | yes | maintainer, Notion |
| `GitHub repository` | rich text, `owner/name` | yes | maintainer; **routing truth = FlowForge allowlist in Git** (Prompt 33), Notion value is cross-checked, never trusted alone |
| `FlowForge enabled` | checkbox | yes | maintainer, Notion |
| `Project` | relation → Projects, dual (`Repositories`) | yes | maintainer, Notion |
| `Needs` | relation ↔ Needs `Target repository` (reverse side) | — | follows `Needs.Target repository` |

### 3.3 FlowForge Needs

| Property | Type | Req. | Owner / source of truth |
|---|---|---|---|
| `Title` | title | yes | requester, Notion (frozen for FlowForge once submitted) |
| `Need` | rich text | yes | requester, Notion; natural language, no format imposed |
| `Project` | relation → Projects, dual (`Needs`) | yes | requester, Notion |
| `Target repository` | relation → Repositories, dual (`Needs`) | yes | requester, Notion |
| `Requested by` | people | yes | requester, Notion |
| `Created by` | created by | auto | Notion |
| `Priority` | select `Low`, `Medium`, `High`, `Urgent` | yes | requester / owner, Notion (business priority) |
| `Submit` | checkbox | yes | requester / owner: **intent only**, triggers nothing |
| `FlowForge Status` | select `Draft`, `Backlog`, `Refining`, `Ready`, `Developing`, `Review`, `Iteration`, `Human validation`, `Done`, `Closed` | yes | integration; `Draft` (or empty) until the Issue exists, then **GitHub Project** |
| `Integration status` | select *empty*, `Pending`, `OK`, `Error` | yes | integration |
| `Integration message` | rich text | — | integration |
| `Attention` | select `Needs clarification`, `Blocked`, `Max iterations`, `Failed` | — | integration, mirror of the GitHub Project |
| `GitHub Issue` | URL | yes | integration, set once (idempotence guard) |
| `Pull request` | URL | yes | integration, from GitHub |
| `Completed at` | date | — | integration, from GitHub |
| `Last synced` | date | — | integration |
| `Need ID` | unique ID, prefix `NEED` | auto | Notion (`NEED-1`, `NEED-2`, …) |
| `Business reason` | rich text | — | requester, stays in Notion |
| `Context` | files & media | — | requester, stays in Notion |
| `Related needs` | relation → Needs (self, one-way) | — | requester, Notion |

`Draft` and `Closed` are **Notion-only** values; the eight others are the GitHub Project statuses
([kanban-model.md §3](../github-projects/kanban-model.md#3--statuses)).

### 3.4 Prompt 32 brief vs. model: what was provisioned

The brief listed indicative properties; the model (Prompt 31) is the source of truth and was
kept. Each difference is deliberate:

| Brief | Provisioned (model) | Why |
|---|---|---|
| Projects `Owner` + `Status` | `Owners` (people); no `Status` | several owners; `Status` duplicates `Active` (model §5.1) |
| Repositories `GitHub Owner`, `Repository URL`, `Default Branch`, `Active` | `GitHub repository` (`owner/name`), `FlowForge enabled` | one canonical value, URL derivable; default branch read from GitHub; one switch (model §5.2) |
| `Author` | `Requested by` + automatic `Created by` | the person with the need may differ from the typist |
| `GitHub Issue Number` | not created | derivable from `GitHub Issue`; a copy would drift |
| `Integration Status` `Not submitted` / `Pending` / `Submitted` / `Error` | *empty* / `Pending` / `OK` / `Error` | *empty* = never handled; "submitted" = `GitHub Issue` non-empty, the real guard; `OK` also covers syncs (model §15) |
| Board with 9 statuses | 10 (`Closed`, Notion-only) | Issue closed as not planned (model §9) |
| `Completed At`, `Pull Request` | `Completed at`, `Pull request` | model naming |

------

## 4. 🔗 Relations

| Relation | Shape | Verified |
|---|---|---|
| Project → Repositories / Repository → Project | `Repositories.Project` dual ↔ `Projects.Repositories` | **PASS**: Test Project A shows `test-repo-a`, `test-repo-b`; each repository shows its Project |
| Project → Needs | `Needs.Project` dual ↔ `Projects.Needs` | **PASS**: each Project lists its Needs |
| Repository → Needs | `Needs.Target repository` dual ↔ `Repositories.Needs` | **PASS**: `test-repo-c` lists both of its Needs |
| Need → Need | `Related needs`, one-way | created, not exercised |

`Project` and `Target repository` are **separate** relations: a Need names both, and they must agree
(§7.2).

------

## 5. 👁️ Views of FlowForge Needs

| View | Layout | Filter / group | Sort | State |
|---|---|---|---|---|
| **All Needs** | table | none | `Need ID` ↓ | provisioned; columns: Title, Need ID, Project, Target repository, Requested by, Priority, FlowForge Status, Integration status, GitHub Issue |
| **My Needs** | table | `Created by` contains *me* **or** `Requested by` contains *me* | `Need ID` ↓ | provisioned; the API stored the `me` filter |
| **By Project** | table | grouped by `Project` | `Need ID` ↓ | provisioned |
| **By Repository** | table | grouped by `Target repository` | `Need ID` ↓ | provisioned |
| **FlowForge Board** | board | columns = `FlowForge Status`, in option order, empty columns shown | — | provisioned; **informative only**: moving a card changes a Notion value and nothing else |
| **Needs attention** | table | (`Submit` ✔ **and** `GitHub Issue` empty) **or** `Attention` not empty **or** `FlowForge Status` = `Human validation` **or** `Integration status` = `Error` | `Need ID` ↓ | provisioned; on the test data it selects exactly `NEED-2` |

Notes:

- **Sort**: the model says "sorted by `Last edited`"; a view sort must name a property, and
  `Need ID` descending (newest first) avoids adding a `Last edited time` property.
- **Needs attention**: "`Draft` with `Submit` ticked" is expressed as "`Submit` ticked and no
  `GitHub Issue`", the actual pending-submission condition, also true when `FlowForge Status` is
  left empty. The brief's name *Needs requiring attention* is shortened as in the model; no
  `Needs clarification` status is added, it stays an `Attention` value.
- Projects and Repositories keep their default table view (model §18).

------

## 6. 🖱️ Manual UI steps (not available through the API)

`bootstrap.sh` prints them as `MANUAL:` on every run.

| # | Step | Where | Status |
|---|---|---|---|
| 1 | Limit `Project` and `Target repository` (Needs) and `Project` (Repositories) to **1 page** | property → Edit property → Limit → 1 page | **to do** by the maintainer |
| 2 | Sharing (below) | page `FlowForge` → Share, then each database → Share | **to do** when a second person joins |
| 3 | Optional: filter the `Target repository` picker by the chosen Project | relation property settings, if the plan offers it | not done; never a guarantee (§7.2) |

**Permission model** (model §7), from the parent page down:

| Role | `FlowForge` page / Projects / Repositories | Needs |
|---|---|---|
| Observer | Can view | Can view or Can comment |
| Requester | Can view | **Can edit content** (create rows, edit Title / Need / Priority / Project / Target repository, tick Submit) |
| Project owner | Can view | Can edit content (+ listed in `Projects.Owners`) |
| FlowForge maintainer | Full access | Full access (schema, views) |

*Can edit content* lets requesters change rows but not properties or views. External people can
be invited as **guests** on the Needs database. Least privilege: nobody but maintainers edits
Projects and Repositories, the routing data.

------

## 7. 🧪 Test data and checks

Created by `seed-test-data.sh`, all clearly marked *Test*:

```text
Test Project A  (Active, owner: maintainer)
  ├── test-repo-a   TiPunchLabs/test-repo-a   FlowForge enabled ✘
  └── test-repo-b   TiPunchLabs/test-repo-b   FlowForge enabled ✘
Test Project B  (Active, owner: maintainer)
  └── test-repo-c   TiPunchLabs/test-repo-c   FlowForge enabled ✘

NEED-1  Test — paginate the task list              Project A → test-repo-a   Medium  Submit ✘
NEED-2  Test — add a health endpoint               Project A → test-repo-b   High    Submit ✔
NEED-3  Test — export candidates as CSV            Project B → test-repo-c   Low     Submit ✘
NEED-4  Test — inconsistent target (A → repo-c)    Project A → test-repo-c   Medium  Submit ✘
```

The test repositories do not exist on GitHub and are not enabled: none of these rows can pass the
Prompt 33 validation. All four are `Draft`, with empty `GitHub Issue` and `Integration status`.

### 7.1 Multi-project, multi-repository

**PASS**: two Projects, one with two repositories; Needs of Project A target `test-repo-a` and
`test-repo-b`, a Need of Project B targets `test-repo-c`; relations are visible from both sides;
*By Project* and *By Repository* group them.

### 7.2 Project ↔ Repository inconsistency

`NEED-4` (Project A, target `test-repo-c` of Project B) was **accepted by Notion** without any
warning. Notion relations cannot express "the target must belong to the chosen Project".

> ⚠️ **Rule (not implicit)**: Prompt 33 must reject such a Need before any GitHub call:
> `Need.Target repository.Project` = `Need.Project`, otherwise `Integration status = Error`, a
> message, `Submit` unticked (model §10.3, §15).

### 7.3 Submit

`NEED-2` has `Submit` ticked: it appears in *Needs attention* and **nothing else happened**: no
GitHub Issue, no workflow, no agent, no label. Nothing in FlowForge reads Notion yet.

### 7.4 Multi-contributor

Only the maintainer's account exists (decision for Prompt 32). Person fields of the test data use
it. The schema (`Requested by`, `Created by`, `Owners`), the *My Needs* view and the permission
model (§6) support several contributors; **real multi-account collaboration is NOT VERIFIED
LIVE**. Rows created through the API show the token's bot (`FlowForge Provisioning`) as
`Created by`; *My Needs* still finds them through `Requested by`.

------

## 8. 📤 Ready for Prompt 33: submission rules

The space carries everything the submission job needs. Before creating an Issue it must check,
in this order, and stop with `Integration status = Error` at the first failure:

| Check | Property |
|---|---|
| `Submit` is ticked | `Submit` |
| `GitHub Issue` is empty (else: already submitted, never a second Issue) | `GitHub Issue` |
| `FlowForge Status` is `Draft` or empty | `FlowForge Status` |
| `Title` and `Need` non-empty, within length limits, title on one line | `Title`, `Need` |
| exactly one `Project`, and it is `Active` | `Project` → `Active` |
| exactly one `Target repository`, `FlowForge enabled` | `Target repository` → `FlowForge enabled` |
| the repository belongs to the Need's Project | `Target repository` → `Project` = `Project` |
| `GitHub repository` is `owner/name` **and in the FlowForge allowlist (Git)** | `GitHub repository` |

**Idempotence**: the stable key is the Need's **Notion page ID** (immutable), written as a hidden
marker in the Issue body; `GitHub Issue` non-empty is the first guard; a lookup of the marker in
the target repository before creating covers a crash between the two writes (model §14).

------

## 9. 🔐 Credentials and identities

### 9.1 The provisioning token (this prompt)

| Item | Value |
|---|---|
| Kind | Notion **personal access token** `FlowForge Provisioning` (Developer tools → Personal access tokens); capability *Notion API* on, *Workers* off |
| Identity | appears as a bot owned by the maintainer; acts with the maintainer's access to the **whole workspace**, not only the `FlowForge` page |
| Use | local only, `NOTION_TOKEN` in the maintainer's shell, for `bootstrap.sh`, `--check` and `seed-test-data.sh` |
| Handling | never printed, logged or written; passed to curl through a file descriptor, not argv; never in the repository, never an Actions secret |
| Scope control | the scripts write **only under** `NOTION_PARENT_PAGE_ID` / the recorded parent page |
| After Prompt 32 | revoke it, or keep it only for `--check` audits; **never** reused as the runtime credential |

> ⚠️ **Warning**: a personal access token is broader than the internal connection of model §19.3
> (it sees every page of the maintainer and returns the owner's e-mail through `/users/me`).
> Accepted for a short, local, maintainer-run provisioning; not acceptable for automation.

### 9.2 Identity separation (Prompts 33/34, not created here)

| Credential / identity | Responsibility | Never |
|---|---|---|
| **Notion Bridge** identity (future, GitHub) | create the initial GitHub Issue of a submitted Need, in allowlisted targets only | modify code, push, merge, apply `agent:*` labels, dispatch Developer, replace the FlowForge App |
| **FlowForge App** (existing) | agent publication: push agent branches, open Draft PRs, Project sync | unchanged by Phase 7; **no `issues: write` added** (keeps the anti-loop guard, [architecture.md §2.10](../architecture.md#210-delivery-identity-flowforge-github-app-issue-34)) |
| `GITHUB_TOKEN` | workflow-local actions in the caller's repository | — |
| `CLAUDE_CODE_OAUTH_TOKEN` | Anthropic / Claude Code in agent jobs | never in a job that holds `NOTION_TOKEN` |
| `NOTION_TOKEN` (future runtime) | read Needs / Projects / Repositories, update Need properties | a separate **internal connection**, shared with the three databases only; secret of the **FlowForge** repository only, never in targets |
| Provisioning token (§9.1) | schema and test data, locally | runtime use |

### 9.3 Central integration (future)

```text
                 FlowForge repository  (the only place holding NOTION_TOKEN)
                    │
   Requester        ├── submission workflow  (Prompt 33, workflow_dispatch by a maintainer)
   Submit ✔ ───────►│      Notion → validate → Notion Bridge identity → GitHub Issue (Backlog)
                    │
                    └── feedback workflow    (Prompt 34)
                           GitHub Project / Issue / PR → Notion (one way, best-effort)

   repo-a ─┐
   repo-b ─┼── unchanged: no Notion logic, no NOTION_TOKEN
   repo-c ─┘
```

Then the normal lifecycle: Issue → Refiner (on demand) → `READY` → human `agent:ready` → Developer
→ Reviewer ⇄ Iterator → human merge. Notion never triggers any of it.

### 9.4 Trust model

> **Everything read from Notion is untrusted user input**: `Title`, `Need`, URLs, notes, select
> values, and the Projects / Repositories rows themselves. None of it is an instruction (model §19).

------

## 10. ▶️ Commands

```bash
# NOTION_TOKEN must be in the environment (exported before starting the shell / Claude Code)
export NOTION_PARENT_PAGE_ID=3f86f28f-f5ca-81ad-b505-f1760753b14b   # optional once config/notion.json exists

scripts/notion/bootstrap.sh            # create or converge, write config/notion.json
scripts/notion/bootstrap.sh --check    # read-only audit, exit 1 on drift
scripts/notion/seed-test-data.sh       # test rows, idempotent by title
```

To **recreate** the space elsewhere: create an empty page, set `NOTION_PARENT_PAGE_ID` to it, move
`config/notion.json` aside, run `bootstrap.sh`, then the manual steps of §6.

------

## 11. ✅ Validation (2026-10-13)

| Check | Result |
|---|---|
| First run creates 3 databases, relations, 6 views; writes `config/notion.json` | PASS |
| Second run makes no write call (only rewrites the identical IDs file) | PASS |
| `bootstrap.sh --check` | PASS: "Notion space conforms to the model" |
| `seed-test-data.sh` twice: second run creates nothing | PASS |
| Relations readable from both sides | PASS (§4) |
| *Needs attention* filter, evaluated on the data source | PASS: selects `NEED-2` only |
| Views rendered in the Notion UI (grouping, `me` filter) | NOT VERIFIED by Claude (API read-back only): the maintainer should open each view once |
| No GitHub Issue, no workflow, no agent, no FlowForge App change | PASS: no GitHub call in this prompt |

------

## 12. ⚠️ Limits

- Notion does not enforce required fields, relation consistency (§7.2) or per-property editors:
  all three are enforced by the integration (Prompt 33) or by overwrite (Prompt 34).
- Relation limit "1 page" and sharing are manual (§6).
- The API cannot query a view; view filters were verified by running them on the data source.
- Multi-account collaboration not verified live (§7.4).
- Rows created through the API are `Created by` the token's bot.
- The provisioning token is workspace-wide (§9.1).

------

> **Document created on**: 2026-10-13
> **Author**: FlowForge maintainers, with Claude Code
> **Version**: 1.0 — Phase 7, Prompt 32 (Notion space provisioned, nothing integrated)
