---
description: Fan out a planned change to the product repos and report the resulting PRs.
argument-hint: <change-dir-name, e.g. 0042-csv-export>
---

Ship the change `$1`.

<!-- EXAMPLE / TEMPLATE. Adjust the preconditions to match what this project actually
     enforces once the gates are real. -->

## Preconditions — check all of these first, and STOP if any fails

1. `changes/$1/BRIEF.md` exists and its acceptance criteria are filled in.
2. `changes/$1/BRIEF.md` § "Contract changes" names a freeze SHA, and that commit is
   already on `main` here.
3. The working tree is clean; `contracts/` has no uncommitted edits.

## Steps

1. Run `./scripts/fanout.sh $1`.
2. When it returns, report per repo: branch, PR link, and the OK / FAIL line the
   session ended with.
3. For any FAIL that mentions a contract gap: do NOT patch around it. Surface it as a
   new contract-freeze pass.
4. Do not merge anything. Merging is a human decision, in dependency order.
