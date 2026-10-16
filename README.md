![FlowForge](assets/flowforge.png)

# 🔥 FlowForge

> **Status: experimental — Phases 1–7 validated end to end, with reservations listed in each [milestone](docs/milestones/) (Notion Need → Issue → Refiner → Developer → Reviewer ⇄ Iterator → human merge, mirrored on a GitHub Project and back to Notion). Latest: Phase 7 — Notion ([closure](docs/milestones/phase7-notion-complete.md)). Next: Phase 8, not defined yet.** Nothing here is production-ready.

FlowForge is a **central repository** that orchestrates AI-assisted software development
across several GitHub repositories: it configures them declaratively and provides the
workflows and agent rules that turn a raw need into a refined Issue, then into a Draft Pull
Request that a human merges.

------

## 📖 The problem

Using a coding agent on one repository is easy. Using it on **many** repositories leads to:

- copies of the same workflows, prompts and rules drifting apart in every repo;
- hand-configured labels, permissions and branch protections, different in each repo;
- no single place to improve the agent's behavior or tighten its permissions.

## 🎯 The approach: 1 FlowForge → N target repositories

| FlowForge owns (once) | Each target repository owns |
|---|---|
| Terraform module to onboard a repo | Its code and tests |
| Reusable GitHub Actions workflows | Its CI |
| Generic agent rules (`agents/`) | Its `CLAUDE.md` (project conventions) |
| | A ~20-line `flowforge-agent.yml` calling FlowForge |

------

## 🏗️ Architecture

```mermaid
flowchart TD
    FF[FlowForge] --> TF[Terraform<br/>target-repository module]
    FF --> WF[Reusable GitHub Actions<br/>agent-refine.yml, agent-develop.yml, review-cycle.yml]
    FF --> AG[Agents<br/>refiner.md, developer.md, reviewer.md, iterator.md]

    TF -- labels, variables, default-branch ruleset --> T[Target repository]
    T --> N[Raw need, Issue]
    N -- workflow_dispatch --> RF[Refiner<br/>agent-refine.yml]
    RF -- READY --> HR[Human applies agent:ready]
    HR --> I[Issue + agent:ready]
    I --> C[flowforge-agent.yml]
    C -- workflow_call --> WF
    WF --> CC[Claude Code]
    AG -.rules.-> CC
    CC --> PR[Branch agent/&lt;n&gt;-&lt;slug&gt;<br/>+ Draft PR]
    PR --> RC[Reviewer ↔ Iterator<br/>review-cycle.yml, ≤ 3 passes]
    RC --> H[Human GitHub approval & merge<br/>enforced by the ruleset]
    RF & WF & RC & H -. status, one way .-> GP[GitHub Project<br/>FlowForge Development]
```

Details: [docs/architecture.md](docs/architecture.md).

------

## 🔀 Target workflow: Issue → Draft PR

```text
GitHub Issue → label agent:ready → target workflow → FlowForge reusable workflow
→ Claude Code → branch agent/<issue>-<slug> → code + tests → Draft PR → human validation
```

The agent never pushes to `main` and never merges. See [agents/developer.md](agents/developer.md).
Claude only commits: the workflow verifies the commits, then pushes the branch and opens the
Draft PR with the **FlowForge GitHub App** (one App for all targets), so the target's CI runs
on agent PRs without manual approval. To connect a new repository, follow
[docs/target-onboarding.md](docs/target-onboarding.md).

Phase 3 adds a **Reviewer** between the Draft PR and the human review. It is defined in
[agents/reviewer.md](agents/reviewer.md) and run by the reusable workflow
`agent-review.yml`; its first end-to-end run on `demo-api` is validated
([milestone](docs/milestones/phase3-reviewer-e2e.md)):

```text
Issue → Developer → Draft PR → Reviewer → APPROVE | REQUEST_CHANGES | BLOCKED → human review
```

The Reviewer is read-only: it produces structured findings and a verdict (one PR comment +
a JSON artifact), never commits nor merges.

Phase 4 defines an **Iterator** ([agents/iterator.md](agents/iterator.md)) that fixes the
findings of a `REQUEST_CHANGES` review on the existing PR branch, then hands the PR back to
the Reviewer, in a loop bounded to 3 iterations. One iteration is run by the reusable
workflow `agent-iterate.yml`; the loop is orchestrated by `review-cycle.yml`, which only
decides who runs and when:

```text
Issue → Developer → Draft PR → Reviewer → REQUEST_CHANGES → Iterator → Reviewer → …
        stops on APPROVE, BLOCKED, or after 3 Iterator passes (MAX_ITERATIONS_REACHED)
```

The cycle never merges, never marks the PR ready for review: the final merge stays human.

------

## 🛡️ Human merge gate

The last step is a **human** decision, enforced by GitHub, not only by convention. The
Terraform module puts a ruleset on the target's default branch: pull request required, at
least one GitHub approval, approvals dismissed by new pushes, no force push, no deletion, no
bypass for FlowForge.

```text
Reviewer APPROVE → cycle APPROVED → PR still Draft and unmerged
→ human: Ready for review → GitHub approval → merge → agent:done
```

A Reviewer `APPROVE` is an agent verdict posted as a PR comment; it is **not** a GitHub
approval and does not count for the ruleset. Agent PRs are authored by the FlowForge GitHub
App (`GITHUB_TOKEN` fallback), which cannot approve its own PRs; no FlowForge workflow
approves, merges or enables auto-merge. Details: [docs/architecture.md §2.7](docs/architecture.md#27-human-merge-gate-phase-41).

------

## 🚀 Roadmap

Phase 1 goal: make the flow above work end to end on one POC repository, `demo-api`
(FastAPI + pytest), with the Issue *"Add GET /health"*. Plan: [docs/phase-1.md](docs/phase-1.md).

| Phase | Status |
|---|---|
| Phase 1 — Foundation | ✅ Done |
| Phase 2 — Developer E2E | ✅ Done — tag `flowforge-phase2-e2e` |
| Phase 3 — Reviewer | ✅ Done — tag `flowforge-phase3-reviewer-e2e` ([milestone](docs/milestones/phase3-reviewer-e2e.md)) |
| Phase 4 — Iterator | ✅ Done, with reservations — tag `flowforge-phase4-iterator-e2e` ([milestone](docs/milestones/phase4-iterator-e2e.md)) |
| Phase 4.1 — Hardening & lifecycle | ✅ Done, validated E2E, one reservation — tag `flowforge-phase4.1-hardening-e2e` ([milestone](docs/milestones/phase41-hardening-e2e.md)) |
| Phase 5 — Refiner agent | ✅ Done, validated E2E, with reservations — tag `flowforge-phase5-refiner-e2e` ([milestone](docs/milestones/phase5-refiner-e2e.md)) |
| Phase 6 — GitHub Projects / Kanban | ✅ Done, validated E2E, with reservations — tag `flowforge-phase6-github-projects-e2e` ([milestone](docs/milestones/phase6-github-projects-e2e.md)) |
| Phase 7 — Notion | ✅ Done, validated E2E, with reservations ([closure](docs/milestones/phase7-notion-complete.md)); tag `flowforge-phase7-notion-e2e` after the closure merge |

Phase 4.1 covers: Iterator partial delivery (#17), closed / merged PR = `NO_OP` (#18), Issue
label lifecycle up to `agent:done` (#19), and the human merge gate (default-branch ruleset).
Each is covered by offline tests and was validated live on `demo-api` on 2026-10-09.

**Phase 5 — Refiner (done)**: turn a rough human need into a
structured, executable Issue that the existing chain consumes. Started on demand
(`gh workflow run flowforge-refine.yml -f issue_number=<n>` in the target); verdict `READY`,
`NEEDS_CLARIFICATION` (label `agent:needs-clarification`) or `BLOCKED`. A human still applies
`agent:ready`:

```text
rough human need → Refiner → structured Issue → Developer → Reviewer ⇄ Iterator → human
```

Refiner validated in isolation (Prompt 23, [milestone](docs/milestones/phase5-refiner-simple-cases.md))
and end to end in the chain (Prompt 24, [milestone](docs/milestones/phase5-refiner-e2e.md)), then
closed with reservations (Prompt 25, same milestone §13). The Refiner is optional: a hand-written
`agent:ready` Issue still goes straight to the Developer.

**Phase 6 — GitHub Projects / Kanban (done)**: the org Project `FlowForge Development` shows
where each need is. The workflows write its status one way, best-effort, through the FlowForge
App token; the Project never starts an agent:

```text
Backlog → Refining → Ready → Developing → Review ⇄ Iteration → Human validation → Done
```

Model ([kanban-model.md](docs/github-projects/kanban-model.md)), provisioning
([provisioning.md](docs/github-projects/provisioning.md)), sync
([synchronization.md](docs/github-projects/synchronization.md)); validated live on `demo-api`
(#39 main E2E, #45 `Review → Iteration → Review`) and closed in Prompt 30
([milestone](docs/milestones/phase6-github-projects-e2e.md) §19).

**Phase 7 — Notion (done)**: a shared Notion `Needs` database where people without GitHub can
write a need in plain words for a Project and one of its repositories. A maintainer submits it
(`notion-submit.yml`): it becomes **one** raw GitHub Issue in `Backlog`, created by the dedicated
Notion Bridge App. A central reconciler (`notion-sync.yml`, scheduled + on demand) mirrors its
status, PR and completion back to Notion, one way. Notion never starts an agent, applies a label
or merges; the Refiner still structures the need and a human still applies `agent:ready` and
merges. Model ([model.md](docs/notion/model.md)), provisioning
([provisioning.md](docs/notion/provisioning.md)), submission ([submission.md](docs/notion/submission.md)),
feedback ([feedback.md](docs/notion/feedback.md)); validated live on `demo-api` and `demo-api-2`
with two contributors and two Projects, closed in Prompt 36
([milestone](docs/milestones/phase7-notion-complete.md)).

**Future (not implemented)**: QA agent, Documentation
agent, self-hosted runners, GitHub Project reconciliation job (the Notion reconciler exists).

------

## 🛠️ Stack

| Area | Tool |
|---|---|
| GitHub configuration | Terraform + [`integrations/github`](https://registry.terraform.io/providers/integrations/github/latest) provider |
| Orchestration | GitHub Actions reusable workflows (`workflow_call`) |
| Agent runtime | Claude Code via [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action) (automation mode) |
| Project board | GitHub Projects (org Project, GraphQL via GitHub CLI) |
| Quality | pre-commit, `terraform fmt` / `validate` / `test`, actionlint, Bash test suites (`tests/`) |

------

## 📁 Layout

```text
.github/workflows/agent-develop.yml   reusable Developer workflow (called by targets)
.github/workflows/agent-review.yml    reusable Reviewer workflow (called by targets)
.github/workflows/agent-iterate.yml   reusable Iterator workflow (one iteration per call)
.github/workflows/review-cycle.yml    reusable bounded Reviewer ↔ Iterator loop (≤ 3 Iterator passes)
.github/workflows/agent-lifecycle.yml reusable lifecycle workflow (Issue terminal state on PR close)
.github/workflows/agent-refine.yml    reusable Refiner workflow (refines one Issue, read-only agent)
.github/scripts/flowforge-state.sh    agent:* state label transitions (one state per Issue)
.github/scripts/flowforge-refine.sh   Refiner result validation and refined body rendering
.github/scripts/flowforge-project.sh  GitHub Project sync (one way, best-effort, stale guard)
.github/workflows/notion-submit.yml   FlowForge-only Notion Need → GitHub Issue submission (Notion Bridge App)
.github/workflows/notion-sync.yml     FlowForge-only GitHub → Notion status feedback (central reconciler)
.github/scripts/flowforge-notion.sh   Notion submission rules (validation, sanitising, marker lookup)
.github/scripts/flowforge-notion-sync.sh  Notion feedback (correlation, mapping, idempotent write-back)
.github/ISSUE_TEMPLATE/feature.yml    agent-friendly issue form
agents/developer.md                   generic Developer agent rules
agents/reviewer.md                    generic Reviewer agent rules
agents/iterator.md                    generic Iterator agent rules
agents/refiner.md                     generic Refiner agent rules (Phase 5)
examples/target-repository/           caller workflows to copy into a target
terraform/                            root config + target-repository module (labels, ruleset…)
docs/                                 architecture, target onboarding, refined Issue contract, phase plans, milestones
docs/github-projects/                 Kanban model, Project provisioning, workflow → Project sync
docs/notion/                          Notion model, provisioning, submission, feedback (Phase 7)
scripts/github-projects/              maintainer CLI: bootstrap.sh (provision / --check), sync-issue.sh
scripts/notion/                       maintainer CLI: bootstrap.sh (provision / --check), seed-test-data.sh
config/github-project.json            generated, non-secret Project IDs (written by bootstrap.sh)
config/notion.json                    generated, non-secret Notion IDs (written by scripts/notion/bootstrap.sh)
config/notion-allowlist.json          repositories Notion submissions may target (hand-edited, reviewed by PR)
tests/                                offline tests of the workflows' step scripts (run by pre-commit)
```

------

## ✅ Local checks

```bash
pre-commit install            # once
pre-commit run --all-files    # whitespace, EOF, YAML, JSON, private keys, terraform fmt/validate/test,
                              # actionlint, and the tests/*.sh suites (no network, no token)
```

The same hooks run in CI (`.github/workflows/ci.yml`) on every pull
request and on pushes to `main`.

## 🔐 Security

No token or secret is ever committed; Terraform reads `GITHUB_TOKEN` from the environment;
workflows use minimal permissions; agents only open Draft PRs, and a default-branch ruleset
requires a human approval to merge. See
[docs/architecture.md §4](docs/architecture.md#4--security-model).

## 💡 Inspiration

FlowForge is inspired by [big-emotion/ferry](https://github.com/big-emotion/ferry), a
GitHub Actions–native agent pipeline that turns Jira column moves into reviewed draft PRs,
with no server and no daemon.

Ideas borrowed from ferry: the split into specialized agents (Refiner, Developer, Reviewer,
Iterator) and the rule that agents open Draft PRs but never merge. FlowForge reimplements them
independently on GitHub Issues: a label (`agent:ready`) replaces the Jira column move, and one
central repository serves several target repositories through reusable workflows. No ferry
code is included.

## 📄 License

[MIT](LICENSE)
