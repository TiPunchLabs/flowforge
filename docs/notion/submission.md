# 📤 FlowForge — Notion → GitHub submission

> **Status**: implemented and validated live with reservations (Phase 7, Prompt 33, 2026-10-14): see §12.
> **Scope**: one Need → at most one GitHub Issue, run by a maintainer. No status feedback (Prompt
> 34), no automatic submission, no webhook, nothing triggered in the target.
>
> **Prerequisites**: [model.md](model.md) §10, §11, §14, §15, §19 (the rules implemented here),
> [provisioning.md](provisioning.md) (the Notion space and its IDs).

------

## 🧠 Mental Model

```text
 Requester            Maintainer               FlowForge repository (notion-submit.yml)                 Target repository
 ─────────            ──────────               ────────────────────────────────────────                 ─────────────────
 Need, Submit ✔ ───►  Run workflow ──► resolve ─► prepare ──────────► deliver ─────────────► finish
                      (page ID/URL)    page ID    NOTION_TOKEN        Bridge App token         NOTION_TOKEN
                                                  read, guards,       find Issue by marker ──► Issue (raw need,
                                                  claim Pending,      or create it             no label, Backlog)
                                                  validate, render                             nothing starts
                                                                                       ──► Need: GitHub Issue,
                                                                                           Backlog, OK
```

| Who | Holds | Can | Cannot |
|---|---|---|---|
| Notion runtime integration | `NOTION_TOKEN` | read the 3 FlowForge databases, update Need properties | insert pages, comment, read users, see anything else |
| Notion Bridge GitHub App | `NOTION_BRIDGE_PRIVATE_KEY` | read and create Issues in the allowlisted targets it is installed on | push, open PRs, merge, run workflows, apply `agent:ready` with effect (§9) |
| FlowForge App | unchanged | agent delivery, Project sync | — (not used here) |

------

## 1. 🏗️ Architecture

| Part | File | Role |
|---|---|---|
| Workflow | [`.github/workflows/notion-submit.yml`](../../.github/workflows/notion-submit.yml) | `workflow_dispatch` in FlowForge only; two jobs (`resolve`, `submit`) |
| Helper | [`.github/scripts/flowforge-notion.sh`](../../.github/scripts/flowforge-notion.sh) | every rule: page ID, parsing, validation, sanitising, rendering, lookup, write-back |
| IDs | [`config/notion.json`](../../config/notion.json) | data source IDs and API version (Prompt 32), not duplicated in the workflow |
| Allowlist | [`config/notion-allowlist.json`](../../config/notion-allowlist.json) | repositories the submission may write to; **routing truth**, reviewed by pull request |
| Tests | [`tests/notion-submit.sh`](../../tests/notion-submit.sh) | stubbed Notion and GitHub, pre-commit hook `notion-submit` |

Targets get nothing: no caller, no Notion logic, no Notion credential. The Bridge App is only
*installed* on them.

------

## 2. ▶️ Running a submission

1. A requester fills a Need (`Title`, `Need`, `Project`, `Target repository`, `Priority`) and
   ticks `Submit`. The *Needs attention* view lists it.
2. A maintainer opens **Actions → FlowForge — Notion submit → Run workflow** on `main`, pastes the
   Need's **page URL** (or page ID), runs it.
3. The run summary gives the result, the Issue and the reason. Notion shows the same.

```bash
# Same thing from a terminal
gh workflow run notion-submit.yml -R TiPunchLabs/flowforge -f notion_page_id='<Notion page URL or ID>'
```

Input: a page ID (with or without dashes) or a Notion URL (`notion.so`, `notion.com`,
`notion.site`), whose path ends with the 32-hex page ID; query and fragment are ignored. Anything
else is `REFUSED` before any secret is read. **No repository is ever passed as input**: it comes
from the Need's `Target repository` relation, checked against the allowlist.

------

## 3. ⚙️ Workflow

| Item | Value |
|---|---|
| Trigger | `workflow_dispatch`, input `notion_page_id` (string, required) |
| Workflow permissions | `{}` |
| `resolve` job | `contents: read`, no secret; normalises the input to the canonical dashed UUID |
| `submit` job | `contents: read`, environment **`notion-bridge`**; `GITHUB_TOKEN` is never used for GitHub writes |
| Concurrency | job-level, `notion-submit-<canonical page ID>`, `cancel-in-progress: false` |
| Steps | Read and validate (`NOTION_TOKEN`) → Create Notion Bridge token (only on `PROCEED`) → Find or create the Issue (Bridge token only) → Write the outcome to Notion (`NOTION_TOKEN`, `always()`) → Report |

- The concurrency group uses the **normalised** ID (output of `resolve`), so a URL and a bare ID of
  the same Need share one lock, while two Needs never wait for each other.
- The Bridge token is minted only after validation, for the **one** allowlisted repository and
  `issues: write`; `actions/create-github-app-token` revokes it in its post step.
- The token step is `continue-on-error`: if the App is not installed on the target (or its
  credentials are wrong), the next step ends the run `FAILED` with "GitHub App has no access to
  target repository …", written to Notion. There is **no fallback** to another credential.
- Inputs and Notion values reach scripts through `env:` and files only, never `${{ }}` in `run:`.

------

## 4. ✅ Validation

Order of the checks; the first failure decides. "Write" = what the Need receives (§6).

| # | Check | Failure → result | Notion write |
|---|---|---|---|
| 0 | input is a page ID / Notion URL | `REFUSED` | none |
| 1 | page readable by the integration (404/400) | `REFUSED` | none |
| 2 | page is a live row of **FlowForge Needs** (parent data source, not trashed), with the model's properties | `REFUSED` (schema drift: `FAILED`) | none |
| 3 | `Submit` ticked | `REFUSED` | none |
| 4 | `GitHub Issue` empty | `ALREADY_SUBMITTED` | none |
| — | **claim**: `Integration status = Pending` | Notion error: `FAILED` | — |
| 5 | `Title` non-empty, ≤ 256 characters (one line after sanitising) | `REFUSED` | Error, Submit unticked |
| 6 | `Need` non-empty, ≤ 20 000 characters | `REFUSED` | Error, Submit unticked |
| 7 | `Priority` ∈ `Low`, `Medium`, `High`, `Urgent` | `REFUSED` | Error, Submit unticked |
| 8 | exactly **one** `Project` (`has_more` = more than 25 also refused) | `REFUSED` | Error, Submit unticked |
| 9 | exactly **one** `Target repository` | `REFUSED` | Error, Submit unticked |
| 10 | each related page is a live row of **its** database (Projects / Repositories) | `REFUSED` | Error, Submit unticked |
| 11 | Repository's own `Project` is exactly the Need's Project (checked first: a structural error of the Need) | `REFUSED` | Error, Submit unticked |
| 12 | Project `Active` | `REFUSED` | Error, Submit unticked |
| 13 | Repository `FlowForge enabled` | `REFUSED` | Error, Submit unticked |
| 14 | `GitHub repository` matches `owner/name` | `REFUSED` | Error, Submit unticked |
| 15 | `GitHub repository` is in `config/notion-allowlist.json` (case-insensitive; the allowlist spelling is used) | `REFUSED` | Error, Submit unticked |

Then `deliver` (§7). `FlowForge Status` is not a refusal on its own: a Need **past `Draft` with no
Issue link** lost its link, so it may only be **relinked** to an existing Issue, never get a new
one (model §14).

------

## 5. 📝 The Issue

```markdown
<!-- flowforge:notion-page-id=<page uuid> -->
## Need

<the Need text, as written>

## Context

- Project: <Project name>
- Business priority: <Priority>

## Source

- Submitted from Notion (FlowForge Needs `NEED-12`)
- Notion Need: <https://app.notion.com/p/<page id>>
```

- **Title** = Need `Title`, one line. **No** label, assignee, milestone or Project field: the
  request body has `title` and `body` only (tested).
- **No refinement**: no goal, scope or acceptance criteria. The Refiner keeps this body verbatim
  as *Original request* ([issue-contract.md](../issue-contract.md)).
- **Sanitising** (model §19.2): HTML comments removed (no forged marker), a left-over `<!--`
  escaped, `@mentions` neutralised with a zero-width space, CR removed. Length is **checked, never
  silently cut**.
- **Never crosses**: page body, `Context`, `Business reason`, people, comments, any URL read in
  Notion. The Notion link is **built** from the validated page ID.

> ⚠️ **Warning — public targets.** `demo-api` is public: `Title`, `Need`, Project name and
> priority become public on submission.

------

## 6. 🧾 Results and Notion write-back

| Result | When | Run | Need after the run |
|---|---|---|---|
| `CREATED` | Issue created | green | `GitHub Issue` = URL, `FlowForge Status` = `Backlog`, `Integration status` = `OK`, message `CREATED: Issue #N created in owner/name.` |
| `LINKED` | a Bridge Issue with this Need's marker already existed (recovery; the "equivalent explicit" of `ALREADY_SUBMITTED` for a Need whose link was lost) | green | same, message `LINKED: Existing Issue #N … found and linked; none created.`; `FlowForge Status` set to `Backlog` only if it was `Draft`/empty |
| `ALREADY_SUBMITTED` | `GitHub Issue` already set | green | unchanged |
| `REFUSED` | functional refusal (§4, invalid input, lost Issue) | green, notice | Error + message + `Submit` unticked, or unchanged (rows 0–3) |
| `FAILED` | technical: Notion/GitHub API error, missing secret, **Bridge App not installed on the target** ("GitHub App has no access to target repository …"), interruption, several marked Issues | **red** | Error + message, `Submit` **kept** (retry) — or unchanged if Notion itself is down |

- `Last synced` is stamped on every write.
- **`Submit` stays ticked after success** (decision): it records the requester's intent; the
  `GitHub Issue` link is the proof of submission and the idempotence guard. It is unticked only on
  a functional refusal, so a human must fix the Need and tick again (model §15).
- `FlowForge Status` never receives a technical state: a failed submission stays `Draft`.
- `Integration message` = `RESULT: reason`, ≤ 1900 characters, the remote service's reason
  with the operation name, never a token or a payload.

------

## 7. 🔁 Idempotence, concurrency, recovery

**Invariant: one Need → at most one Issue.**

| Layer | Mechanism |
|---|---|
| 1 | `GitHub Issue` set ⇒ `ALREADY_SUBMITTED`, no call to GitHub |
| 2 | **Marker lookup before creating**: `GET /repos/{target}/issues?state=all` (REST listing, strongly consistent, unlike search), keeping Issues **authored by the Bridge** whose body contains the marker. One found ⇒ `LINKED`; two ⇒ `FAILED` (a human keeps one) |
| 3 | Concurrency group per Need: a second run waits for the first, then hits layer 1 or 2 |
| 4 | `Pending` claimed before anything: an interrupted attempt is visible in Notion |

Only Bridge-authored Issues count: a marker pasted into someone else's Issue is ignored, so it
cannot hijack a Need's link (tested).

**Recovery — Issue created, Notion write-back failed.** The run ends `FAILED` with "Issue … exists
but the Notion write-back failed … Re-run". The Need still has no link. The re-run finds the
Issue by its marker (layer 2) and links it: `LINKED`, still one Issue. Same path if a human clears
`GitHub Issue`. A Need whose Issue was **deleted** is `REFUSED` (past `Draft`) for a human to
resolve, never silently re-created.

------

## 8. 🔐 Credentials and setup

| Credential | Purpose | Location | Scope |
|---|---|---|---|
| `NOTION_TOKEN` | read Needs / Projects / Repositories, update Need properties | secret of environment `notion-bridge` (FlowForge repo) | Notion **internal integration** `FlowForge Notion Runtime`: *Read content* + *Update content* only; connected to the 3 FlowForge databases only |
| `NOTION_BRIDGE_APP_CLIENT_ID` | identify the Bridge App | variable of `notion-bridge` | not secret |
| `NOTION_BRIDGE_PRIVATE_KEY` | mint the Bridge installation token | secret of `notion-bridge` | App `FlowForge Notion Bridge`: **Issues: read & write**, Metadata: read; since Prompt 34 also **Pull requests: read** and **Organization Projects: read** for the status feedback ([feedback.md §8](feedback.md#8--permissions-and-credentials)), the submission token still asks for `issues: write` only; installed on **selected** repositories = the allowlisted targets |
| FlowForge App | agent delivery, Project sync | unchanged | **unchanged**: no `issues` permission (anti-loop) |
| Provisioning token (Prompt 32) | — | revoked | never reused |

### 8.1 Notion runtime integration

1. Notion → **Settings → Connections → Develop or manage integrations → New integration**:
   name `FlowForge Notion Runtime`, type **Internal**, workspace of the FlowForge page.
2. **Capabilities**: *Read content* ✔, *Update content* ✔, *Insert content* ✘, *Read comments* ✘,
   *Insert comments* ✘, *User information*: **No user information**.
3. On **each** of the three databases (not the parent page): `•••` → **Connections → Connect to →
   FlowForge Notion Runtime**. The integration then sees those databases and their rows only.
4. Copy the internal integration secret into the environment secret (§8.3). Never into a file.

> 💡 **Note**: *Read content* includes the Projects and Repositories rows, needed to validate the
> relations. *Update content* is needed for the write-back. Without *Insert content* the runtime
> cannot create rows: test rows are added by hand in the UI.

### 8.2 Notion Bridge GitHub App

1. Organization **TiPunchLabs → Settings → Developer settings → GitHub Apps → New GitHub App**:
   name `FlowForge Notion Bridge`, homepage the FlowForge repository, **Webhook: inactive**.
2. **Repository permissions**: *Issues*: **Read and write**; *Metadata*: Read (mandatory);
   *Pull requests*: **Read-only** (added in Prompt 34). **Organization permissions**: *Projects*:
   **Read-only** (added in Prompt 34, the FlowForge Project is private). Nothing else: no Contents,
   Actions, Workflows, Administration, no write on Pull requests or Projects. No event subscription.
3. *Where can this App be installed*: **Only on this account**.
4. Generate a **private key**; note the **Client ID**.
5. **Install App → TiPunchLabs → Only select repositories →** the allowlisted targets (today
   `demo-api`). Not FlowForge itself, not *All repositories*.

### 8.3 Environment `notion-bridge` (FlowForge repository)

Repository → **Settings → Environments → New environment** `notion-bridge`:

- **Deployment branches and tags**: *Selected branches* → `main` (a run from another branch cannot
  read the secrets);
- secrets `NOTION_TOKEN`, `NOTION_BRIDGE_PRIVATE_KEY`; variable `NOTION_BRIDGE_APP_CLIENT_ID`.

```bash
gh secret set NOTION_TOKEN -R TiPunchLabs/flowforge --env notion-bridge            # prompts, no echo
gh secret set NOTION_BRIDGE_PRIVATE_KEY -R TiPunchLabs/flowforge --env notion-bridge < path/to/key.pem
gh variable set NOTION_BRIDGE_APP_CLIENT_ID -R TiPunchLabs/flowforge --env notion-bridge --body '<client id>'
```

The FlowForge repository is managed in `~/Workspace/02-infrastructure/flowforge/github-terraform`:
the environment and its branch policy may be added there; the secret **values** never go to
Terraform.

### 8.4 Onboarding a new target

1. add `owner/name` to `config/notion-allowlist.json` (pull request);
2. add the repository to the Bridge App installation;
3. add its row in Notion `FlowForge Repositories` (`FlowForge enabled` ✔, `Project` set).

All three are needed: Notion alone can never route an Issue anywhere.

------

## 9. 🚫 Anti-loop

The submission must never start the Developer.

1. **No label**: the Issue is created with `title` and `body` only; the helper never calls the
   labels API.
2. **No listener**: no FlowForge caller listens to `issues: opened`; the Developer listens to
   `labeled` with `agent:ready`.
3. **Guard in `agent-develop.yml`**: an `agent:ready` label event whose sender is a **Bot** is
   refused in the first step, before any state change. FlowForge's own label writes use
   `GITHUB_TOKEN`, which starts no workflow, so only a GitHub App with `issues: write` (the Bridge)
   could send such an event. `agent:ready` stays human-only.
4. **Refiner unchanged**: still dispatched by a human (`flowforge-refine.yml`); the Issue waits
   with no state label. The Project card is **not** created on submission (Prompt 28 rule:
   Issues are not added on creation); it appears in `Refining` when the Refiner starts.

------

## 10. 🛡️ Security

- Notion is **untrusted**: every value is data. No command, URL or instruction from a Need is
  executed or followed; there is no model in this workflow.
- **Routing** comes only from the relation → Repositories row → allowlist in Git. A Need that says
  "create the issue in another repository" is just text (tested).
- **Token isolation**: `NOTION_TOKEN` and the Bridge token never share a step; the Notion token is
  passed to curl through a file descriptor, never argv; nothing prints a token or an
  `Authorization` header (tested). No step runs Claude.
- **Branch-gated secrets**: environment `notion-bridge` limited to `main`.
- **Logs**: page ID, Need ID, Project, repository, result, Issue URL; never Need text.

------

## 11. 🧪 Tests

`tests/notion-submit.sh` (pre-commit hook `notion-submit`, also run in CI) drives the real helper
and step scripts with stubbed `curl` and `gh`:

| Area | Cases |
|---|---|
| Input | dashed / undashed / URL / app URL accepted; other host, shell text, `owner/repo`, short ID refused |
| Guards | unknown page, page of another database, `Submit` off, already submitted (no write, no GitHub call), Notion down (retried, `FAILED`) |
| Validation | 0 / 2 / >25 Projects, 0 / 2 repositories, mismatch, disabled, inactive, not allowlisted, malformed repository, relation to the wrong database, empty title / need, long title, no priority |
| Success | `CREATED`, request = `title` + `body` only, body format, write-back values, `Submit` untouched, token only in the header |
| Idempotence | re-run `ALREADY_SUBMITTED`; failed write-back → `FAILED` → re-run `LINKED`, one Issue; cleared link `LINKED`; lost Issue past Draft `REFUSED`; forged marker ignored; two marked Issues `FAILED` |
| Failures | GitHub create error (Error, `Submit` kept), Bridge App not installed on the target (explicit reason, no GitHub call, no fallback), interrupted run |
| Injection | Need text with instructions, a forged marker, an open comment, mentions: one Issue in the related repository, one marker, neutralised |
| Workflow | trigger, permissions, environment, concurrency, no `${{ }}` in `run:`, token scopes and separation |
| Developer | bot-applied `agent:ready` refused before any call; human-applied goes on |

------

## 12. 📋 Live validation

Done on 2026-10-14 from `main` `0213509`, recorded in
[`docs/milestones/phase7-notion-submission.md`](../milestones/phase7-notion-submission.md):
`NEED-5` → `CREATED` demo-api #47 → rerun `ALREADY_SUBMITTED`; injection `NEED-6` → `CREATED` #48
in demo-api only; mismatch `NEED-4` → `REFUSED`; no run started in demo-api. Recovery,
concurrency and "App not installed" are covered by tests only (**NOT VERIFIED LIVE**).

------

## 13. ⚠️ Limits

> ⚠️ **POC limitation**: submission is manually triggered with `workflow_dispatch`.
> **Future**: automatic triggering may be added later.

- No automatic submission, no webhook: ticking `Submit` alone does nothing until a maintainer runs the workflow.
- No GitHub → Notion status feedback after `Backlog` (Prompt 34).
- The marker lookup lists every Issue of the target (paginated): fine at POC size, to revisit for
  large repositories.
- Edits of a Need after submission are not propagated (model §13).
- Notion cannot lock properties: integration-owned values are protected by overwrite only.

------

> **Document created on**: 2026-10-13
> **Author**: FlowForge maintainers, with Claude Code
> **Version**: 1.0 — Phase 7, Prompt 33 (submission implemented)
