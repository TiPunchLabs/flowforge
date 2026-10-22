# 🚀 Getting started with FlowForge

> **Objective**: connect an existing GitHub repository (a *target*) to FlowForge, then take a
> first request from a raw Issue to a human-merged pull request.
> **Prerequisites**: admin access to the target repository; an organization owner for the
> one-time organization setup and for adding the target to shared lists; Terraform ≥ 1.6, the
> GitHub CLI (`gh`), `jq`, `yq` and a local checkout of FlowForge; the target already has CI.
> **Estimated duration**: about one hour for the repository and its configuration, plus the time
> the project owner needs to validate `SPEC.md`.
> **Version**: FlowForge `v0.1.0`, an experimental POC version (no stability guarantee).

This guide gives the steps in order. The detailed reference, with every check and its reasons,
is [docs/target-onboarding.md](docs/target-onboarding.md). When the two disagree, that reference
is right; please report the difference.

------

## 🧠 Mental Model

```text
  Step 1   ORGANIZATION (once)        App, 2 secrets, 2 variables, org Project
  Step 2   FUNCTIONAL (per target)    CLAUDE.md + SPEC.md, validated by the project owner
  Step 3   TERRAFORM  (per target)    module target-repository: labels, merge ruleset, token settings
  Step 4   CALLERS    (per target)    5 thin workflows, pinned to one FlowForge commit
  Step 5-6 CHECKS                     permissions + readiness R1–R18: PASS / FAIL / NOT_VERIFIED
  Step 7   FIRST REQUEST              Issue → Refiner → human agent:ready → Developer → Draft PR
                                      → Reviewer ⇄ Iterator → human approval + merge → agent:done
```

FlowForge never starts by itself. Every agent run starts with a human action: a dispatched
workflow, or the `agent:ready` label. Every merge is human.

------

## 📋 Table of contents

1. Understand the prerequisites
2. Prepare the existing repository
3. Configure Terraform
4. Configure GitHub Actions
5. Check the permissions
6. Check the onboarding
7. Create a first request
8. Understand the results
9. Troubleshooting

In the commands below, set these once:

```bash
R=TiPunchLabs/<target>              # the target repository, owner/name
FF=~/path/to/flowforge              # your local FlowForge checkout
APP=tipunchlabs-flowforge           # FlowForge GitHub App slug
```

------

## 🏢 1. Understand the prerequisites

Three levels, set up by different people. Only levels B and C are repeated for each target.

| Level | Who | When | What |
|---|---|---|---|
| **A. Organization** | organization owner | **once** for all targets | FlowForge repository (public), FlowForge GitHub App, secrets and variables, organization Project, Actions policy |
| **B. Repository** | target admin + organization owner | **per target** | Terraform module, five caller workflows, target added to the App installation and to the secret/variable lists, target CI |
| **C. Functional** | target owner | **per target** | `CLAUDE.md` and `SPEC.md` on the default branch |

### 1.1 🏢 Level A, done once

If FlowForge is already used in the organization, all of this exists: a new target only checks
it (step 5).

| Item | Value |
|---|---|
| FlowForge repository | `TiPunchLabs/flowforge`, **public**, so any repository can call its reusable workflows |
| FlowForge GitHub App | one App for all targets. Repository permissions: Contents and Pull requests read & write; organization permissions: Projects read & write; **no Issues permission** |
| Secret `CLAUDE_CODE_OAUTH_TOKEN` | from `claude setup-token`; required by every agent |
| Secret `FLOWFORGE_APP_PRIVATE_KEY` | the App's private key; recommended |
| Variable `FLOWFORGE_APP_CLIENT_ID` | the App's client ID; recommended |
| Variable `FLOWFORGE_PROJECT_NUMBER` | the organization Project number; optional (unset = no Project sync) |
| Organization Project | `FlowForge Development`, created by `scripts/github-projects/bootstrap.sh` ([provisioning](docs/github-projects/provisioning.md)) |
| Actions policy | lets the targets call actions and reusable workflows from other repositories |

Secrets and variables are stored **at organization level** with *Selected repositories*
visibility, never in Git and never in Terraform. Creating them is described in
[target-onboarding.md §1.2](docs/target-onboarding.md#12--secrets-and-variables).

> 💡 **Note**: without the App, FlowForge still works with `GITHUB_TOKEN`. But every agent PR
> then shows *Approve workflows to run*: its CI waits for a manual approval, and the Project is
> not synchronized.

### 1.2 📦 Levels B and C, done for each target

| Item | Step |
|---|---|
| `CLAUDE.md`, `SPEC.md` merged on the default branch | 2 |
| Terraform module instantiated in **one** state, plan reviewed, apply done | 3 |
| Five callers in `.github/workflows/`, pinned to one FlowForge version | 4 |
| Target added to the App installation and to the four secret/variable lists | 5 |
| A `pull_request` CI workflow, without a `paths:` filter | 4 |

------

## 📖 2. Prepare the existing repository

The agents need two files at the root of the default branch.

| File | Role | Who writes it | Who validates it |
|---|---|---|---|
| `CLAUDE.md` | how to work in the project: stack, test / lint / format commands, conventions. Agents read it first | the target team | the target owner |
| `SPEC.md` | what the product **is**: the functional contract. Features `F-xxx`, rules `R-xxx` and scenarios `S-xxx`, which agents cite in Issues, reviews and PRs | prepared by the mission below | the target owner |

`SPEC.md` is **required**. Without it, the Developer refuses to start (`SPEC contract: FAILED`)
and the Refiner classifies every request `NO_SPEC`.

### 2.1 🧾 Prepare a candidate `SPEC.md`

Do not write the specification by hand from scratch. Run the **target preparation mission**,
[docs/preparation-projet-existant-pour-flowforge.md](docs/preparation-projet-existant-pour-flowforge.md)
(written in French): give its text to Claude Code, **inside the target repository**. It reads the
README, the code and the tests, then writes on a branch:

- `SPEC.md`, with the four sections of the [contract](docs/spec-contract.md). The section titles
  are exact and in the target's language: `## 1. Objective and scope`, `## 2. Features`,
  `## 3. Rules and constraints`, `## 4. Validation scenarios` for an English repository. The
  French titles are `Objectif et périmètre`, `Fonctionnalités`, `Règles et contraintes`,
  `Scénarios de validation`;
- `docs/flowforge-spec-review.md`: the sources, the contradictions, the questions for the owner,
  and which test covers each scenario.

Each requirement carries a status:

| Status | Meaning |
|---|---|
| `CONFIRMED` | documented or decided by the owner: a change must preserve it |
| `OBSERVED` | seen in the code or tests, never validated: not a requirement yet |
| `KNOWN GAP` | the expected contract and the implementation disagree: the contract wins |

The mission never changes the code, the CI or the workflows.

### 2.2 ✅ Validate it (human)

1. Check the structure locally, before opening the PR:

   ```bash
   # From the target checkout. No gh, no network.
   bash "$FF/.github/scripts/flowforge-spec.sh" SPEC.md   # last line: SPEC contract: PASS
   ```

2. The **owner** reads `docs/flowforge-spec-review.md` and answers its questions. Only an owner
   decision turns an `OBSERVED` behaviour into a `CONFIRMED` requirement.
3. The owner merges the `SPEC.md` PR into the default branch.

> ⚠️ **Warning**: the check is structural only. A `PASS` proves the four sections exist, not
> that the content is right. The content is the owner's responsibility.

> ⚠️ **Warning**: a `SPEC.md` that is still in an open PR is invisible to the agents. Merge it
> before the first request.

------

## 🏗️ 3. Configure Terraform

The module [`terraform/modules/target-repository`](terraform/modules/target-repository/README.md)
manages, on an existing repository:

- the six `agent:*` labels;
- the default-branch ruleset, which is the human merge gate: pull request required, at least one
  approval, no force push, no deletion;
- the workflow token settings.

It **reads** the repository and never creates, renames or deletes it. It manages no secret.

### 3.1 🧭 One target = one state

Put the `module` block in **exactly one** Terraform state:

| Target situation | Where the `module` block lives |
|---|---|
| The target already has its own Terraform (preferred) | its IaC, next to its `github_repository`, with `repository = github_repository.<x>.name` |
| No Terraform of its own | FlowForge's `terraform/` root, one `module "<name>"` block (source `./modules/target-repository`) |

Never both: two states would overwrite each other's labels and ruleset on every apply.

### 3.2 📝 Minimal configuration

Consume a **tagged version** through a Git source, never a local path or a branch:

```hcl
terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

# Token from the GITHUB_TOKEN environment variable, never in a file.
provider "github" {
  owner = "TiPunchLabs"
}

module "flowforge" {
  source = "git::https://github.com/TiPunchLabs/flowforge.git//terraform/modules/target-repository?ref=v0.1.0"

  repository = "my-target" # or github_repository.<x>.name in the target's own IaC

  # Optional: solo maintainer, who cannot approve their own PRs (merge through a PR only).
  # admin_pull_request_bypass = true

  # Optional: only once the App delivers agent PRs and their CI check is visible.
  # required_status_checks = [
  #   { context = "<CI job name>", integration_id = 15368 }, # 15368 = GitHub Actions
  # ]
}
```

The module's other inputs (`labels`, `actions_variables`, `default_branch_ruleset_enabled`,
`required_approving_review_count`) have safe defaults: see the
[module README](terraform/modules/target-repository/README.md).

### 3.3 📥 Adopt what already exists

An existing repository may already have some `agent:*` labels or a ruleset. List them first:

```bash
gh api "repos/$R/labels" --paginate --jq '.[] | select(.name | startswith("agent:")) | .name'
gh api "repos/$R/rulesets" --jq '.[] | [.id, .name] | @tsv'
```

Adopt each existing object with an `import` block in the root module of the owning state, one
block per object, and remove the block after the apply:

```hcl
import {
  to = module.flowforge.github_issue_label.flowforge_labels["agent:ready"]
  id = "my-target:agent:ready" # repository:label
}
```

The ruleset and token-settings forms are in
[target-onboarding.md §2.1](docs/target-onboarding.md).

### 3.4 ▶️ Init, validate, plan, then apply

```bash
export GITHUB_TOKEN=...      # fine-grained token limited to the target; never written to a file
terraform init
terraform validate
terraform plan
```

> ⚠️ **Warning**: `terraform apply` changes a real repository. Run it only after reviewing the
> plan:
> - an existing object shows `import`, never `create`;
> - there is no `destroy` and no replace;
> - the module appears in one state only.

------

## ⚙️ 4. Configure GitHub Actions

### 4.1 📄 The five callers

Copy the five files of [`examples/target-repository/`](examples/target-repository/) into the
target's `.github/workflows/`. Each one is a thin caller with no logic of its own.

| File | Started by | Role |
|---|---|---|
| `flowforge-refine.yml` | a human: `gh workflow run` with `issue_number` | Refiner: turns a raw Issue into an executable one |
| `flowforge-agent.yml` | the `agent:ready` label, applied by a human | Developer: checks `SPEC.md`, implements, opens a **Draft** PR |
| `flowforge-review-cycle.yml` | a human: `gh workflow run` with `pull_request_number` | bounded Reviewer ⇄ Iterator loop (at most 3 Iterator passes) |
| `flowforge-review.yml` | a human (`gh workflow run`), or human activity on an `agent/*` PR | one read-only review |
| `flowforge-lifecycle.yml` | an `agent/*` PR being closed | `agent:done` on merge, card `Done` |

### 4.2 📌 Pin one FlowForge version

The examples contain `OWNER/flowforge/...@main` as a placeholder. In the target, replace it with
the **full commit SHA** of a FlowForge tag. Use the same SHA in all five files:

```bash
git ls-remote https://github.com/TiPunchLabs/flowforge.git 'refs/tags/v0.1.0^{}'
# afa60c599fa47643bba45e26dad0e836b0375b69  refs/tags/v0.1.0^{}
```

```yaml
    uses: TiPunchLabs/flowforge/.github/workflows/agent-develop.yml@afa60c599fa47643bba45e26dad0e836b0375b69 # v0.1.0
```

> ⚠️ **Warning**: never `@main`, a branch, a tag name or a short SHA in a target's default branch.
> A branch moves, and a full SHA cannot. The SHA also pins the scripts and agent rules the
> workflows fetch.

Copy the examples from the **same version** as the SHA, for example with
`git -C "$FF" show v0.1.0:examples/target-repository/flowforge-agent.yml`. `demo-api` and
`demo-api-2` have byte-for-byte identical callers: either one is a working reference.

### 4.3 🔧 What to adapt, and what to keep

| Keep as in the examples | Adapt to the project |
|---|---|
| triggers, `if:` conditions (the review caller ignores bot actors) | `setup_uv` (install uv) |
| `permissions:` blocks (a caller can only narrow them) | `allowed_tools` (Developer, Reviewer) |
| explicit `secrets:` (never `secrets: inherit`) | `review_allowed_tools`, `iterate_allowed_tools` (review cycle) |
| `app_client_id: ${{ vars.FLOWFORGE_APP_CLIENT_ID }}` | — |
| `project_number: ${{ fromJSON(vars.FLOWFORGE_PROJECT_NUMBER \|\| '0') }}` | — |

`allowed_tools` must list the commands that `CLAUDE.md` documents (e.g.
`Bash(uv run pytest:*)`), otherwise the agents cannot run the checks they are asked to run.

### 4.4 🔑 Secrets and variables the callers use

| Name | Kind | Passed as | Needed for |
|---|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | secret | `claude_code_oauth_token` | every agent |
| `FLOWFORGE_APP_PRIVATE_KEY` | secret | `app_private_key` | App delivery, Iterator push, Project sync |
| `FLOWFORGE_APP_CLIENT_ID` | variable | `app_client_id` | the same; both or neither |
| `FLOWFORGE_PROJECT_NUMBER` | variable | `project_number` | Project sync (unset = off) |

The target reads them from the organization: none of the four may also exist at repository
level, because a repository-level value overrides the organization one.

### 4.5 🧪 The target's CI

A `pull_request` workflow on the default branch, **without** a `paths:` filter, with explicit
`permissions:`. FlowForge never replaces it.

Check the callers before merging their PR:

```bash
actionlint .github/workflows/flowforge-*.yml                               # if installed
grep -h "uses: TiPunchLabs/flowforge/" .github/workflows/flowforge-*.yml   # 5 lines, one SHA
```

[target-onboarding.md §10.4](docs/target-onboarding.md#104--update-a-target) gives a script that
compares each caller's keys with the version's `workflow_call` interface.

------

## 🔐 5. Check the permissions

### 5.1 🧾 What each identity needs

| Identity | Needs | Must not have |
|---|---|---|
| Caller jobs (`GITHUB_TOKEN`) | the `permissions:` of the examples: e.g. Developer `contents`, `issues`, `pull-requests: write`; Reviewer read-only except `pull-requests: write` | workflow-level permissions (`permissions: {}` at the top) |
| Repository token settings | `can_approve_pull_request_reviews: true` (set by the module) | — |
| FlowForge GitHub App installation | Contents and Pull requests `write`, organization Projects `write`; the target in its repository list | **Issues** (it could apply `agent:ready` and restart the Developer) |
| Secrets / variables | the four names visible to the target (*Selected repositories*) | a repository-level copy |
| Maintainer `gh` login | `repo`, `read:org`, `project` (the default login) | a permanent `admin:org` scope |

### 5.2 🔍 Read-only commands

```bash
# App installation: granted permissions, not suspended (organization owner + read:org)
gh api orgs/TiPunchLabs/installations \
  --jq '.installations[] | select(.app_slug=="'$APP'") | {permissions, suspended_at, repository_selection}'
# Actions allowed, token settings (repository admin)
gh api "repos/$R/actions/permissions"
gh api "repos/$R/actions/permissions/workflow"
# Secrets and variables the target receives: names and dates only, never values
gh api "repos/$R/actions/organization-secrets" --jq '.secrets[] | [.name, .updated_at]'
gh api "repos/$R/actions/organization-variables" --jq '.variables[].name'
# No repository-level override (expect 0 and 0)
gh api "repos/$R/actions/secrets" --jq .total_count
gh api "repos/$R/actions/variables" --jq .total_count
# Organization Project matches the model (needs read:project)
"$FF/scripts/github-projects/bootstrap.sh" --check
```

### 5.3 🚦 Reading a result

| Result | Meaning | What to do |
|---|---|---|
| `PASS` | the check was run, and the evidence covers it **now** | nothing |
| `FAIL` | a mandatory item is missing or wrong | fix it before the first request |
| `NOT_VERIFIED` | your permissions or the data cannot settle it | never read it as `PASS`: ask an organization owner, or wait for the first run when this is allowed |

Two things cannot be checked with the default login:

- the organization *Selected repositories* lists;
- the repository list of the App installation.

An organization owner checks them in the UI (Organization settings → Secrets and variables →
Actions, and GitHub Apps → FlowForge → **Configure**), as described in
[target-onboarding.md §4.3](docs/target-onboarding.md#43--checks-that-need-an-organization-owner).
Until then they stay `NOT_VERIFIED`.

A secret's value can never be read. Its validity is only proven by a successful run that is
newer than the secret's `updated_at`.

------

## ✅ 6. Check the onboarding

Run the readiness checks **R1–R18** of
[target-onboarding.md §4.2](docs/target-onboarding.md#42--checks-r1r18). They are read-only and
print no secret. They group as follows:

| Checks | Covers | Typical command |
|---|---|---|
| R1–R3 | organization: FlowForge callable, App permissions, Project | step 5.2 |
| R4–R9 | repository: readable, Actions allowed, one IaC owner, 6 labels, active ruleset, token settings | `gh api "repos/$R/labels" --paginate --jq '.[].name' \| grep -c '^agent:'` (expect `6`) |
| R10–R12 | secrets and variables reach the target, no override | step 5.2 |
| R13 | 5 callers active, one full SHA, no `secrets: inherit` | `gh workflow list -R "$R"` |
| R14 | App installed on the target | organization owner, UI |
| R15 | required check name = CI job name | `gh api "repos/$R/rulesets" --jq '.[] \| [.name, .enforcement]'` |
| R16–R18 | `SPEC.md` passes the check, `CLAUDE.md` exists, the owner validated `SPEC.md` | `flowforge-spec.sh` (step 2.2) |

**Ready for a first request** means no `FAIL`, with `NOT_VERIFIED` accepted only on:

- R14, until the owner checks the installation (the first App-authored PR confirms it);
- R10 secret validity, on a new target, until its first run;
- R18, if the owner accepts it.

**When a check fails**: the table in the reference names the fix for each check, and step 9 below
covers the frequent ones. Fix it with the normal mechanisms (a PR in the target, the module and a
reviewed apply, or the organization settings), then run the check again. Never widen a token or
copy a secret to the repository to make a check pass.

------

## 🧪 7. Create a first request

Each step says who acts. A step marked **human** is never done by FlowForge.

### 7.1 ✍️ Create the Issue (human)

Describe the need in plain words: the problem, the expected result, any known constraint.

```bash
gh issue create -R "$R" --title "feat: <short need>" --body "<what is needed, and why>"
```

Leave it without a label. (A need written in Notion can also become this Issue: see
[target-onboarding.md §9](docs/target-onboarding.md#-9-notion-intake-optional).)

### 7.2 🔎 Ask for refinement (human)

```bash
gh workflow run flowforge-refine.yml -R "$R" -f issue_number=<n>
gh run list -R "$R" --workflow flowforge-refine.yml --limit 1     # follow the run
```

The Refiner reads the Issue, its comments, the code and `SPEC.md` of the default branch. It never
writes code and never applies `agent:ready`.

### 7.3 📖 Read the Refiner's result

The Issue is rewritten into the [refined Issue format](docs/issue-contract.md), and the original
request is kept verbatim inside it. One FlowForge comment gives the verdict and the run link.

| Section | Read it for |
|---|---|
| *Specification* | the `SPEC.md` impact (step 8) and the `F/R/S` items concerned |
| *Scope* / *Out of scope* | what will and will not change |
| *Acceptance criteria* | the testable conditions the Reviewer will check |
| *Definition of Done* | what must be true before merging (tests, `SPEC.md` update, checks) |
| *Open questions*, *Assumptions* | anything the Refiner did not know: each statement is tagged `[provided]`, `[observed]`, `[assumption]`, `[recommended]` or `[missing]` |

### 7.4 💬 Answer a clarification (human)

On `NEEDS_CLARIFICATION`, the Issue carries `agent:needs-clarification` and the comment lists the
blocking questions. Answer them in an Issue comment, then run the Refiner again (step 7.2). When
the request contradicts `SPEC.md`, the Refiner offers the options and never chooses. Only the
owner decides, and a decision to change the contract leads to a `MODIFIES` refinement.

### 7.5 ✅ Validate the criteria and the Definition of Done (human)

Before going further, the owner checks that:

- the acceptance criteria describe the expected behaviour, and nothing more;
- the Definition of Done lists the `SPEC.md` change when the impact is `EXTENDS`, `NEW_FEATURE`
  or `MODIFIES`;
- no `[assumption]` hides a decision that you have not taken.

If something is wrong, say so in a comment and run the Refiner again.

### 7.6 🏷️ Start the Developer (human)

```bash
gh issue edit <n> -R "$R" --add-label agent:ready
```

This label is the only trigger of the Developer, and only a human applies it. The Developer then:

1. checks `SPEC.md` (`SPEC contract: PASS` in the run summary);
2. sets `agent:running` and implements the change with tests;
3. updates `SPEC.md` only when the Issue says so, in the same PR;
4. opens a **Draft** PR on `agent/<n>-<slug>` (author: the FlowForge App) and sets `agent:review`.

### 7.7 🔁 Review the PR (human starts, agents run)

The Draft PR is authored by a bot, so no review starts on its own. Start the review cycle:

```bash
gh workflow run flowforge-review-cycle.yml -R "$R" -f pull_request_number=<pr>
```

The read-only Reviewer posts one comment with a verdict. On `REQUEST_CHANGES`, the Iterator
fixes the findings on the same branch and the Reviewer runs again, at most 3 times. The cycle ends
`APPROVED`, `BLOCKED`, `MAX_ITERATIONS_REACHED` or `FAILED`. For a single review without the
Iterator, use `flowforge-review.yml` instead. Never run both on the same PR at the same time.

### 7.8 👀 Validate and merge (human)

A Reviewer `APPROVE` is an agent's opinion. It is **not** a GitHub approval and does not count
for the merge gate.

1. Read the diff, the Reviewer comment, and the target CI result.
2. Mark the PR ready (`gh pr ready <pr> -R "$R"`). This starts one more review on the same head,
   which is expected.
3. Approve the PR in GitHub (the App cannot approve its own PR), then merge it. With
   `admin_pull_request_bypass = true`, a repository admin may merge through the PR without that
   approval: this suits a solo maintainer, and the merge is still a human action.

### 7.9 🏁 Check `agent:done`

The lifecycle workflow runs on the merge:

```bash
gh issue view <n> -R "$R" --json state,labels --jq '{state, labels: [.labels[].name]}'   # agent:done
"$FF/scripts/github-projects/sync-issue.sh" "$R" <n> --show                              # Status: Done
```

After this first run, check the points of
[target-onboarding.md §6](docs/target-onboarding.md#-6-validation-after-the-first-run). In
particular, the PR author must be `app/tipunchlabs-flowforge`, and the CI must have started
without *Approve workflows to run*.

------

## 📊 8. Understand the results

### 8.1 🔎 Refiner verdicts

| Verdict | Issue | Your action |
|---|---|---|
| `READY` | rewritten, no state label | step 7.5, then `agent:ready` |
| `NEEDS_CLARIFICATION` | rewritten, `agent:needs-clarification` | answer, run the Refiner again |
| `BLOCKED` | unchanged, one comment with the reason | fix the cause, or close the Issue |

### 8.2 📜 `SPEC.md` impact (`spec_impact`)

| Value | Meaning | `READY` possible? |
|---|---|---|
| `COMPLIANT` | the request respects the contract as it is | yes |
| `EXTENDS` / `NEW_FEATURE` | it adds to the contract: the `SPEC.md` change is listed, done in the same PR | yes |
| `MODIFIES` | it changes the contract, after an explicit owner decision | yes |
| `CONTRADICTS` / `NEEDS_DECISION` | it breaks a requirement, or needs an arbitration | **no**: the workflow refuses it |
| `NO_SPEC` | the target has no `SPEC.md` on its default branch | yes, but the Developer will refuse to start |

### 8.3 🗂️ GitHub Project and labels

The Project card follows the workflows; moving a card by hand never starts an agent.

| Project status | Label | Who acts next |
|---|---|---|
| `Backlog` | none, or `agent:needs-clarification` | requester / owner |
| `Refining` | none | Refiner |
| `Ready` | none, then `agent:ready` | **human**: apply `agent:ready` |
| `Developing` | `agent:running` | Developer |
| `Review` ⇄ `Iteration` | `agent:review` | Reviewer, Iterator |
| `Human validation` | `agent:review`, or `agent:blocked` with an `Attention` | **human**: review, approve, merge |
| `Done` | `agent:done` | — |

The `Attention` field says why a human must act: `Needs clarification`, `Blocked`,
`Max iterations` or `Failed`. Model: [kanban-model.md](docs/github-projects/kanban-model.md).

------

## 🔧 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Developer run fails with `SPEC contract: FAILED` | `SPEC.md` absent from the default branch, wrong section title, empty features or scenarios | fix `SPEC.md` by PR (step 2.2), then remove and re-apply `agent:ready` ([spec-contract §4](docs/spec-contract.md#4--fixing-a-non-conformity)) |
| `SPEC contract: ERROR` | the file could not be read (API, rights, branch) | check the repository and branch, re-apply `agent:ready`. Do not create a `SPEC.md` for an `ERROR` |
| Refiner always says `NO_SPEC` | `SPEC.md` still in an open PR | merge it into the default branch |
| Run fails at *Create App … token*, or at the first agent step | a secret or variable is not visible to the target, only one of client ID / key is visible, or there is a repository-level override | R10–R12; an organization owner checks the *Selected repositories* lists |
| PR shows *Approve workflows to run* | the App is not used: client ID or key not visible, or the target is not in the App installation | R10, R11, R14 |
| Developer commits but no Draft PR is created (permission error) | delivery fell back to `GITHUB_TOKEN` and `can_approve_pull_request_reviews` is `false`, or the App lacks Pull requests `write` | R9 (module token settings, reviewed `terraform apply`), R2 |
| Agent push rejected | the change touches `.github/workflows/`: the App has no `workflows` permission | that change stays human work |
| Workflow not triggered | the label was applied by a bot, or the caller is not on the default branch | apply `agent:ready` yourself; merge the callers (R13) |
| Callers end in `startup_failure` | the Actions policy forbids reusable workflows from other repositories | R5, organization Actions policy |
| Review did not start on the Draft PR | expected: bot-authored PRs are skipped | dispatch `flowforge-review-cycle.yml` (step 7.7) |
| Card never moves | `FLOWFORGE_PROJECT_NUMBER` unset or not visible, or the App lacks organization Projects permission | R2, R11. A green sync step proves nothing: look for the log line `Project sync … update` ([synchronization §6](docs/github-projects/synchronization.md)) |
| Refiner keeps asking questions | the answer is missing, or the request contradicts `SPEC.md` | answer every blocking question in a comment; for a contradiction, the owner chooses an option explicitly |
| State label skipped with a warning | the module is not applied on the target | R7, reviewed `terraform apply` |
| Merge blocked forever | the required check name differs from the CI job name, or the CI has a `paths:` filter | R15, step 4.5 |

More cases: [target-onboarding.md §7](docs/target-onboarding.md#-7-common-errors).

------

## ✅ Checklist

- [ ] Level A exists (step 1.1), or the organization owner created it
- [ ] `CLAUDE.md` and `SPEC.md` merged; `flowforge-spec.sh` prints `SPEC contract: PASS`; owner validated
- [ ] Module in one state, Git source `?ref=vX.Y.Z`, plan reviewed (imports, no destroy), applied
- [ ] Five callers merged, same full SHA, Project inputs present, no `secrets: inherit`
- [ ] Target in the App installation and in the four secret/variable lists
- [ ] R1–R18: no `FAIL`; every `NOT_VERIFIED` is one of the accepted ones
- [ ] First Issue: refined, criteria and DoD validated, `agent:ready` applied by a human
- [ ] Draft PR reviewed, approved and merged by a human; Issue shows `agent:done`

------

## 📚 Resources

| Document | For |
|---|---|
| [README.md](README.md) | what FlowForge is, what it does not do |
| [docs/target-onboarding.md](docs/target-onboarding.md) | the detailed onboarding reference: all checks, evidence rules, updates and rollback |
| [docs/spec-contract.md](docs/spec-contract.md) | the `SPEC.md` contract and how agents use it |
| [docs/issue-contract.md](docs/issue-contract.md) | the refined Issue format and the *Ready* definition |
| [docs/architecture.md](docs/architecture.md) | components, flows, security model |
| [terraform/modules/target-repository/README.md](terraform/modules/target-repository/README.md) | module inputs, ruleset, token permissions |
| [docs/milestones/phase8-specification-complete.md](docs/milestones/phase8-specification-complete.md) | what has been validated live, and the open reservations |

------

> **Document created on**: 2026-10-22
> **Author**: xgueret, with Claude Code (Phase 8, Prompt 41)
> **Version**: 1.0 — for FlowForge `v0.1.0`; derived from [target-onboarding.md](docs/target-onboarding.md) v2.3
