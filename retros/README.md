# Retrospectives

One file per lane that had something to say. Written by the `harness-retro` agent, which
every lane invokes as its last phase, and landed by the pull request that carries it —
nothing here is committed straight to `main`.

This directory is the harness's memory. It exists for one mechanism: a retrospective reads
the ones before it, so friction that was noticed and tolerated once becomes proposable the
second time it appears, and a proposal the reviewer closed does not come back every week.

A lane that produced a clean audit and no finding leaves no file. Silence here means
nothing was wrong, not that nobody looked — the report the lane printed says which.

## Shape

Filename `<UTC timestamp>-<lane>[-<change>].md`, e.g. `20260826T140355Z-ship-0003-chats.md`.

```markdown
---
lane: ship | ship-correct | ship-iterate | realign
change: NNNN-slug | none
run: changes/NNNN-slug/runs/<ts> | none
date: YYYY-MM-DD
verdict: coherent | coherent-with-warnings | incoherent
findings: <n> proposed, <n> recorded, <n> rejected
pr: <url> | none
---

## State audit
<one line per item from the agent's §2, each with its evidence or `not verified`>

## Findings
### <one-line defect>
- **Evidence:** <path, line, assertion name>
- **Judgement:** <against the bar in §4>
- **Disposition:** proposed | recorded | rejected — <why>

## Recorded, not proposed
- **R1 — <one-line defect>.** <evidence, and why it did not clear the bar>

## Rejected
- **<one line>** <why>

## Not verified
<what could not be checked from here, and what it would take>
```

`run:` names the run directory even though `changes/*/runs/` is not committed — the
retrospective is written while it still exists, and the path is what makes a later reader
able to say which evidence was in front of it.

## What the next retrospective actually reads

**The leads, not the bodies.** `retro-evidence.sh` § 7 emits a ledger — each file's
frontmatter and every one of its finding leads — and that is what the next retrospective
is given. It opens a whole file only to cite one specific finding.

A lead is a `###` heading, or the bolded opening of a top-level bullet: both forms above
are read by `scripts/retro_findings.py`, which the ledger prints from and `check-docs.py`
[retro-ledger] holds every file here to. A finding written any other way is invisible to
the next lane — which is what happened to 24 recorded findings across three files before
the gate existed.

So: **write each lead so it stands alone.** `### F1 — the failure dump has covered six of
nine services since 0004` is a lead the next lane can act on; `### F1 — a logging gap` is
one it has to open the file to understand, which is the cost this directory is otherwise
paying on every lane forever.

The body below the heading is for the human reading the pull request. Nothing loads it by
default, and nothing should: this is history, and one lane's worth of it is longer than
the run it graded.
