![FlowForge](assets/flowforge.png)

# 🔥 FlowForge

> **Status: experimental — Phase 4 (Iterator) validated end to end, with reservations ([milestone](docs/milestones/phase4-iterator-e2e.md)).** Nothing here is production-ready.

FlowForge is a **central repository** that orchestrates AI-assisted software development
across several GitHub repositories: it configures them declaratively and provides the
workflows and agent rules that turn a well-written Issue into a Draft Pull Request.

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
    FF --> WF[Reusable GitHub Actions<br/>agent-develop.yml]
    FF --> AG[Agents<br/>developer.md, reviewer.md, iterator.md]

    TF -- labels, variables, rulesets --> T[Target repository]
    T --> I[Issue + agent:ready]
    I --> C[flowforge-agent.yml]
    C -- workflow_call --> WF
    WF --> CC[Claude Code]
    AG -.rules.-> CC
    CC --> PR[Branch agent/&lt;n&gt;-&lt;slug&gt;<br/>+ Draft PR]
    PR --> H[Human review & merge]
```

Details: [docs/architecture.md](docs/architecture.md).

------

## 🔀 Target workflow: Issue → Draft PR

```text
GitHub Issue → label agent:ready → target workflow → FlowForge reusable workflow
→ Claude Code → branch agent/<issue>-<slug> → code + tests → Draft PR → human validation
```

The agent never pushes to `main` and never merges. See [agents/developer.md](agents/developer.md).

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

## 🚀 Phase 1

Goal: make the flow above work end to end on one POC repository, `demo-api`
(FastAPI + pytest), with the Issue *"Add GET /health"*.

Full plan: [docs/phase-1.md](docs/phase-1.md).

| Phase | Status |
|---|---|
| Phase 1 — Foundation | ✅ Done |
| Phase 2 — Developer E2E | ✅ Done — tag `flowforge-phase2-e2e` |
| Phase 3 — Reviewer | ✅ Done — tag `flowforge-phase3-reviewer-e2e` ([milestone](docs/milestones/phase3-reviewer-e2e.md)) |
| Phase 4 — Iterator | ✅ Done, with reservations — tag pending ([milestone](docs/milestones/phase4-iterator-e2e.md)) |

Later phases (not started): Refiner agent, GitHub Project, Notion.

------

## 🛠️ Stack

| Area | Tool |
|---|---|
| GitHub configuration | Terraform + [`integrations/github`](https://registry.terraform.io/providers/integrations/github/latest) provider |
| Orchestration | GitHub Actions reusable workflows (`workflow_call`) |
| Agent runtime | Claude Code via [`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action) (automation mode) |
| Quality | pre-commit, `terraform fmt` / `validate` |

------

## 📁 Layout

```text
.github/workflows/agent-develop.yml   reusable Developer workflow (called by targets)
.github/workflows/agent-review.yml    reusable Reviewer workflow (called by targets)
.github/workflows/agent-iterate.yml   reusable Iterator workflow (one iteration, no loop yet)
.github/ISSUE_TEMPLATE/feature.yml    agent-friendly issue form
agents/developer.md                   generic Developer agent rules
agents/reviewer.md                    generic Reviewer agent rules
agents/iterator.md                    generic Iterator agent rules
examples/target-repository/           caller workflows to copy into a target
terraform/                            root config + target-repository module
docs/                                 architecture and phase plans
scripts/                              maintainer helpers (empty for now)
```

------

## ✅ Local checks

```bash
pre-commit install            # once
pre-commit run --all-files    # whitespace, EOF, YAML, JSON, private keys, terraform fmt/validate, actionlint
```

The same hooks run in CI (`.github/workflows/ci.yml`) on every pull
request and on pushes to `main`.

## 🔐 Security

No token or secret is ever committed; Terraform reads `GITHUB_TOKEN` from the environment;
workflows use minimal permissions; agents only open Draft PRs. See
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
