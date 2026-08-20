---
description: Fan out a planned change to the product repos, deploy it, smoke it, and report.
argument-hint: <change-dir-name, e.g. 0042-csv-export>
---

Ship the change `$1`.

Shipping means the slices are implemented, deployed together, and asserted against — not
that three PRs exist. `./scripts/iterate.sh` does the whole loop and is the only thing you
need to run; everything below is about checking it is safe to start and reading what comes
back.

## Preconditions

Run `./scripts/manifest.py changes/$1 --validate`. It exits 0, or it exits 2 and names what
to fix. It checks `change.yaml`, the freeze SHA and its reachability, that `contracts/` is
clean, that `BRIEF.md` has been filled in, and `smoke.yaml` — including that every step has
an `owner` and that **every slice has at least one step it is answerable for**. Fix what it
names; do not proceed, and do not work around it.

Nothing else is checked by hand. Docker is checked by `verify.sh` preflight. One thing the
validator cannot judge: whether the acceptance criteria in `BRIEF.md` are *good*. Read them.

**If this change deploys to AWS** (`deploy.infra: true`), also confirm:

- `deploy.environment` names an environment, and it is one you meant.
- Deploy credentials are present in this session. The control repo is normally the least
  privileged session in the system; this is the one lane where it is not — see
  `docs/adr/0004`.
- `make -C infra -n plan deploy outputs` all succeed. The loop refuses to dispatch
  otherwise, loudly, rather than skipping the deploy.
- The attempt budget is **1** by default here, because each attempt is a real
  `terraform apply`. Raise it only deliberately.

## Steps

1. Run `./scripts/iterate.sh $1`.

   It dispatches every slice in parallel, brings all the repos up as one stack, runs the
   smoke suite through the single origin, and — when the change deploys — publishes the
   images, plans, applies, and re-runs the same suite against the deployed origin. On
   failure it sends the failing assertion plus that service's container logs back to the
   repo named in the step's `owner`.

   `--max-attempts N` for more passes, `--no-repair` for one pass and a report,
   `--verify-only` to skip dispatch, `--no-infra` to stay local, `--plan-only` to see what
   an apply would do without doing it.

2. Read `changes/$1/runs/<ts>/report.md` and report to the human:
   - the outcome, and the assertion count beside it. A report cannot say `verified` above
     an empty count, so if the count looks thin, say so.
   - per repo: branch, PR link, and the status the session ended with (in
     `attempt-*/fanout.json` — `pr` and `status` are fields, not prose to be parsed)
   - the smoke result: which assertions passed, and which failed with what. When the change
     deployed, say which pass each failure came from — local or remote.

3. Route on the outcome:

   - **`verified`** — deployed and asserted, locally and remotely if it deploys. Nothing to
     fix.
   - **`verified-local`** — passed locally, and **no remote environment was touched**
     (`--no-infra` or `--plan-only`). Do not present this as shippable for a change that is
     supposed to deploy.
   - **`contract-gap`** — do NOT patch around it. A slice reported it cannot be built
     against the frozen contract, and named the gap. Surface it as a new contract-freeze
     pass (see the `freeze-contract` skill), re-freeze, update `freeze_sha`, re-run.
   - **`failed`** — read the briefs at `runs/<ts>/attempt-*/failure-*.md`; that is exactly
     what the agents were given. Decide whether the implementation is wrong (re-run with
     more attempts) or the assertion is wrong (fix it here, in the control repo — never in a
     product repo).
   - **`blocked`** — a precondition was unmet, so nothing was dispatched and nothing was
     deployed. There is no deploy evidence to read. Fix what the dispatcher named.
   - **`unattributable`** — the failure could not be pinned on a slice. Check
     `verify.json`'s `fault` field: `harness` means it is this repo's bug and there is
     nothing for a product-repo agent to do.

4. Do not merge anything. Merging is a human decision, in dependency order.

## After a human merges

- `./scripts/lock.sh` and commit `repos.lock`.
- Promote the smoke steps worth keeping forever from `changes/$1/smoke.yaml` into
  `smoke/baseline.yaml`, so the next change cannot silently break this one. Carry their
  tags across — a step tagged `local` is tagged that way for a reason.

ARGUMENTS: $1
