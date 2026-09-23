# Initialization playbook

How this four-repo structure is created from zero, as a repeatable procedure.

`concept.md` at the repo root explains *why* the structure looks like this. This
document is the *how*: ordered steps, the decisions that must be made before starting,
and the checks that prove the result actually works. Where the two disagree, this one
is the operational truth — it reflects what was really run.

**Produced by this playbook:** one control repository plus a product repository per
tier, each private, each self-describing, with the agent-facing structure in place and
no technology chosen yet. It started at three product repos; `chatbot-eval` was
attached later by the same steps — see § Attaching a product repo after the fact.

---

## 1. Decide these before you start

Each is cheap now and expensive later.

| Decision | Default | Why it matters |
| --- | --- | --- |
| Repo names | `<project>`, `<project>-backend`, `frontend`, `infra` | They appear in every clone URL, CI config and vendored-contract check. |
| How many product repos | one per tier that deploys on its own cadence | Each one is a fourth copy of every hand-kept repo list in `scripts/`. Cheap to add, never free — see `docs/adr/0013`'s accepted costs. |
| Submodule paths | match the remote names | Scripts loop over these, and a path that differs from its remote name is a permanent small tax on every reader. Keep them identical unless there is a reason not to. |
| Visibility | private | Public is a one-way door for anything already pushed. |
| Default branch | `main` | Must match across all four, or CI and fan-out branch logic diverge. |
| Who owns `contracts/` | the control repo, exclusively | The whole structure rests on this. Do not soften it. |

Not decided at init time, on purpose: language, framework, test runner, formatter,
IaC tool, package manager. See §6.

---

## 2. Order of operations

The order is the point. Gates must exist before the first feature, not after — a gate
added later has to be retrofitted against code that already violates it.

### Step 1 — Create the repositories

```bash
gh repo create <owner>/<name> --private --description "<one line>"
```

All four, control repo included.

### Step 2 — Scaffold each product repo

One shared template, materialized three times. Every product repo gets:

| Path | Purpose | Loads |
| --- | --- | --- |
| `CLAUDE.md` | commands, layout, hard rules, gotchas | every session |
| `.claude/settings.json` | permissions + hook wiring | session start |
| `.claude/skills/*/SKILL.md` | procedures with a natural trigger | on demand |
| `.claude/rules/*.md` | hard local rules, scoped by `paths:` frontmatter | when a matching file is touched |
| `.claude/agents/*.md` | narrow-brief subagents | when invoked |
| `.claude/hooks/gate.sh` | Stop hook — the enforcement | end of every turn |
| `.claude/hooks/format.sh` | PostToolUse hook — never blocks | after Edit/Write |
| `docs/architecture.md` | module map, boundaries, lifecycle | never automatically |
| `docs/adr/` | decisions and their accepted costs | never automatically |
| `docs/product/` | what is being built and for whom | never automatically |
| `contracts/` | vendored, read-only | read as needed |
| `.github/workflows/ci.yml` | required status checks | CI |

`.claude/settings.json` does **not** layer from parent directories — it loads only
from the directory the session starts in. Each product repo therefore needs a
complete, self-contained file. `CLAUDE.md` does layer; that is why the control repo's
copy can be additive.

**A `deny` must not glob a file the same repo requires committed.** `deny: Edit(./.env*)`
matches `.env.example`, which `.gitignore` un-ignores with `!.env.example` on purpose — two
committed files contradicting each other, with the correct action on the forbidden side. It
is latent from the first commit and surfaces only when something has to create the template,
which is a dispatched slice that then cannot: three repos scaffolded from this template carry
it, and it cost `0006` two dispatches and left the file unshipped. Deny the real files by
name — `Edit(./.env)`, `Edit(./.env.local)` — and check every `deny` pattern against that
repo's own `.gitignore` negations before committing either.

Commit and push each repo with its own history before touching the control repo.

### Step 3 — Scaffold the control repo

Adds, on top of the same idea:

```
contracts/          the interfaces — owned here and only here
changes/NNNN-*/     one directory per cross-repo feature; change.yaml is its machine half
stack/compose.yml   every repo joined into ONE compose project, so the seams are real
stack/dev.env       the one source of values for the stack AND the suites
smoke/baseline.yaml the cross-repo regression suite, every step with an owner
scripts/            manifest.py --validate is the ship gate; iterate.sh is the loop;
                    verify.sh is the oracle; smoke.py asserts; prs.sh opens the PRs;
                    lock.sh pins. `--help` on any of them. None is an entry point —
                    the commands below are.
repos.lock          the submodule SHAs known to work together
docs/adr/           decisions and their accepted costs
docs/infra-interface.md   what this repo requires of infra/
docs/init/          this playbook
.github/workflows/  check-docs.py and manifest.py --validate over every change
.claude/commands/   one per lane — ship, ship-correct, ship-iterate, realign — and the
                    whole agent-facing surface. No skills: see docs/adr/0005.
.claude/agents/     harness-retro.md — the retrospective every lane ends with. It proposes
                    harness fixes as a pull request; it never applies them. docs/adr/0009.
retros/             what each retrospective found, so the next one has a memory
.claude/hooks/no-subrepo-edits.sh   PreToolUse guard on Bash, probed by test-hooks.py
```

Steps 1-4 of this playbook produce a documents-and-scripts repo. `stack/`, `smoke/` and the
deploy-verify machinery arrived with `docs/adr/0002`, which also made this repo depend on
Docker and on the submodules being checked out. Planning still works without them; shipping
does not.

The `deny` rules in `.claude/settings.json` stop the editing tools from reaching a
submodule. They do not stop a shell command — `sed -i`, `tee`, a redirect. The
`PreToolUse` hook covers that gap. Both are needed; neither alone is sufficient.

### Step 4 — Attach the submodules

```bash
git submodule add https://github.com/<owner>/<backend-repo>.git <backend-repo>
git submodule add https://github.com/<owner>/<frontend-repo>.git <frontend-repo>
git submodule add https://github.com/<owner>/<infra-repo>.git <infra-repo>
./scripts/lock.sh
git add .gitmodules <backend-repo> <frontend-repo> <infra-repo> repos.lock
git commit -m "chore: vendor product repos as submodules"
```

Add each one at its final path first time. `git mv` relocates a submodule's *path* but
leaves its *name* — the `[submodule "..."]` key in `.gitmodules` and the directory
under `.git/modules/` — at the old value, and there is no porcelain command to rename
it afterwards.

Submodules land in **detached HEAD** on update. Any commit made there is on no branch
and is easy to lose. `git -C <repo> switch -c <branch>` before any work inside one —
The dispatch does this; interactive sessions must do it by hand. This is why it is a
hard rule in the control `CLAUDE.md` rather than a note in a doc. The dispatch `/ship`
runs does it for the slices; `/realign` does it when bringing them back to `main`.

### Step 5 — Make the gates real

Everything up to here is documentation, and documentation degrades silently.
`gate.sh` is the part that cannot be ignored by a model having a bad day. Per repo:

1. Add the toolchain and one passing test.
2. Uncomment the matching lines in `.claude/hooks/gate.sh`.
3. **Break a test on purpose and confirm the Stop hook blocks the turn.** An unverified
   gate is worse than no gate — it produces confidence without enforcement.
4. Fill in `.github/workflows/ci.yml` and mark each job a required status check.
   Secret scanning is non-negotiable and never delegated to agent judgement.

### Step 6 — Verify

Most importantly, the self-sufficiency test: clone one product repo alone into a fresh
directory outside the submodule tree, start a session, ask for a small change. If the
agent is missing context, the split is wrong — fix the product repo, not the control
repo.

---

## 2b. Attaching a product repo after the fact

Steps 1-5 assume a clean start. Attaching a repo to a system that is already running is the
same work in a different order, and `chatbot-eval` is the worked example — `docs/adr/0013`
is the decision, this is the procedure.

The thing that makes it awkward is that **the control session may not write inside a
submodule**, so the scaffold cannot be authored at its final path. Scaffold it somewhere
else, push it, and only then attach it.

```bash
gh repo create <owner>/<name> --private --description "<one line>"

# Scaffold OUTSIDE the submodule tree — the deny rules and the PreToolUse hook both key on
# the submodule paths, and a half-written repo at its final path is unattachable anyway.
# Same template as step 2: CLAUDE.md, .claude/{settings.json,hooks/}, docs/architecture.md,
# docs/adr/, contracts/, .github/workflows/ci.yml, README.md, .gitignore.
#
# contracts/ MUST carry the vendored specs from the start: vendor-contracts.sh only
# refreshes a file the repo ALREADY has (`[ -f "$dst" ] || continue`), so a repo that ships
# without them never receives a frozen contract and its CI verifies against nothing.
cd <somewhere outside this tree> && git init -b main && git push -u origin main

git submodule add https://github.com/<owner>/<name>.git <path>
./scripts/lock.sh
```

Then teach the harness. Every list below is hand-kept, and **only `test-hooks.py` fails when
one is missed** — so work down the list rather than trusting a grep:

| Where | What |
| --- | --- |
| `.claude/settings.json` | `Edit(./<path>/**)` deny rule (covers Write too) |
| `.claude/hooks/no-subrepo-edits.sh` | the `SUB` alternation |
| `scripts/test-hooks.py` | a BLOCK case and an ALLOW case for the new path — this is the probe that holds the two above honest |
| `scripts/manifest.py` | `REPOS`, so it may be a slice |
| `scripts/check-docs.py` | `SUBMODULES`, for the vendored-contract comparison |
| `scripts/lock.sh` · `prs.sh` · `vendor-contracts.sh` · `retro-evidence.sh` · `verify.sh` | their repo lists |
| `scripts/failure-brief.py` | `SERVICES` — which containers it is answerable for |
| `Makefile` | `REPOS` |
| `.claude/commands/realign.md` | the two loops over the repos |
| `stack/compose.yml` | an `include:` for its compose file, and an `agentapp.owner` label for each service it ships |
| `scripts/stack.sh` | `SERVICES`, for the failure dump |
| `CLAUDE.md` · `README.md` · `concept.md` | the repo table and the "never edit inside" rule |

`./scripts/check-docs.py`, `./scripts/test-hooks.py` and `make check` are what confirm it,
and the write guard must be **probed in both directions** before the session goes on: a
guard that blocks ordinary work is one the next agent routes around.

Finally, the feature itself is a change like any other. The scaffold is structure; the
toolchain, the image and the implementation arrive through `/ship`, in a session started
inside the new repo. Attaching the repo and implementing it in one session would put the
implementation outside that repo's own gates, which is the whole thing the split protects.

## 3. Where each new document goes

The single most common configuration mistake is putting everything in one place. For
any document, the question is: **when should this enter the context window?**

| If it is… | It goes in | Because |
| --- | --- | --- |
| a command, a layout fact, a rule that applies always | `CLAUDE.md` | always loaded — and therefore expensive |
| a procedure with a natural trigger phrase | `.claude/skills/<name>/SKILL.md` | loads only when the agent judges it relevant |
| a hard rule about one area of the tree | `.claude/rules/<name>.md` with `paths:` | loads only when a matching file is touched |
| durable truth: specs, architecture, decisions | `docs/` | never loads automatically; a skill points at it |
| something that must not happen | a hook or a `deny` rule | prose is advisory; only hooks are deterministic |

A product spec has no natural trigger phrase, so as a skill it either never activates
or activates constantly. Keep it in `docs/` and let a thin skill layer point at it.

**`CLAUDE.md` sizing: 40–60 lines maximum.** For each line ask *would removing this
cause the agent to make a mistake?* If not, delete it. An over-long `CLAUDE.md` causes
the agent to ignore the rules that matter, because the important ones are lost in
noise. Watch for the drift signal: if the agent repeatedly violates a written rule,
the file is too long. Shorten before adding emphasis.

---

## 4. What is a template and what is real

Everything created by this playbook is a template. Files carrying `<placeholder>`
markers or an `EXAMPLE / TEMPLATE` comment are structure, not decisions — they exist
so the shape is obvious and so nothing has to be invented under time pressure later.

Replace them as the need appears. Do not pre-write skills you have not needed yet: the
first one worth writing per repo is usually *how tests are written here*, and it should
be written after the first few tests exist, not before.

---

## 5. Verification

Nothing here is done until each of these has actually been observed, not assumed:

- [ ] Each product repo's Stop hook **blocks** when a test is deliberately broken.
- [ ] Each product repo's CI jobs are **required** status checks, secret scanning included.
- [ ] A product repo cloned alone into a fresh directory can be worked in without the
      control repo — the self-sufficiency test above.
- [ ] `make up` brings every repo up on one origin, and `make health` answers on `/api/`.
- [ ] `make check` is green: `check-docs.py`, the hook probe, every change validating, and
      each product repo's own lint and typecheck.
- [ ] One deliberately small cross-repo change has been driven end to end through `/ship`,
      reaching `verified-local` with assertions from its own suite — `verified` once a
      `/dev-push` on its PR is green — and `/realign` afterwards.
- [ ] `contracts/` cannot be edited from a product repo, and the control session cannot
      write into a submodule — `./scripts/test-hooks.py` proves the second in both
      directions.

---

## 6. Deliberately not done at init time

| Deferred | Adopt when |
| --- | --- |
| Language, framework, test runner, formatter, IaC tool | the first real feature forces the choice |
| Real contract entries | a real interface exists; an invented contract is worse than none |
| Spec-driven frameworks (OpenSpec, Spec Kit, BMAD) | `changes/` has ~10 entries and hand-written briefs visibly drift from the code |
| Agent teams | the dispatch proves insufficient because slices genuinely need to negotiate mid-flight |
| Dynamic workflows / high-effort orchestration | a task needs dozens of agents — a repo-wide migration or audit |
| Deep multi-agent review | change size makes local review unreliable |
| Shared-convention plugin in an internal marketplace | per-repo skill duplication becomes a maintenance burden |
| Skills in the control repo | a procedure here genuinely has a natural trigger phrase — `docs/adr/0005` explains why the first four did not |
| Instruction-drift detection from session transcripts | the base gates are stable — not on day one |

---

## 7. Review cadence

Revisit after roughly ten completed changes, and after any major model release. Rules
written to work around a weaker model become pure friction on a stronger one. Prune
aggressively: assume a rule is obsolete until it earns its place.

Track which skills never activate and retire them. Review `CLAUDE.md` and skill changes
in pull requests like any other documentation, so conventions track the code instead of
drifting from it.
