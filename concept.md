# Project Structure & Agentic Development Conventions

Reference document for initializing a three-tier system (backend, frontend,
infrastructure) developed primarily through AI coding agents.

**Status:** initial version — conventions, not yet battle-tested.
**Review cadence:** revisit after ~10 completed changes, and after any major model release.

---

## 1. Purpose and scope

This document defines:

- how the repositories are split and why,
- where instructions for coding agents live, and which of the four destinations each kind of document belongs in,
- what is enforced mechanically versus what is advisory,
- the two development workflows (single-repo and cross-repo),
- a concrete file-by-file layout with example contents.

It assumes Claude Code as the primary harness, but the layout is harness-agnostic:
everything is plain markdown, shell scripts, and CI configuration.

---

## 2. Architecture decisions

### 2.1 Polyrepo with a control repo

Four repositories:

| Repo | Contents | Deploy cadence |
| --- | --- | --- |
| `platform` (control) | contracts, change briefs, cross-cutting docs, orchestration | n/a |
| `backend` | API service | per-merge |
| `frontend` | web client | per-merge |
| `infra` | IaC | reviewed, gated |

The three product repos are vendored into the control repo as **git submodules**.

**Rationale.** Each product repo keeps its own git history, CI pipeline, deploy
cadence, secret scope, and observability. The control repo exists to hold the one
thing that cannot live inside any single product repo: the interface between them.

**Known cost.** A feature spanning all three repos produces three pull requests and
three CI runs, and cannot merge atomically. Version skew between repos is a permanent
tax, paid via expand-contract migrations and feature flags (see §8.3). This cost is
accepted deliberately; if it becomes the dominant source of friction, the fallback is
to merge `backend` + `frontend` + `contracts` into one repo and keep `infra` separate.

### 2.2 Contract-first coordination

**The control repo owns `contracts/`. No product repo may modify it.**

A cross-repo feature is not coordinated by an orchestrating agent or by prose
instructions. It is coordinated by a frozen, machine-readable artifact that each
repo's own CI verifies conformance against:

```
contracts/openapi.yaml        HTTP interface
contracts/events/*.json       async message schemas
contracts/infra-outputs.yaml  what infra promises the app repos (ARNs, URLs, secret names)
```

Three agents working in three repos will each independently re-derive an interface if
allowed to, and they will disagree in small ways. No amount of instruction text
prevents this, because instruction text cannot fail a build. A contract can.

**Corollary:** contract changes are sequential and single-session. Implementation is
parallel. Never both at once.

### 2.3 Self-sufficiency of sub-repos

Because CI clones each product repo on its own, and because a developer may clone
only `backend`, the following rule is absolute:

> **The control repo's `CLAUDE.md` is additive context. It is never load-bearing.**
> Every product repo must be fully self-describing in isolation.

Test this periodically: clone a product repo into a fresh directory outside the
submodule tree, start an agent session, and ask it to implement a small change. If it
is missing context, the split is wrong.

---

## 3. Where instructions live: the four destinations

The single most common configuration mistake is putting everything in one place.
The correct question for each document is **when should this enter the context window?**

| Destination | Loads | Contents |
| --- | --- | --- |
| `CLAUDE.md` | Every session, always | Commands, layout map, hard rules, gotchas. **40–60 lines maximum.** |
| `.claude/skills/*/SKILL.md` | On demand, when the agent judges it relevant | **Procedures with a natural trigger:** how tests are written, how to add an endpoint, release runbook |
| `.claude/rules/*.md` (with `paths:` frontmatter) | When the agent touches a matching file | **Hard local rules** for a specific area: migrations, auth, generated code |
| `docs/` | Never automatically | **Durable source of truth:** ADRs, architecture, product specs |

### Skills are procedures. Docs are truth.

A product spec has no natural trigger phrase, so as a skill it either never activates
or activates constantly. Keep it in `docs/` and let a *skill* instruct the agent when
to go read it. This is why the plan is not "move `context/*.md` into skills" but
rather: most of that content becomes `docs/`, with a thin skill layer pointing at it.

### CLAUDE.md sizing discipline

For each line in a `CLAUDE.md`, ask: *would removing this cause the agent to make a
mistake?* If not, delete it. An over-long `CLAUDE.md` causes the agent to ignore the
rules that matter, because the important ones get lost in the noise. Symptom to watch
for: the agent repeatedly violating a rule that is written down. The fix is almost
always to shorten the file, not to add emphasis.

Note that `.claude/settings.json` does **not** layer from parent directories the way
`CLAUDE.md` does — it loads only from the directory the session starts in. Each
product repo therefore needs a complete, self-contained settings file.

---

## 4. Repository layout

### 4.1 Control repo

```
platform/
├── CLAUDE.md                                 # additive context; never load-bearing
├── README.md
├── .gitmodules
├── repos.lock                                # human-readable SHA triple
├── .claude/
│   ├── settings.json                         # root-session hooks + deny rules
│   ├── skills/
│   │   ├── plan-cross-repo-change/SKILL.md
│   │   └── freeze-contract/SKILL.md
│   ├── agents/
│   │   └── contract-conformance.md
│   ├── commands/
│   │   └── ship.md                           # /ship 0042-csv-export
│   └── hooks/
│       └── no-subrepo-edits.sh
├── contracts/
│   ├── openapi.yaml
│   ├── events/
│   │   └── account-activity.schema.json
│   └── infra-outputs.yaml
├── changes/
│   └── 0042-csv-export/
│       ├── BRIEF.md                          # what, why, acceptance criteria
│       ├── backend.md
│       ├── frontend.md
│       ├── infra.md
│       └── STATUS.md                         # PR links, SHAs, blockers
├── docs/
│   ├── adr/
│   │   └── 0001-contract-first-polyrepo.md
│   └── product/
│       └── overview.md
├── scripts/
│   ├── fanout.sh
│   ├── lock.sh
│   └── new-change.sh
├── backend/                                  # submodule
├── frontend/                                 # submodule
└── infra/                                    # submodule
```

### 4.2 Product repo (backend shown; frontend and infra follow the same shape)

```
backend/
├── CLAUDE.md
├── .claude/
│   ├── settings.json
│   ├── skills/
│   │   ├── add-endpoint/SKILL.md
│   │   ├── testing/SKILL.md
│   │   └── db-migration/SKILL.md
│   ├── rules/
│   │   └── migrations.md                     # paths: migrations/**
│   ├── agents/
│   │   ├── adversarial-reviewer.md
│   │   └── security-reviewer.md
│   └── hooks/
│       ├── format.sh
│       └── gate.sh
├── contracts/
│   └── openapi.yaml                          # vendored copy; CI-verified, never edited here
├── docs/
│   ├── adr/
│   ├── architecture.md                       # modules, boundaries, data flow
│   └── product/
├── src/
├── tests/
├── migrations/
└── .github/workflows/ci.yml
```

---

## 5. Control repo file contents

### 5.1 `platform/CLAUDE.md`

```markdown
# Control repo

Three INDEPENDENT projects, vendored as submodules. Each has its own git history,
CI, deploy cadence, and CLAUDE.md. This file is extra context only — never assume a
sub-repo session can see it.

## Hard rules
- NEVER edit code inside backend/, frontend/, infra/ from this session. Implementation
  happens in a session started inside that repo, or via scripts/fanout.sh. Here you
  plan and write contracts.
- Submodules land in detached HEAD. Before ANY commit inside one:
  `git -C <repo> switch -c <branch>` first. Verify with `git -C <repo> status`.
- contracts/ is owned here and only here. Product repos consume, never edit.
- After merging a change, run ./scripts/lock.sh and commit repos.lock.

## Layout
- contracts/    frozen interfaces (OpenAPI, event schemas, infra outputs)
- changes/NNNN/ one directory per cross-repo feature
- docs/adr/     cross-cutting decisions
- repos.lock    the SHA triple known to work together

## Commands
- ./scripts/new-change.sh <slug>     scaffold changes/NNNN-<slug>/
- ./scripts/fanout.sh <change-dir>   dispatch a change to all three repos
- ./scripts/lock.sh                  refresh repos.lock from submodule SHAs
```

### 5.2 `platform/.claude/settings.json`

```json
{
  "permissions": {
    "deny": [
      "Edit(./backend/**)",
      "Edit(./frontend/**)",
      "Edit(./infra/**)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": ".claude/hooks/no-subrepo-edits.sh" }
        ]
      }
    ]
  }
}
```

The `deny` rules cover the agent's file-editing tools. The `PreToolUse` hook covers
the gap: shell commands that write into a submodule (`sed -i`, `tee`, redirects) are
not caught by `Edit` rules.

### 5.3 `platform/changes/0042-csv-export/BRIEF.md`

The brief is the substitute for a spec framework. Written by hand, in a planning
session, before any implementation.

```markdown
# 0042 — CSV export of user activity

## Why
Support spends roughly 3 hours per week manually pulling activity data for account
reviews. Self-service export removes that.

## Acceptance criteria (these are the oracle)
- [ ] GET /v1/accounts/{id}/activity.csv returns text/csv, streamed, never fully buffered
- [ ] Requires the `activity:read` scope; 403 otherwise, covered by a test
- [ ] A 50,000-row export completes in under 30s in staging
- [ ] Frontend: "Export" button on the Activity tab, disabled while a job is pending
- [ ] Infra: S3 bucket for exports exceeding 5 minutes, 7-day lifecycle rule

## Out of scope
XLSX format. Scheduled or recurring exports. Email delivery.

## Contract changes
contracts/openapi.yaml: +1 path, +ExportJob schema. Frozen as of <commit sha>.

## Slices
- backend.md
- frontend.md
- infra.md
```

Acceptance criteria are written as checkable statements, not aspirations. Each one
should map to a test, a metric, or a manual verification step someone can perform.

### 5.4 `platform/scripts/fanout.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

CHANGE="${1:?usage: fanout.sh <change-dir-name>}"
CONTROL="$(pwd)"
[ -d "changes/$CHANGE" ] || { echo "no such change: $CHANGE" >&2; exit 1; }

for r in backend frontend infra; do
  [ -f "changes/$CHANGE/$r.md" ] || continue

  git -C "$r" switch -c "feat/$CHANGE" 2>/dev/null || git -C "$r" switch "feat/$CHANGE"

  (
    cd "$r"
    claude -p "Implement your slice of this change: $CONTROL/changes/$CHANGE/$r.md
Read $CONTROL/changes/$CHANGE/BRIEF.md for full context and acceptance criteria.
The contracts under $CONTROL/contracts/ are FROZEN. If your slice appears to require
a contract change, STOP and report it rather than working around it.
Finish with your repo's gates passing, then open a pull request.
Return exactly OK or FAIL:<one-line reason>." \
      --permission-mode auto \
      --add-dir "$CONTROL/changes/$CHANGE" \
      --add-dir "$CONTROL/contracts"
  ) &
done

wait
echo "fanout complete — review the three PRs before merging anything"
```

Each invocation starts with its working directory *inside* the real product repo, so
it picks up that repo's `CLAUDE.md` chain, its `.claude/settings.json`, its skills,
its hooks, and its git remote. This is why the fan-out uses separate processes rather
than subagents spawned from the control session.

`--add-dir` is used rather than the `additionalDirectories` setting: the setting grants
file access only, while the flag also loads skills from the added directory.

### 5.5 `platform/scripts/lock.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
{
  echo "# Submodule SHAs known to work together"
  echo "# Regenerate with ./scripts/lock.sh"
  echo "# Updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for r in backend frontend infra; do
    printf '%-10s %s\n' "$r" "$(git -C "$r" rev-parse HEAD)"
  done
} > repos.lock
cat repos.lock
```

### 5.6 `platform/.claude/agents/contract-conformance.md`

```markdown
---
name: contract-conformance
description: Verifies a repo's implementation matches contracts/. Use after any slice completes.
tools: Read, Grep, Glob, Bash
model: sonnet
---

Compare the implementation against contracts/openapi.yaml.

Report ONLY:
- endpoints in the contract that are not implemented
- request or response shapes that differ from the contract
- implemented endpoints absent from the contract
- status codes returned but not documented

Do not comment on style, naming, file structure, or test quality. If everything
matches, say so in one line.
```

A reviewer agent asked to find problems will find some, whether or not they exist.
Narrow scope, as above, is what keeps review output actionable instead of producing
speculative refactors.

---

## 6. Product repo file contents

### 6.1 `backend/CLAUDE.md`

```markdown
# backend — Node 22 / TypeScript / Fastify / Postgres

Standalone repo. Everything needed to work here is in this repo.

## Commands
- test:      `npm test`                  (vitest; single file: `npm test -- <path>`)
- typecheck: `npm run typecheck`          MUST pass before work is considered done
- lint:      `npm run lint -- --fix`
- contract:  `npm run contract:check`     implementation vs contracts/openapi.yaml
- dev:       `npm run dev`                port 3001; requires `docker compose up db`

## Hard rules
- contracts/openapi.yaml is vendored from the control repo. NEVER edit it. If an
  endpoint needs to change, stop and say so — that is a control-repo change.
- No raw SQL in route handlers. Query builders live in src/db/.
- Every new endpoint needs: handler, integration test, contract entry.
- Migrations are append-only. Never edit a migration that has been merged.

## Source of truth
- Architecture and module boundaries: docs/architecture.md
- Why things are the way they are: docs/adr/ — read before proposing a redesign
- What we are building and for whom: docs/product/

If you change behaviour described in docs/architecture.md, or make a decision a
future reader would ask "why?" about, update the doc or add an ADR in the SAME
commit. This is enforced by .claude/hooks/gate.sh.
```

The final paragraph is deliberately paired with mechanical enforcement. On its own it
is advisory and will be ignored eventually; §7 is what makes it real.

### 6.2 `backend/.claude/settings.json`

```json
{
  "permissions": {
    "deny": [
      "Edit(./contracts/**)",
      "Edit(./migrations/*.sql)",
      "Read(./dist/**)",
      "Read(./coverage/**)",
      "Read(./**/*.generated.*)"
    ]
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": ".claude/hooks/format.sh" }]
      }
    ],
    "Stop": [
      {
        "hooks": [{ "type": "command", "command": ".claude/hooks/gate.sh" }]
      }
    ]
  }
}
```

### 6.3 `backend/.claude/skills/add-endpoint/SKILL.md`

```markdown
---
name: add-endpoint
description: Adding or modifying a REST endpoint in backend. Use when creating routes, handlers, or changing request/response shapes.
---

## Before writing code
1. Confirm the endpoint exists in `contracts/openapi.yaml`. If it does not, STOP —
   this is a control-repo change, not a backend change.
2. Read `docs/architecture.md` § "Request lifecycle".
3. Find the closest existing route in `src/routes/` and follow its shape.

## Order of work
1. Integration test in `tests/routes/<name>.test.ts`. It must fail first.
2. Handler in `src/routes/<name>.ts`, exporting a Fastify plugin.
3. Domain logic in `src/domain/`. Handlers stay thin; no business rules in them.
4. Run `npm run contract:check` and `npm test`.

## Conventions
- Validate with the zod schema generated from the contract, never hand-written.
- Return 4xx via `throw new AppError(...)`, never `reply.code(400).send()` directly.
- Every handler emits exactly one structured log line including `requestId`.
```

Skill descriptions are used to decide whether the skill applies, and they get
shortened when many skills are in scope. Lead with words a real request would contain.

### 6.4 `backend/.claude/rules/migrations.md`

```markdown
---
paths: ["migrations/**", "src/db/schema.ts"]
---

- Migrations are immutable once merged. To change a merged migration, write a new one.
- Every migration must be expand-contract: add nullable column → backfill → enforce
  constraint. Never a single breaking DDL, because backend and frontend deploy
  independently and will be skewed in production.
- Include a `-- rollback:` block describing how to reverse the change.
- Update `src/db/schema.ts` in the same commit.
```

### 6.5 `backend/docs/architecture.md` (skeleton)

```markdown
# Architecture

## Module map
| Directory | Responsibility | May import from |
| --- | --- | --- |
| src/routes/ | HTTP surface, validation, serialization | domain, db (read-only) |
| src/domain/ | business rules, invariants | db |
| src/db/ | queries, migrations, schema | — |

## Request lifecycle
1. ...

## Boundaries and invariants
- Domain code never imports from routes.
- ...

## Known gaps and deliberate omissions
- ...
```

The module table is the highest-value part of this file: it gives an agent something
concrete to check its own work against, rather than prose it can interpret loosely.

---

## 7. Enforcement: hooks and gates

Instructions in `CLAUDE.md` and skills are advisory. Hooks are deterministic. Anything
that genuinely must not happen belongs in a hook or a `deny` rule, not in prose.

### 7.1 `backend/.claude/hooks/gate.sh` — the Stop hook

A `Stop` hook blocks the agent's turn from ending until it passes. This converts
"looks done" into "provably done" and is the single highest-leverage file in this
layout. (Claude Code overrides the hook after 8 consecutive blocks, so it cannot
deadlock a session permanently.)

```bash
#!/usr/bin/env bash
set -uo pipefail

fail() { echo "$1" >&2; exit 2; }   # exit 2 = block the turn, send message to the agent

npm run typecheck --silent      || fail "typecheck failed — fix before finishing"
npm test -- --run --silent      || fail "tests are failing"
npm run contract:check          || fail "implementation drifted from contracts/openapi.yaml"

# Documentation freshness: architectural surface changed without any doc change
CHANGED="$(git diff --name-only HEAD 2>/dev/null; git diff --cached --name-only 2>/dev/null)"
if grep -qE '^src/(routes|domain)/' <<< "$CHANGED" && ! grep -qE '^docs/' <<< "$CHANGED"; then
  fail "You changed src/routes/ or src/domain/ without touching docs/. Update docs/architecture.md or add docs/adr/NNNN-*.md, then finish."
fi

exit 0
```

Keep it fast. A gate that takes two minutes will get disabled. If the full test suite
is slow, gate on the affected subset and leave the full suite to CI.

### 7.2 `backend/.claude/hooks/format.sh` — the PostToolUse hook

```bash
#!/usr/bin/env bash
set -uo pipefail
npx prettier --write --log-level warn "$@" 2>/dev/null || true
exit 0
```

Formatting must never block. Exit 0 unconditionally.

### 7.3 Optional: instruction drift detection

A `Stop` hook receives the path to the session transcript. A script can read it and
propose `CLAUDE.md` or skill updates while the gap that exposed the need is still
fresh. Worth adding once the base gates are stable — not on day one.

### 7.4 CI gates (independent of the agent harness)

Every product repo's CI must enforce, as required status checks:

- typecheck, lint, unit tests, integration tests
- contract conformance against the vendored `contracts/`
- vendored contract matches the control repo at the pinned SHA
- secret scanning — non-negotiable, and never delegated to the agent's judgement
- SAST / dependency audit

Additionally, for auditability: label agent-opened PRs with the tool and session
identifier so a finding in production can be traced back to the originating session.

---

## 8. Workflows

### 8.1 Single-repo feature (the common case, ~80% of work)

```bash
cd backend
claude
```

The session loads `backend/CLAUDE.md` plus the control repo's `CLAUDE.md` (found by
walking up the directory tree), `backend/.claude/settings.json`, and only that repo's
skills. Nothing from `frontend/` or `infra/` enters context.

No orchestration, no fan-out, no multi-agent setup. Plan mode first if the change
spans several files or the approach is uncertain; straight to implementation if the
diff could be described in one sentence.

### 8.2 Cross-repo feature

```bash
cd platform
claude
```

1. **Plan.** In plan mode, have the agent read `docs/`, interview you about the hard
   parts, then write `changes/NNNN-<slug>/BRIEF.md` and the per-repo slice files.
   Review and edit these by hand — this is where your judgement is worth the most.
2. **Freeze the contract.** Edit `contracts/` yourself or with the agent. Commit.
   This commit is the freeze point and should be referenced in `BRIEF.md`.
3. **Fan out.** `./scripts/fanout.sh 0042-csv-export`. Three parallel sessions, each
   inside its real repo with its real gates.
4. **Review.** Three PRs, each independently green. Run the deeper multi-agent review
   on anything substantial before merging.
5. **Merge in dependency order.** Backend first (expand-contract means it is backward
   compatible), then frontend, then infra as required. Bump `repos.lock` and commit.

**Never overlap steps 2 and 3.** Implementation agents working against an unfrozen
contract is exactly the failure mode this structure exists to prevent.

### 8.3 Managing version skew

Because the three repos cannot merge atomically, production will always briefly run
mismatched versions.

- **Backend:** additive changes only within a release. New fields optional, new
  endpoints alongside old ones, old endpoints deprecated in a later change.
- **Frontend:** feature-flagged, so it can merge and deploy before the backend
  capability is enabled.
- **Database:** expand-contract in three separate merges, never one.
- **Infra:** outputs are additive; removing an output is its own change with the
  consumers updated first.

---

## 9. Submodule operating rules

Submodules are the sharpest edge in this layout. Two failure modes recur:

**Detached HEAD.** `git submodule update` leaves each submodule on a detached HEAD.
Commits made there are not on any branch and are easy to lose. Always
`git -C <repo> switch -c <branch>` before any work. `fanout.sh` does this; interactive
sessions must do it manually. This is why it appears in the control repo's
`CLAUDE.md` hard rules.

**Stale pointers.** The control repo pins SHAs. After merging product-repo PRs:

```bash
git submodule update --remote --merge
./scripts/lock.sh
git add backend frontend infra repos.lock
git commit -m "chore: bump submodules for 0042-csv-export"
```

`repos.lock` duplicates information git already stores in the submodule pointers, on
purpose: it is human- and agent-readable without git plumbing, and it is what CI reads
to verify the vendored contract matches.

**Clone instructions** belong in the control repo's `README.md`:

```bash
git clone --recurse-submodules <url> platform
# or, after a plain clone:
git submodule update --init --recursive
```

---

## 10. Bootstrap checklist

Order matters — the gates should exist before the first feature, not after.

1. Create the four GitHub repositories.
2. In each product repo: language toolchain, one passing test, working CI with
   required status checks including secret scanning.
3. In each product repo: `CLAUDE.md` (short), `.claude/settings.json`,
   `.claude/hooks/gate.sh` (+ `chmod +x`), `docs/architecture.md` skeleton.
   Verify the Stop hook actually blocks by breaking a test on purpose.
4. Write the first real skill per repo — the testing one. Do not pre-write skills you
   have not needed yet.
5. Create the control repo; add the three as submodules; write `CLAUDE.md`,
   `scripts/`, and an empty `contracts/`.
6. Write `docs/adr/0001-contract-first-polyrepo.md` recording the decision in §2 and
   its accepted costs.
7. Install a code-intelligence plugin per language so the agent resolves symbols via
   the language server instead of scanning files.
8. Run one deliberately small cross-repo change end to end through §8.2 to shake out
   the fan-out script and the submodule branching.
9. Verify sub-repo self-sufficiency: clone one product repo alone into `/tmp`, run a
   session, confirm nothing essential is missing.

---

## 11. Maintenance

**Harness review every three to six months, and after every major model release.**
Rules written to work around a weaker model become pure friction on a stronger one —
for example, an instruction to break refactors into single-file changes. Prune
aggressively; the default assumption should be that a rule is obsolete until it earns
its place.

**Track which skills never activate.** With OpenTelemetry logs enabled and tool
details unredacted, skill invocation events record which skills fire and what
triggered them. Retire or consolidate the ones that never do.

**Review `CLAUDE.md` and skill changes in pull requests** like any other
documentation, so conventions track the code rather than drifting from it.

**Watch for the drift signal:** if the agent repeatedly violates a written rule, the
file is too long and the rule is being lost. Shorten before adding emphasis.

---

## 12. Deliberately deferred

These are real capabilities that do not yet solve a problem this project has. Adopt
each only when a specific symptom demands it.

| Deferred | Adopt when |
| --- | --- |
| Spec-driven frameworks (OpenSpec, Spec Kit, BMAD) | `changes/` has ~10 entries and hand-written briefs are visibly drifting from the code |
| Agent teams | `fanout.sh` proves insufficient because slices genuinely need to negotiate mid-flight |
| Dynamic workflows / high-effort orchestration modes | A task needs dozens of agents, e.g. a repo-wide migration or audit |
| Deep multi-agent cloud review | Change size makes local review unreliable; use per-merge on substantial diffs |
| Shared-convention plugin in an internal marketplace | Per-repo skill duplication becomes a maintenance burden |

Everything in §1–§11 except `gate.sh` is documentation, and documentation degrades
silently. `gate.sh` is the part that cannot be ignored by a model having a bad day.
If effort has to be spent somewhere, spend it there.