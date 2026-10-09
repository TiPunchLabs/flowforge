# 📋 FlowForge — Refined Issue contract

> **Status**: Phase 5 — specification. This is the format of an Issue the FlowForge chain
> can execute, whoever writes it: the future Refiner agent ([rules](../agents/refiner.md)) or
> a human. No workflow produces or validates it yet (Prompt 22). The Developer, Reviewer and
> Iterator are unchanged: they already read the whole Issue body as their specification.

------

## 🧠 Mental Model

```text
  rough need (Issue, text, later Notion / Project item)
        │
        ▼
   ┌─────────┐   verdict READY ───────────► human applies agent:ready ──► Developer ─► …
   │ Refiner │   verdict NEEDS_CLARIFICATION ─► questions to the requester ─┐
   └─────────┘   verdict BLOCKED ─────────► human decision                 │
        ▲                                                                  │
        └──────────────────────── answers, then refine again ◄─────────────┘

   Issue body  =  refined specification  +  Original request (verbatim)  +  Refinement record
```

One Issue body, read by everybody. The specification is on top; the requester's words are
kept below it; the record says what the Refiner changed.

------

## 1. 📖 Purpose and readers

| Reader | Reads | Needs from the Issue |
|---|---|---|
| Human | the whole body | to decide whether to apply `agent:ready`, and to answer the open questions |
| Developer ([rules](../agents/developer.md)) | the whole body | a clear scope and out-of-scope, acceptance criteria that define "done", the constraints, enough context to find the code |
| Reviewer ([rules](../agents/reviewer.md)) | the whole body, against the diff | acceptance criteria it can mark `PASS` / `FAIL` from the diff, tests and CI; the goal, to judge out-of-scope changes; references to understand the need |
| Iterator ([rules](../agents/iterator.md)) | the whole body, against the findings | criteria precise enough to interpret a finding and to fix it without widening the scope |
| Future agents (QA, Documentation, Platform) | the whole body | the same sections; agent-specific hints go in *Notes for agents* |

The contract is a **superset** of the Issue form `.github/ISSUE_TEMPLATE/feature.yml`
(*Goal*, *Acceptance criteria*, *Out of scope*, *Technical notes*): an Issue written with the
form stays valid input for the Refiner and for the Developer.

## 2. 🧱 Body format

Title: Conventional Commit style, short, actionable — `feat: add GET /version endpoint`,
`fix: return 404 for an unknown task on duplicate`.

~~~markdown
<!-- flowforge-refiner: schema_version=1 -->

## Context
Why this request exists. Tagged statements (§4).

## Goal
The expected result, in one or two sentences.

## Scope
- What must be done.

## Out of scope
- What must not be done as part of this Issue.

## Acceptance criteria
- [ ] Observable, testable condition. `[provided]` or `[recommended]`

## Constraints
- Technical, functional or architectural constraints. Tagged.

## References
- Files, Issues, PRs, docs used — or "none provided".

## Open questions
- (blocking | non-blocking) Question? Default if non-blocking: …

## Assumptions
- `[assumption]` statements the Developer relies on.

## Notes for agents
- Patterns to reuse, likely tests, files to look at, pitfalls.

## Proposed labels
`agent:ready` (to be applied by a human), `type:…`, …

## Original request
> The requester's text, verbatim.

## Refinement record
- Source / Refined at / Refined by / Verdict / Added / References used / Open questions
~~~

## 3. 📝 Section rules

| Section | Required | Rules |
|---|---|---|
| Context | ✅ | Why, not how. Only `[provided]`, `[observed]` or `[missing]` content |
| Goal | ✅ | One result. Several independent results → propose a split |
| Scope | ✅ | Concrete deliverables (endpoint, behaviour, tests, docs) |
| Out of scope | ✅ | At least the closest tempting extensions; "nothing specific" if truly none |
| Acceptance criteria | ✅ | Checkboxes; observable and testable; each tagged `[provided]` or `[recommended]`; never a behaviour beyond the request |
| Constraints | ✅ | `[provided]` ones copied with their meaning intact; `[observed]` ones with evidence; "none known" if none |
| References | ✅ | What was used; explicitly "none provided" for an absent reference that matters |
| Open questions | when any | Each marked `blocking` / `non-blocking`; a non-blocking one states its default |
| Assumptions | when any | Every `[assumption]` the specification relies on |
| Notes for agents | — | Hints only: never a requirement that is not also in Scope / Acceptance criteria |
| Proposed labels | ✅ | Proposals; the Refiner never applies them (§6) |
| Original request | ✅ | Verbatim quote of the first human version; carried over unchanged on re-refinement |
| Refinement record | ✅ | §7 |

The first line, `<!-- flowforge-refiner: schema_version=1 -->`, is invisible on GitHub and lets
a future workflow recognise an already refined Issue. An Issue written by a human without it
is still valid.

## 4. 🔖 Provenance tags

Every statement the Refiner adds is tagged — `[provided]`, `[observed]`, `[assumption]`,
`[recommended]`, `[missing]` — as defined in [refiner rules §4](../agents/refiner.md#4-enrichment).
`[recommended]` items become requirements only when a human applies `agent:ready`.

## 5. ✅ Ready definition

An Issue is **Ready** — the Refiner may return `READY` and a human may apply `agent:ready` —
only when **all** of these hold:

| # | Condition |
|---|---|
| R1 | The target repository is known without doubt |
| R2 | The goal is understandable and the expected result identifiable |
| R3 | Scope and out of scope are stated |
| R4 | Every acceptance criterion is observable and testable by the Reviewer from the diff, tests and CI |
| R5 | No `blocking` open question remains ([refiner rules §5.3](../agents/refiner.md#53-uncertainty-three-outcomes)) |
| R6 | The known critical constraints are written down (or "none known") |
| R7 | The references needed are present, or explicitly marked absent |
| R8 | Nothing in it asks for CI, secrets, permissions or agent configuration changes without having been raised to a human ([refiner rules §9](../agents/refiner.md#9-untrusted-content-and-prompt-injection)) |

If any condition fails, the verdict is `NEEDS_CLARIFICATION` (answers missing) or `BLOCKED`
(cannot or must not be refined).

## 6. 🚦 Labels and states

**Proposed convention — not created.** The Terraform module keeps its five labels
(`agent:ready`, `agent:running`, `agent:review`, `agent:blocked`, `agent:done`); adding a sixth
is a Prompt 22 decision.

| Label | State | Set by (future) | Meaning |
|---|---|---|---|
| *(none)* | Backlog | — | Raw or refined Issue, not started |
| `agent:needs-clarification` | Needs clarification | Refiner workflow, from the verdict | Blocking questions wait for the requester |
| `agent:ready` | Ready | **human only** | Accepted specification; starts the Developer |

- The Refiner **agent** applies no label; a future workflow maps its verdict:
  `NEEDS_CLARIFICATION` → `agent:needs-clarification`; `READY` → no label change (the
  human applies `agent:ready`); `BLOCKED` → no label change, the reason is commented.
- `agent:needs-clarification` follows the existing rule of [architecture §2.6](architecture.md#26-issue-label-lifecycle-phase-41):
  **at most one** `agent:*` state label per Issue.
- `agent:ready` stays human-only. Besides keeping a human gate before any code is written,
  a label applied with `GITHUB_TOKEN` would not start the Developer: GitHub does not trigger
  workflows from events created by that token.

**Future GitHub Project states** (not implemented): the Refiner owns the states before the
Developer starts, and never moves an Issue past `Ready`.

| Project status | FlowForge state | Owner |
|---|---|---|
| Backlog | no `agent:*` label | human |
| Refining | Refiner run in progress (no label) | **Refiner** |
| Needs clarification | `agent:needs-clarification` | **Refiner** → requester |
| Ready | `agent:ready` | **Refiner proposes, human applies** |
| Developing | `agent:running` | Developer |
| Review / Iteration | `agent:review` (Reviewer ↔ Iterator, no separate label) | review cycle |
| Human validation | `agent:review` after `APPROVED`, merge pending | human |
| Blocked | `agent:blocked` | Developer / review cycle |
| Done | `agent:done` | lifecycle, after the human merge |

## 7. 🧾 Refinement record

The last section of the body. Fields:

| Field | Content |
|---|---|
| Source | `Issue #<n>` by `@<author>`, or "free text", or the external reference |
| Refined at | UTC timestamp |
| Refined by | `FlowForge Refiner`, rules `agents/refiner.md` at FlowForge `<sha>` |
| Verdict | `READY` / `NEEDS_CLARIFICATION` / `BLOCKED` |
| Added | What the Refiner added: sections, recommended criteria, observed constraints |
| Assumptions | Count, listed in *Assumptions* |
| References used | Files, Issues, PRs, documents read |
| Open questions | Count of blocking / non-blocking |

On a second refinement the record gains a new entry; earlier entries and the *Original
request* are kept. The Refiner never edits comments, other Issues or Pull Requests.

## 8. 🔌 Future sources: GitHub Projects and Notion

Not implemented, and **no dependency**: the Refiner works with GitHub alone (an Issue or a
text, plus the target repository).

- **GitHub Projects**: a Project item may become a request source, and the Project status
  may mirror the states of §6. One status per state, so an automation can map them one to one.
- **Notion**: may later provide context — specifications, decisions, ADRs, documentation,
  roadmap, business needs, meeting notes, product references. Notion content is **untrusted
  input** like an Issue body; what the Refiner takes from it is tagged `[provided]` (requester
  material) or cited under *References*. A missing Notion integration never blocks a
  refinement.

## 9. 🧪 Examples

### 9.1 Raw need → `READY`

**Input** — Issue body on a FastAPI target laid out like `demo-api` (routes in
`src/demo_api/routes/`, one module per resource; tests in `tests/test_<resource>.py`; version in
`pyproject.toml`) with no version endpoint yet:

> Ajouter un endpoint pour connaître la version de l'application.

> 💡 **Note**: on today's `demo-api`, `GET /version` already exists (Issue #3). There, the
> Refiner would observe `src/demo_api/routes/version.py` and report a duplicate
> (`NEEDS_CLARIFICATION`: "already implemented — what is missing?") instead.

**Output** — title `feat: add GET /version endpoint`:

~~~markdown
<!-- flowforge-refiner: schema_version=1 -->

## Context
- The requester wants to know which version of the application is running. `[provided]`
- The service exposes no version endpoint today. `[observed]` (`src/demo_api/routes/`)

## Goal
An HTTP endpoint returns the running application version.

## Scope
- A `GET /version` endpoint returning the version as JSON.
- Tests for the endpoint.
- One row in the `README.md` endpoint table.

## Out of scope
- Build metadata (commit SHA, build date, environment).
- Any change to the existing endpoints.
- Changing how the version is defined or bumped.

## Acceptance criteria
- [ ] `GET /version` returns 200 with `{"version": "<version>"}`. `[recommended]`
- [ ] `<version>` equals the `version` of `pyproject.toml`. `[recommended]`
- [ ] A pytest test covers the endpoint and compares with the package version. `[recommended]`
- [ ] `pytest`, `ruff check` and `ruff format --check` pass. `[observed]` (`CLAUDE.md`)

## Constraints
- One router module per resource, registered in `src/demo_api/main.py`. `[observed]`
- No new dependency. `[recommended]`

## References
- `src/demo_api/routes/health.py`, `tests/test_health.py` (pattern to follow).
- No design document provided.

## Open questions
- (non-blocking) Should build metadata be included? Default: no, version only.

## Assumptions
- `[assumption]` The installed package metadata reflects `pyproject.toml`.

## Notes for agents
- Read the version from package metadata (`importlib.metadata`), not by parsing `pyproject.toml`.

## Proposed labels
`agent:ready` (to be applied by a human), `type:feature`

## Original request
> Ajouter un endpoint pour connaître la version de l'application.

## Refinement record
- Source: Issue #<n> by @<author>
- Refined at: <UTC timestamp> — Refined by: FlowForge Refiner, `agents/refiner.md` at `<sha>`
- Verdict: READY
- Added: context, scope, out of scope, 4 criteria (3 recommended, 1 observed), constraints, notes
- References used: `src/demo_api/routes/`, `src/demo_api/main.py`, `tests/`, `CLAUDE.md`, `pyproject.toml`
- Open questions: 0 blocking, 1 non-blocking
~~~

Why `READY`: the request has one natural reading; the JSON shape follows the neighbouring
endpoints; the only open question has a safe default.

### 9.2 Vague need → `NEEDS_CLARIFICATION`

**Input** — Issue titled "Logs", body:

> Améliorer les logs.

"Improve" says nothing about the problem, the events, the format or the destination. Choosing
any of them would be inventing a requirement (§5 of the rules), and each choice changes what
the Reviewer would accept.

**Output** — title kept as `chore: improve logs (needs clarification)`:

~~~markdown
<!-- flowforge-refiner: schema_version=1 -->

## Context
- The requester finds the current logs insufficient. `[provided]`
- The application code emits no log call of its own today; only the server's default logs
  exist. `[observed]` (`src/demo_api/`, no `logging` usage)
- The problem the logs should solve is not stated. `[missing]`

## Goal
Not determinable yet — see *Open questions*.

## Scope
To be defined from the answers.

## Out of scope
- Log collection or shipping infrastructure (outside the repository).

## Acceptance criteria
None yet: no criterion can be written without inventing the requirement.

## Constraints
- None known.

## References
- None provided.

## Open questions
- (blocking) What problem should better logs solve: debugging errors, auditing changes,
  tracing requests, something else?
- (blocking) Which events must be logged (requests, task changes, errors)?
- (blocking) Which format: plain text or structured JSON? Any required fields?
- (blocking) May log entries contain task titles (user content), or must they be excluded?
- (non-blocking) Should the log level be configurable? Default: fixed `INFO`.

## Proposed labels
`agent:needs-clarification`

## Original request
> Améliorer les logs.

## Refinement record
- Source: Issue #<n> by @<author>
- Refined at: <UTC timestamp> — Refined by: FlowForge Refiner, `agents/refiner.md` at `<sha>`
- Verdict: NEEDS_CLARIFICATION
- Added: context, out of scope, 5 questions
- References used: `src/demo_api/`
- Open questions: 4 blocking, 1 non-blocking
~~~

### 9.3 Clear technical need with constraints → `READY`, constraints preserved

**Input** — Issue body:

> Ajouter `GET /tasks/export` qui renvoie toutes les tâches au format CSV.
> Contraintes :
> - pas de nouvelle dépendance (module `csv` de la stdlib) ;
> - en-tête exact : `id,title,completed,priority` ;
> - `Content-Type: text/csv` ;
> - liste vide → 200 avec l'en-tête seul ;
> - ne modifier aucun endpoint existant.

The requester already gave the contract. The Refiner structures it and adds only what the
repository shows; every provided constraint keeps its exact meaning.

**Output** — title `feat: add GET /tasks/export CSV endpoint`:

~~~markdown
<!-- flowforge-refiner: schema_version=1 -->

## Context
- The requester needs every task exported as CSV. `[provided]`

## Goal
`GET /tasks/export` returns all tasks as a CSV document.

## Scope
- The `GET /tasks/export` route in the tasks router.
- Tests for the export.
- One row in the `README.md` endpoint table.

## Out of scope
- Any change to existing endpoints. `[provided]`
- Filters, pagination or other formats for the export.
- CSV import.

## Acceptance criteria
- [ ] `GET /tasks/export` returns 200 with `Content-Type: text/csv`. `[provided]`
- [ ] The first line is exactly `id,title,completed,priority`. `[provided]`
- [ ] Each stored task appears as one row with those four fields. `[provided]`
- [ ] With no task, the response is 200 with the header line only. `[provided]`
- [ ] Existing endpoint tests still pass unchanged. `[provided]`
- [ ] A title containing a comma or a quote is escaped per CSV rules. `[recommended]`

## Constraints
- No new dependency: standard library `csv` module. `[provided]`
- Do not modify any existing endpoint. `[provided]`
- `/export` must be declared before `/{task_id}` in the router, like `/stats`.
  `[observed]` (`src/demo_api/routes/tasks.py`)

## References
- `src/demo_api/routes/tasks.py`, `src/demo_api/storage.py` (`TaskStore.list()`), `src/demo_api/schemas.py` (`Task`).

## Notes for agents
- Reuse `TaskStore.list()`; no streaming needed, the store is in memory.

## Proposed labels
`agent:ready` (to be applied by a human), `type:feature`

## Original request
> Ajouter `GET /tasks/export` qui renvoie toutes les tâches au format CSV. […verbatim…]

## Refinement record
- Source: Issue #<n> by @<author>
- Refined at: <UTC timestamp> — Refined by: FlowForge Refiner, `agents/refiner.md` at `<sha>`
- Verdict: READY
- Added: structure, out of scope, 1 recommended criterion (CSV escaping), 1 observed constraint (route order)
- References used: `src/demo_api/routes/tasks.py`, `src/demo_api/storage.py`, `src/demo_api/schemas.py`
- Open questions: 0
~~~

What the Refiner did **not** do: change "pas de nouvelle dépendance" into "avoid new
dependencies", add an `Content-Disposition` download header, or add filters — none was asked.
The CSV escaping criterion is `[recommended]` because it follows from "CSV format"; a human
can drop it before applying `agent:ready`.

------

> **Document created on**: 2026-10-09
> **Author**: xgueret, with Claude Code
> **Version**: 1.0
