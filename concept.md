# Why this repo looks like this

The reasoning behind a four-repo, contract-first layout developed primarily through AI
coding agents. `docs/adr/` is the record of each decision and its accepted costs;
`docs/init/` is how the repos were created. This file is the argument that ties them
together — the part worth reading once, before proposing a redesign.

**It holds no file contents and no script bodies.** An earlier version quoted both, and
that is precisely what rotted: it went on teaching a form of `fanout.sh` that
`docs/adr/0002` had replaced, at five times this length. Where prose and mechanism disagree,
the mechanism wins, and the mechanism is never quoted here.

---

## 1. Four repos, one of them a control repo

| Repo | Contents | Deploy cadence |
| --- | --- | --- |
| `agent-app-project` (control) | contracts, change artifacts, cross-cutting docs, orchestration | n/a |
| `chatbot-backend` | API service and agent graph | per merge |
| `frontend` | web client | per merge |
| `infra` | IaC | reviewed, gated |

The three product repos are vendored here as git submodules.

**Why split at all.** Each product repo keeps its own git history, CI pipeline, deploy
cadence, secret scope and observability. A shared pipeline couples deploy risk across tiers
with very different review requirements — infra is gated, the app repos are per-merge.

**Why a control repo.** Three agents working in three repos will each re-derive the
interface between them if allowed to, and they will disagree in small ways that surface in
production rather than in review. Prose cannot prevent that, because **instruction text
cannot fail a build**. A contract can. The control repo exists to hold the one thing that
cannot live inside any single product repo.

**The accepted costs**, stated because an argument that lists only benefits is a sales
pitch: a feature spanning all three repos produces three pull requests and three CI runs
and cannot merge atomically; version skew is a permanent tax, paid via expand-contract
migrations and feature flags; and submodules are a sharp edge (§5). The fallback, if the
three-PR overhead ever becomes the dominant friction, is to merge backend + frontend +
contracts into one repo and keep infra separate. `docs/adr/0001`.

---

## 2. The contract is the coordination mechanism

`contracts/` is edited **here and only here**. Product repos vendor a read-only copy and
verify conformance in their own CI.

- `openapi.yaml` — the HTTP interface
- `infra-outputs.yaml` — what infra promises the app repos (ARNs, URLs, secret names)
- `README.md` — the normative prose neither file can hold: cookie attributes, the CSRF
  posture, the `/api/` prefix invariant, the rule that decides between two error shapes

**The freeze is a commit, and then a tree.** A contract change lands in a commit containing
nothing else; that commit's SHA goes in the change's `change.yaml` as `freeze_sha`; and the
dispatch extracts `contracts/` at exactly that SHA and gives the implementing sessions
nothing else. So "frozen" is not a promise an agent is trusted to honour — it is the only
tree it can read. That distinction is the whole design: an earlier version said FROZEN in
the prompt while granting access to the working copy.

Additive by default, because the repos deploy independently and production will always
briefly run mismatched versions. New fields optional, new endpoints alongside old ones,
removals in a later change once every consumer is updated.

---

## 3. Verification is what makes any of it true

A contract says what the interface *should* be. It says nothing about whether the interface
is honoured at runtime, and for a while nothing filled that gap: three repos could each be
internally green while the seam between them was broken, and nobody found out until someone
ran the whole thing by hand. The frontend's tests passed against mock clients; the backend's
passed against itself; the proxy could not resolve the backend at all.

So the control repo also owns:

- **the joined stack** — every repo in one compose project and therefore one network,
  behind the single origin a browser would use. Neither product repo may own this: the
  frontend cannot name a service it does not ship, and the backend has no business knowing
  a proxy exists.
- **the cross-repo smoke suite** — `smoke/baseline.yaml` plus a `smoke.yaml` per change,
  asserted through that origin. Every step names an `owner`: the repo answerable for it.
  That field is what makes a failure routable to one agent with the request, the response
  and the container log attached, instead of a group email.

Keep the suite about the **seam**. Anything provable inside one repo belongs in that repo's
own tests. `docs/adr/0002`.

### A pass requires counted evidence

Every gate here fails closed, and that is a decision rather than an implementation detail.
The rules:

1. **Exit 1 means the thing under test failed. Exit 2 means the harness refused to judge
   it.** No caller may conflate the two. A malformed suite, an undefined variable, an
   unparseable manifest and an empty step selection are the control repo's fault, reported
   as such rather than routed to a product repo as a repair brief.
2. **A pass requires counted assertions**, including at least one from the change's own
   suite. A run that proves only that the stack still works says so, and fails.
3. **Every dispatched agent returns a structured result, or is recorded as failed.** "No
   result" is a defined outcome, not an accident.

Each of those exists because the opposite happened: an outcome inferred from the absence of
a failure signal rather than from the presence of evidence. `docs/adr/0003`.

---

## 4. Two commands

| The work | Lane |
| --- | --- |
| One repo, no interface change | none — `cd <repo> && claude` |
| Two or more repos, or any change to `contracts/` | `/ship` |
| The product PRs are merged and this repo is behind | `/realign` |

`/ship` is plan → freeze → gate → dispatch-and-repair → pull requests, in one invocation.
`/realign` is bump → re-check the contract against what is served → re-run the baseline →
pin → promote.

**Why one command rather than three.** The invariant that matters is that the freeze commit
precedes the dispatch and lands alone, and that is machine-enforced. Keeping plan, freeze and
implementation in separate sessions was a proxy for the same thing, and the proxy cost a
handoff per change while buying nothing the gate does not. It also produced four competing
skills describing one activity, which is how the documentation drifted in the first place.
`docs/adr/0005`.

**Why the control repo dispatches processes rather than spawning subagents.** Each
dispatched session starts with its working directory inside the real product repo, so it
picks up that repo's `CLAUDE.md` chain, its settings, its skills, its hooks and its git
remote. A subagent of the control session would inherit the control session's context, which
is exactly the coupling the split exists to avoid.

**Agents implement; they do not decide whether the change is done.** The control flow, the
attribution and the stopping conditions live in shell where they can be read and audited.
The suite decides.

---

## 5. Submodules, the sharpest edge

Two failure modes recur, and one example covers both.

**Detached HEAD.** `git submodule update` leaves each submodule detached. Commits made there
are on no branch and are easy to lose. Branch before any work — the dispatch does this;
interactive sessions must do it themselves.

**Stale pointers.** The control repo pins SHAs, and they have to be bumped after the product
PRs merge — in that order, never before.

There are **three independently-moving values** per submodule, and mistaking one for another
causes nearly every submodule mistake in this layout:

| | what it is | mid-change | after the bump |
| --- | --- | --- | --- |
| the gitlink in the parent's `HEAD` | what the parent *records* | the last merged commit | the merged `main` |
| what is checked out | what is *on disk* | the feature branch | the same merged `main` |
| `repos.lock` | the human-readable duplicate | older still | the same merged `main` |

A submodule is one SHA, not a branch: in the parent it is a tree entry whose entire content
is a commit id. So a submodule "change" in `git status` is always a pointer move, never a
file edit — read it as *"the pointer would move"*, and leave it alone mid-change. The parent
should only ever record commits that are permanently reachable on a product repo's `main`.

The rules that follow:

1. Never `git add` a submodule path casually, and never `git add -A` at the parent root,
   which sweeps every pointer in as a side effect.
2. Branch inside the submodule before committing there. Always.
3. Do not run `git submodule update --remote --merge` while work is in flight; it yanks
   checked-out submodules back and discards in-flight commits.
4. Merge first, then pin, then bump the pointers — as one commit containing only the
   pointers and `repos.lock`. Pinning first records commits that a squash-merge deletes,
   which is worse than a stale pin because it looks authoritative.

`make repos` reports the disagreement between all three values, at any stage. `/realign`
performs the sequence.

---

## 6. Where instructions live

The most common configuration mistake is putting everything in one place. The right question
for each document is **when should this enter the context window?**

| Destination | Loads | Contents |
| --- | --- | --- |
| `CLAUDE.md` | every session | commands, layout, hard rules, gotchas. **40–60 lines.** |
| `.claude/commands/*.md` | when invoked | the lanes. One per thing this repo does. |
| `.claude/skills/*/SKILL.md` | on the model's judgement | procedures with a natural trigger |
| `.claude/rules/*.md` (`paths:`) | when a matching file is touched | hard local rules for one area |
| `docs/` | never automatically | durable truth: ADRs, architecture, interfaces |

**Reference is not a procedure.** This repo has no skills, on purpose. Four of them once
described one activity — planning, freezing, aligning, deploying — and competed to activate;
what each actually held was reference that has to be *exactly* right at the moment it is
read. That belongs in a file read deliberately (`docs/`, `contracts/README.md`) with a
command routing to it, not in a skill that fires on a description match. A product spec has
no natural trigger phrase either: as a skill it never activates or always does.

**`CLAUDE.md` sizing.** For each line, ask: *would removing this cause a mistake?* If not,
delete it. An over-long file causes the rules that matter to be lost in the noise. The
symptom is an agent repeatedly violating a rule that is written down, and the fix is almost
always to shorten the file, not to add emphasis. This is checked mechanically, because the
file drifted past its own budget while stating it.

Note that `.claude/settings.json` does **not** layer from parent directories the way
`CLAUDE.md` does — it loads only from the directory the session starts in. Each product repo
therefore needs a complete, self-contained file.

---

## 7. Enforcement

Instructions are advisory. Hooks and gates are deterministic. Anything that genuinely must
not happen belongs in a mechanism, not in prose.

- **Per product repo:** a `Stop` hook that refuses to end a turn until typecheck, tests and
  contract conformance pass. This converts "looks done" into "provably done" and is the
  single highest-leverage file in the layout. Keep it fast; a gate that takes two minutes
  gets disabled.
- **Here:** `manifest.py --validate` is the ship gate; `smoke.py --lint` owns the step
  schema; `check-docs.py` holds the prose to the mechanisms, each check tied to a
  documentation defect that actually happened; a `PreToolUse` hook blocks shell writes into
  a submodule, and `test-hooks.py` probes that guard in both directions — a guard that fires
  on ordinary work is one the agent learns to route around.
- **Every product repo's CI**, as required checks: typecheck, lint, unit and integration
  tests, contract conformance, secret scanning.

A guard that is documented must be called. Three here were not — a variable consumed and
never set, labels read and never declared, a diff gate cited in three files and wired to
nothing — and each read as protection while providing none.

---

## 8. Managing version skew

Production will always briefly run mismatched versions.

- **Backend:** additive within a release. New fields optional, new endpoints alongside old,
  deprecations in a later change.
- **Frontend:** feature-flagged, so it can merge and deploy before the capability exists.
- **Database:** expand-contract across separate merges, never one breaking DDL.
- **Infra:** outputs are additive; removing one is its own change, consumers first.

---

## 9. Maintenance

**Review the harness every three to six months, and after every major model release.**
Rules written to work around a weaker model become pure friction on a stronger one. Prune
aggressively; assume a rule is obsolete until it earns its place.

**Watch for the drift signal.** If an agent repeatedly violates a written rule, the file is
too long and the rule is being lost. Shorten before adding emphasis. If prose describes a
mechanism that does not exist, that is not a documentation bug — it is a missing mechanism
or a lie, and both are worse than silence.

**Review `CLAUDE.md`, command and skill changes in pull requests** like any other
documentation, so conventions track the code rather than drifting from it.

**Deliberately deferred**, each until a specific symptom demands it: spec-driven frameworks,
agent teams that negotiate mid-flight, repo-wide dynamic orchestration, a shared-convention
plugin. `docs/init/README.md` holds the adoption triggers.
