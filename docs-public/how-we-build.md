# How we build <project name>

<!-- kit-keeper-Opus5.5-agent, 2026-10-16 (KIT-003). Template.
     Copy to docs-public/how-we-build.md at scaffold; fill it in at the first
     release (start-here, "Per release: harden and tell", step T) and update
     its numbers each release.
     It describes the method in general: the stages, the roles, the gates and
     what was tried against them. It does not copy role files, review rules or
     prompts, and it names no way past a check; a reader learns that a gate
     exists and what it refuses, not how it decides.
     It is public: state each practice and its technical reason, never why
     the kit asks for it or anything about the owner as a person
     (docs/rules/content-rules.md section 4). -->

Last updated: <release>, <date>

## In one paragraph
<How a change gets from an idea to production here: who decides, who
builds, what checks it, who merges. Five sentences at most.>

## The lifecycle
| Stage | What happens | What it leaves in this repository |
|---|---|---|
| Frame | The problem, who has it, the load, budgets, what is cut and why | `specs/PRD.md` |
| Decide | Costly technical choices with their options; architecture; threat model | `specs/adr/`, `specs/architecture.md`, `specs/threat-model.md` |
| Walking skeleton | The thinnest end-to-end path, deployed, observable, with the build rules in CI | the first feature in `specs/features/` |
| Per feature | A brief and its shape, then one thin slice at a time: plan, locked acceptance checks, build test-first, review, merge, retro | `specs/features/`, `plans/`, `acceptance/`, `docs-public/retro-log.md` |
| Per release | Harden (load, security baseline, SLOs, runbook, restore, accessibility), then tell | `load/results/`, `docs-public/runbook.md`, `docs-public/case-study.md` |

## Who does what
| Role | Does | Can't |
|---|---|---|
| Owner | Decides scope and every costly choice; approves each plan; reads every line of each build; merges | |
| Lead agent | Plans each slice, writes its acceptance checks, builds to them | Merge; change a locked check |
| Tech reviewer agent | Reads each draft build for design and production risks; findings only | Change code (read-only tools) |
| Automatic reviewer | Judges each pull request in CI: PASS or FAIL | Be changed by the pull request it judges |

<Agents write the code. The owner owns it: every line is read before it is
merged, and anything that can't be explained is rejected or explained
first.>

## The gates
<What must be true before anything reaches `main`. In general terms: what
each gate refuses, not how it decides.>

| Gate | Refuses | Tried against it |
|---|---|---|
| Merge gate | A merge without a passing review, a passing test lock and the owner's approval | <the attack and its result, for example "a direct push to main: refused"> |
| Automatic reviewer | A change that breaks the project's rules or its plan; a missing input | |
| Test lock | A build that edits or deletes an approved acceptance check, or its plan | |
| Daily report | Nothing: it reports. Any merge without a passing review, pushes to `main` without a pull request, changes to the protection rules | |

<Owner overrides: when they are used, and that each one is logged and
reported the next morning.>

## Numbers
<From this repository's history; each one says how it was counted.>

| | This release | Since the start | How it is counted |
|---|---|---|---|
| Slices merged | | | merged build PRs |
| Median time per slice | | | slice-plan PR opened to build PR merged |
| Automatic reviewer FAILs | | | FAIL verdicts on build PRs |
| Checks added from retros | | | retro entries whose action added a check |
| CI time, push to verdict | | | median over the release's build PRs |
| Owner overrides | | | from the daily report |

## What we'd change
<One to three things about the method itself, each with the evidence:
a retro entry, a number above.>
