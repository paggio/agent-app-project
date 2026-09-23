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

The product repos — `chatbot-backend`, `chatbot-eval`, `frontend`, `infra` — are
vendored here as git submodules.

**Why split at all.** Each product repo keeps its own git history, CI pipeline, deploy
cadence, secret scope and observability. A shared pipeline couples deploy risk across tiers
with very different review requirements — infra is gated, the app repos are per-merge.

**Why a control repo.** Agents working in separate repos will each re-derive the
interface between them if allowed to, and they will disagree in small ways that surface in
production rather than in review. Prose cannot prevent that, because **instruction text
cannot fail a build**. A contract can. The control repo exists to hold the one thing that
cannot live inside any single product repo.

**The accepted costs**, stated because an argument that lists only benefits is a sales
pitch: a feature spanning every repo produces a pull request and a CI run in each
and cannot merge atomically; version skew is a permanent tax, paid via expand-contract
migrations and feature flags; and submodules are a sharp edge (§6). The fallback, if the
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
is honoured at runtime, and for a while nothing filled that gap: the repos could each be
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

## 4. One lane per state, and the state is a fact

| The work | Lane |
| --- | --- |
| One repo, no interface change | none — `cd <repo> && claude` |
| Two or more repos, or any change to `contracts/` | `/ship` |
| The result is not what you asked for | `/ship-correct` |
| You want a different requirement than the one you asked for | `/ship-iterate` |
| The product PRs are merged and this repo is behind | `/realign` |

`/ship` is plan → freeze → gate → dispatch-and-repair → pull requests, in one invocation.
`/ship-correct` turns an objection into a failing assertion and routes it to the repo
answerable. `/ship-iterate` amends the brief, the criteria and the slices, then re-runs the
loop. `/realign` is bump → re-check the contract against what is served → re-run the
baseline → pin → promote.

**Which one is never a judgement call.** Every boundary between them is a fact something can
read: whether a pull request exists, whether one has merged, whether the criterion you want
is already in `smoke.yaml`. Each lane refuses in the states that are not its own and names
the one that is. `docs/adr/0010`, `docs/adr/0012`.

**Why the phases inside a lane are not lanes of their own.** The invariant that matters is
that the freeze commit precedes the dispatch and lands alone, and that is machine-enforced.
Keeping plan, freeze and implementation in separate sessions was a proxy for the same thing,
and the proxy cost a handoff per change while buying nothing the gate does not. It also
produced four competing skills describing one activity, which is how the documentation
drifted in the first place. `docs/adr/0005`.

**Why the control repo dispatches processes rather than spawning subagents.** Each
dispatched session starts with its working directory inside the real product repo, so it
picks up that repo's `CLAUDE.md` chain, its settings, its skills, its hooks and its git
remote. A subagent of the control session would inherit the control session's context, which
is exactly the coupling the split exists to avoid.

**Agents implement; they do not decide whether the change is done.** The control flow, the
attribution and the stopping conditions live in shell where they can be read and audited.
The suite decides.

---

## 5. The lanes, worked

The table above is the decision. This is what each lane is actually like, end to end.

### 5.1 In one module — the common case, and it costs nothing

*"The login throttle's window and threshold are hardcoded. Make them configurable."*

Nothing crosses a repo boundary: no path, status, field or infra output moves, so
`contracts/openapi.yaml` is untouched and `429` on `/v1/auth/login` is already declared.
That makes it a solo change, and solo changes do not come here at all.

```bash
cd chatbot-backend
claude
```

The session loads `chatbot-backend/CLAUDE.md`, its `.claude/settings.json`, its skills and
its hooks — and nothing from `frontend/` or `infra/` enters context. From inside:

```bash
git switch -c feat/configurable-login-throttle   # never commit on main
make test typecheck lint                          # the Stop hook runs these anyway
make contract                                     # implementation vs the vendored spec
```

The Stop hook refuses to end the turn until those pass, which is what converts "looks
done" into "provably done". Then a normal PR in that repo, reviewed and merged on its own
cadence. **The control repo never hears about it.**

**The tripwire.** If the work turns out to touch contract surface — a new field a consumer
would read, a status a caller must handle — that repo's own `make contract` fails against
its vendored copy. That failure is the signal to stop and come back here for `/ship`. You
do not have to judge the boundary correctly up front; the gate judges it for you.

**After it merges**, this repo is one commit behind the submodule it pins:

```bash
claude
> /realign
```

which brings the submodule to its merged `main`, re-checks the contract against what the
service now actually serves, re-runs the baseline suite through the joined origin, and pins
the SHAs in `repos.lock` — one commit containing the pointers and the lock and nothing
else. A single-repo deploy still needs this lane, because a product repo's own CI can only
ever prove that repo is consistent with itself.

### 5.2 Across repos — one command, five phases

*"Let people rename and delete their conversations."*

Two endpoints the frontend must call, so the interface moves and three repos disagree
about it the moment they are allowed to guess.

```bash
cd agent-app-project
claude
> /ship "let people rename and delete their conversations"
```

That is the whole invocation. What it does, and what you should read as it goes:

| Phase | Produces | Worth reading |
| --- | --- | --- |
| 1 plan | `changes/0003-rename-delete-threads/` — brief, `smoke.yaml`, one slice file per repo, `change.yaml` | **the acceptance criteria.** The gate cannot judge whether they are any good. |
| 2 freeze | one commit containing `contracts/` and nothing else; its SHA in `change.yaml` | whether the change is additive — the repos deploy independently, so production runs mismatched versions |
| 3 gate | `./scripts/manifest.py changes/0003-rename-delete-threads --validate` | it exits 0, or exits 2 naming exactly what to fix |
| 4 loop | a session per slice, all repos up as one stack, the suite through one origin, repair on failure | the outcome word, and the assertion count beside it |
| 5 PRs | `runs/<ts>/prs.json` | the URLs, which are checked facts rather than an agent's claim |

Phase 4 takes tens of minutes and runs a real agent per slice, so start it where it will
outlive the turn. A run killed halfway reports `unattributable` with no assertion evidence
— honest about a run that did not finish, and not a result about the change.

**What "done" looks like:**

```
verify: PASS — 0003-rename-delete-threads verified against http://localhost:8080
verify: 19 assertion(s) passed, 11 of them from changes/0003-rename-delete-threads/smoke.yaml
```

Read the count, not just the word. A report cannot say `verified` above an empty one, and a
thin count means the criteria were thin.

**Then a human merges**, in the dependency order `STATUS.md` records — the repo whose half
is backward compatible on its own goes first. Nothing here merges for you. Afterwards:

```bash
> /realign
```

which promotes the assertions worth keeping forever out of the change's `smoke.yaml` and
into `smoke/baseline.yaml`, so the next change cannot silently break this one.

### 5.3 It is not what you asked for

Two versions of this, and they turn out to be one problem:

- **the loop never went green** — `failed`, `contract-gap`, `unattributable`. `/ship`
  reports the outcome with the table that says what each one means, so it is not restated
  here.
- **the loop went green, the pull requests are open, and you have now actually looked at
  the thing.** The most common state of all, and the one with the least written about it.

The second is the first arriving later: something you wanted is not true of what was built,
and this time **no assertion was watching**. So one lane covers both, and **the lane is not
over — you do not start a new change**:

```bash
> /ship-correct 0004-rag-knowledge-base: citations repeat when two chunks come from one document
```

You say what is wrong. The lane decides the rest — whether the criterion was missing or
present and too weak to fail, and which repo is answerable — because those are answers
already sitting in `smoke.yaml` and in `verify.json`'s `owners_failing`, not preferences
you should be asked about. What it costs then follows from the answer rather than from
guessing: one repo answerable is one dispatched session, and only a wrong *interface* costs
a re-freeze and rebuilds every slice.

**The objection has to become an assertion, and that assertion has to fail before anything
is rebuilt.** A dislike that never becomes a criterion is one the next change silently
re-breaks, and the criteria are supposed to outlive the conversation that produced them.
`make verify CHANGE=<change>` is what makes that cheap: it asserts what is checked out and
dispatches nothing.

Three things bite.

- `make verify` asserts what is **checked out**, uncommitted work included. That is what
  makes it the fast loop, and it is also why a green verify is not evidence about what a
  reviewer will see unless the submodule trees are clean. It refuses unless each slice repo
  is on `feat/<change>`, because asserting against code this change did not write is a pass
  that means nothing.
- **Do not merge in order to fix.** Merging ends this lane; `/realign` is the after-merge
  lane and it will not reopen it. Correct while the pull requests are still open.
- If a smoke assertion is what you disagree with, it changes **here, on purpose** — never in
  a product repo, and never by weakening it to match what was built. That is the one edit
  this whole structure exists to prevent.

The stack is left running after a verify, so underneath all of it the loop is `make ps`,
`make logs SVC=backend` and `./scripts/stack.sh rebuild backend` — one service, not a full
cycle.

### 5.4 You changed your mind about the requirement

Different from 5.3, and the difference decides the lane: there the criterion was right and
the build was wrong. Here the build may be fine and **the criterion is what you no longer
want.**

```bash
> /ship-iterate 0004-rag-knowledge-base: also accept PDFs, and drop the summary column
```

It amends `BRIEF.md`, then `smoke.yaml`, then the slice files — that order, because each is
the input to the next and starting at the code produces a change whose record no longer
matches it — re-freezes if the interface moved, re-gates, and runs the loop against the
branches that already exist, so the open pull requests update rather than multiply.

**Merge is the boundary.** Both this lane and 5.3 refuse once anything has merged, because
at that point the criteria describe what is running and rewriting them destroys the record
of what was decided and when. Then it is a new change. `docs/adr/0010`, `docs/adr/0012`.

Two things worth knowing before you invoke it:

- **A dropped requirement does not remove itself.** Its implementation is on the branch, and
  agents add rather than subtract — so the slice file has to say "remove this" in words. The
  lane does that; it is the step most worth reading in its output.
- **Additive-by-default is suspended until the first merge.** That rule exists for deploy
  skew and nothing has deployed, so a frozen-but-unmerged contract can be reshaped freely —
  a field removed, the version left alone. The window closes at the first merge.

### 5.5 Deploying it — `dev`, from the pull request

*"It passes locally. Does it work in AWS?"*

There is one AWS account, treated as `dev`, and one environment. The loop never touches it
— `verified-local` is its ceiling — because deploys run in GitHub Actions, triggered from
the pull request under review. `docs/adr/0018`.

The whole life of a change that deploys:

| Step | Who | What it proves |
| --- | --- | --- |
| `/ship` | the lane | `verified-local`, and a PR per slice repo plus one here |
| `make login && make push-gh-creds` | you, once per working session | CI holds a session that dies with yours |
| `/dev-push` on the control PR | the lane (phase 5b), or you | `verified`: the PR's exact commits ran together in AWS and both suites held through CloudFront |
| merge, in `STATUS.md` order | a human | nothing yet — see below |
| `/realign` | the lane | the merged commits, pinned, deployed from the lock and asserted there |
| `make dev-down` | you, when idle | nothing bills but bootstrap — `leftovers` says so |

**Which commits a deploy builds.** Not the gitlinks: mid-change they name the last merged
`main`, and the change lives on `feat/<change>` (§6). The deploy set is resolved from the
trigger and posted on the PR before anything is built:

| `/dev-push` on | slice repos | every other repo |
| --- | --- | --- |
| a change's control PR | the head of `feat/<change>` on the remote | the gitlinks of that PR |
| a product repo's PR | that PR's head | control `main`'s gitlinks |
| any other control PR, or `make dev-up` | — | that ref's gitlinks |

An unpushed slice branch, or a gitlink that disagrees with `repos.lock`, is a refusal
(exit 2). Images are tagged with the commit and never rebuilt, so a second `/dev-push`
costs an apply, not a build. `/dev-push-backend` (or `-frontend`, `-infra`) rebuilds one
repo and carries the others at what `dev` already runs; that is `deployed-partial`, never
`verified`, because the commits it asserts are not all the PR's.

**Why `/realign` is still required**, even when every PR was pushed and green:

- the gitlinks are behind the moment a product PR merges — that has not changed;
- a squash merge mints new SHAs, so the images `/dev-push` verified are not the ones on
  `main`, and nothing has yet asserted the merged code deployed together;
- `dev` is last-writer-wins, so after a PR's `/dev-push` it runs unmerged code. The lock is
  what `dev` should run when no PR is under test, and `/realign` is what puts it back.

A single-repo change is the same: its PR's `/dev-push` proves the PR, `/realign` proves `main`.

**The credentials, end to end.** `make login` is SSO, and rewrites the four credential lines
of `stack/secrets.env`, expiry included. `make push-gh-creds` copies that session into
`DEV_AWS_*` repository secrets of the five repos — GitHub Free has no Environments for
private repos, so the prefix is where `dev` lives. Every job refuses with under 30 minutes
left (exit 2, naming the command), then assumes `agentapp-dev-deployer` and uses nothing
else. That role, the state bucket, the registries and the budget come from
`make dev-bootstrap`, the one apply run from here, once; `make gh-setup` wires the
read-only deploy keys the workflow reads the other repos with. No long-lived AWS key exists
anywhere.

Three things bite.

- **`/dev-push` runs `main`'s copy of the workflow.** A change to it takes effect once
  merged — which is also why a PR cannot rewrite what holds the credentials.
- **`dev` is shared.** A `/dev-push` replaces whatever else was deployed, and its comment
  names what it replaced. A product repo's run is not serialised with the control repo's,
  so the remote pass re-reads what `dev` runs after the suite and refuses a result about
  commits it did not deploy.
- **`dev` bills while it is up, about $0.30 an hour**, and nothing tears it down for you.
  `make dev-down`, or `make dev-down VIA=ci` from anywhere; a teardown is done when
  `leftovers` is empty, not when `destroy` exits 0.

---

## 6. Submodules, the sharpest edge

Two failure modes recur, and one example covers both.

**Detached HEAD.** `git submodule update` leaves each submodule detached. Commits made there
are on no branch and are easy to lose. Branch before any work — the dispatch does this;
interactive sessions must do it themselves.

**Stale pointers.** The control repo pins SHAs, and they have to be bumped after the product
PRs merge — in that order, never before.

There are **three independently-moving values** per submodule, and a fourth once it deploys;
mistaking one for another causes nearly every submodule mistake in this layout:

| | what it is | mid-change | after the bump |
| --- | --- | --- | --- |
| the gitlink in the parent's `HEAD` | what the parent *records* | the last merged commit | the merged `main` |
| what is checked out | what is *on disk* | the feature branch | the same merged `main` |
| `repos.lock` | the human-readable duplicate | the same as the gitlink | the same merged `main` |
| what `dev` runs | what is *deployed* | the last `/dev-push`'s deploy set | the lock, once `/realign` redeploys it |

The gitlink and the lock move together, in one `/realign` commit, and a deploy refuses when
they disagree. Only the last row is read off something other than git — the PR comment and
`make dev-status` say what `dev` runs.

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
   which is worse than a stale pin because it looks authoritative. Then deploy the pin
   (§5.5) — that run, not the merge, is the one that asserts `main`.

`make repos` reports the disagreement between all three values, at any stage. `/realign`
performs the sequence.

---

## 6b. Configuration and secrets: where to put things

Two files under `stack/`, split by one question — **can this be committed?**

| File | Committed | Holds | Read by |
| --- | --- | --- | --- |
| `stack/dev.env` | yes | non-secret config, grouped by service; every `${VAR}` a smoke suite interpolates | the scripts, and compose |
| `stack/secrets.env` | **no, gitignored** | real credentials: AWS keys and the region | compose's `env_file` only |

### Putting your credentials in

```bash
cp stack/secrets.env.example stack/secrets.env   # region and mode already filled in
#  paste your AWS keys into it
make creds                                       # says what resolved, never prints a value
```

**Credentials alone switch nothing.** The backend never sniffs for them — which model it
builds is an explicit selector, so a fully credentialled stack still serves `echo` until
`CHAT_MODEL=bedrock` is set. That is why the same file carries the mode:

```
CHAT_MODEL=bedrock     # echo | bedrock      — the backend's model
EVAL_JUDGE=heuristic   # heuristic | bedrock — the eval's judge
```

Those two are the **only** names any script here reads out of that file, through an
allowlist, so a credential can never follow them in. `make creds` prints what they resolve
to and from which layer, and says so when credentials are present while the model is still
`echo`. `docs/adr/0017`.

That is the whole of it. **Every service that needs them gets them automatically** — no
export, no second copy, no flag:

```bash
make up                      # backend, with CHAT_MODEL=bedrock available
make eval JUDGE=bedrock      # the eval, with the real judge
make iterate CHANGE=...      # and the loop
```

`backend` and `eval` are the two services wired to that file, in `stack/compose.yml`.
`frontend` and `proxy` are not, because they call no provider. A new service that needs
credentials is one `env_file` entry plus one name in `check-docs.py`'s
`PROVIDER_SERVICES` — and the gate fails until both are there.

### What wins over what

Highest first. Measured, not taken from the manual:

1. `environment:` in a compose file
2. the real process environment — `CHAT_MODEL=echo make up`
3. **`stack/secrets.env`** — the joined stack's shared credentials
4. `<submodule>/.env` — that repo's own file

So a per-repo `.env` keeps working for `cd chatbot-backend && make up`, and in the joined
stack `stack/secrets.env` overrides it. You do not have to delete the per-repo files, and
you should stop adding to them.

### Two rules `stack/dev.env` will punish you for breaking

Both are gates, because both have cost a run:

- **One line per name.** A name declared twice resolves to the **first**; the second is
  dead. This silently ran a stack on `BACKEND_IMAGE_TAG=dev` while every reader of the file
  saw `local-0.0.1`.
- **No trailing comments.** Everything after the first `=` is the value, verbatim — no
  comment stripping, no quote stripping. `SIGNUP_CODE=abc  # gates registration` sets the
  code to `abc  # gates registration`. Comments go on their own line.

### Why the secrets never enter a script here

`scripts/dev-env.sh` is **forbidden** from reading `stack/secrets.env`, and that is a gate
rather than a convention. This repo writes `verify.json`, `smoke.json`, container logs and
repair prompts; a credential in the environment of the process that writes them is one
careless dump away from being committed. Compose hands the file to the Docker daemon and no
process here ever sees it. `docs/adr/0006` and `docs/adr/0016`.

Three hand tools are the exceptions, and each writes no artifact: `make login` writes the
credential lines, `make push-gh-creds` copies them to GitHub over `gh`'s stdin, and
`scripts/with-aws.sh` exports them into the one command it runs — bootstrap, teardown, a
look at the cluster. `docs/adr/0018`.

The corollary worth knowing: **`make creds` prints names and provenance, never values**, and
`make config` redacts. Plain `docker compose config` on the joined stack does not — do not
run it.

### When the region is missing

The failure does not look like a missing region. boto3 reports it inside a sentence that
begins "Could not load credentials to authenticate with AWS client", which sends you to
audit credentials that are fine. `make creds` is the answer, and the eval now refuses up
front naming the variable instead of letting a validation dump do it.

## 7. Where instructions live

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

## 8. Enforcement

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
  on ordinary work is one the agent learns to route around. The deploy workflows are held
  the same way: every secret they read is one a script here writes, none names a GitHub
  Environment (there are none on this plan), and `actionlint` runs in CI because a workflow
  that only runs from `main` is otherwise first tested by a real deploy.
- **Every product repo's CI**, as required checks: typecheck, lint, unit and integration
  tests, contract conformance, secret scanning.

A guard that is documented must be called. Three here were not — a variable consumed and
never set, labels read and never declared, a diff gate cited in three files and wired to
nothing — and each read as protection while providing none.

---

## 9. Managing version skew

Production will always briefly run mismatched versions.

- **Backend:** additive within a release. New fields optional, new endpoints alongside old,
  deprecations in a later change.
- **Frontend:** feature-flagged, so it can merge and deploy before the capability exists.
- **Database:** expand-contract across separate merges, never one breaking DDL.
- **Infra:** outputs are additive; removing one is its own change, consumers first.

---

## 10. Maintenance

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
