# agent-app-project

Control repo for a multi-tier system developed primarily through AI coding agents. It holds
the one thing that cannot live inside any single product repo: the interface between them.

| Repo | Submodule path | Contents | Deploy cadence |
| --- | --- | --- | --- |
| [`agent-app-project`](https://github.com/Paggio/agent-app-project) | — | contracts, change briefs, cross-cutting docs, orchestration | n/a |
| [`chatbot-backend`](https://github.com/Paggio/chatbot-backend) | `chatbot-backend/` | API service | per merge |
| [`chatbot-eval`](https://github.com/Paggio/chatbot-eval) | `chatbot-eval/` | one-shot eval run: fixture corpus, question set, Phoenix experiments | on a schedule |
| [`frontend`](https://github.com/Paggio/frontend) | `frontend/` | web client | per merge |
| [`infra`](https://github.com/Paggio/infra) | `infra/` | IaC | reviewed, gated |

## Clone

```bash
git clone --recurse-submodules git@github.com:Paggio/agent-app-project.git
# or, after a plain clone:
git submodule update --init --recursive
```

## Where the work happens

**One repo.** Around 80% of the work, and it costs nothing: no orchestration, no fan-out,
no contract pass. That repo's CI fails if the work turns out to touch contract surface,
which is the signal to come back here.

```bash
cd chatbot-backend   # or chatbot-eval, frontend, infra
claude
```

**Anything spanning repos** — including any change to `contracts/` on its own.

```bash
claude
> /ship "authenticate the chat endpoint and point the UI at it"
```

One command, five phases: it writes the change artifact (`changes/NNNN-<slug>/` — brief,
acceptance criteria as executable smoke steps, one slice file per repo), freezes the
contract in a commit of its own, gates on `manifest.py --validate`, dispatches a session
into each product repo and loops deploy-assert-repair until the criteria hold through one
origin, then opens the pull requests. **That last loop is what "shipped" means** — the repos
deployed together with the suite passing, not three PRs existing. See `docs/adr/0002`.

Nothing is merged for you. Merging is a human decision, in dependency order.

**Not what you asked for.** Either the loop never went green, or it did, the pull requests
are open, and you have now looked at the thing. Same objection: something you wanted is not
true of what was built.

```bash
> /ship-correct 0004-rag-knowledge-base: citations repeat when two chunks come from one document
```

You say what is wrong; the lane does the triage. It settles whether the criterion was
missing or too weak to fail, writes the step that fails against what is already built, and
routes it to the repo `verify.json` names answerable — then runs the loop against the
branches that exist. **The objection has to become an assertion**, because a dislike that
never becomes a criterion is one the next change silently re-breaks. See `docs/adr/0012`.

**Changed your mind before it merged.** Same window, but the requirement itself is what you
now want different.

```bash
> /ship-iterate 0004-rag-knowledge-base: also accept PDFs, and drop the summary column
```

Amends the brief, the criteria and the slice briefs in that order, re-freezes the contract
if the interface moved, then runs the same loop against the branches that already exist —
so the open pull requests update rather than multiply. It refuses once anything has merged,
because at that point the criteria describe what is running and a new change is the honest
record. See `docs/adr/0010`.

**After the merge.**

```bash
> /realign
```

Bumps the submodules to their merged `main`, pins their SHAs in `repos.lock`, re-checks
`contracts/` against what the services actually serve, re-runs the baseline suite, and
promotes the assertions worth keeping forever into `smoke/baseline.yaml`. This is also the
lane a single-repo deploy needs on its own — it is the only check that can fail on the seam.

**Every lane ends by grading itself.** The last phase of `/ship`, `/ship-correct`,
`/ship-iterate` and `/realign` dispatches the `harness-retro` agent: a separate session that
audits the state the lane left behind — submodule pointers, the contract against what is
served, the assertions and their count, whether anything actually reached a remote
environment — and then grades the harness itself. Where the instructions misled, where a
gate protected nothing, where the effort was out of proportion to the risk. If something
clears its bar it opens one pull request here, on a `harness/` branch, for a human to merge.
If nothing does, it says so and opens nothing. See `docs/adr/0009`.

## Where things live

- `concept.md` — the reasoning behind this layout, and the parts of it that are load-bearing.
- `docs/adr/` — decisions and their accepted costs. Read before proposing a redesign.
- `docs/infra-interface.md` — what this repo requires of `infra/`.
- `docs/init/` — how the repos were created from zero, and how a new one is attached.
- `retros/` — what each lane's retrospective found, and the reason the next one does not
  raise the same thing twice.
- `CLAUDE.md` — additive agent context. Never load-bearing; every product repo is
  self-describing in isolation.
- `make help` — the hand tools for running and inspecting the joined system.
