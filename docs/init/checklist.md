# Initialization checklist

Copy per initialization and tick through. Order matters — see `README.md` for the
reasoning behind each step.

## Decisions

- [ ] Repo names agreed
- [ ] Submodule paths match their remote names (they are hard to rename later)
- [ ] Visibility set (private unless there is a reason)
- [ ] Default branch identical across all four repos

## Repositories

- [ ] Four repos created
- [ ] Each product repo pushed with its own initial commit
- [ ] Control repo pushed
- [ ] Three submodules attached, `repos.lock` generated and committed

## Per product repo

- [ ] `CLAUDE.md` present, under 60 lines, no placeholder left that would mislead
- [ ] `.claude/settings.json` complete and self-contained (it does not inherit)
- [ ] `.claude/hooks/gate.sh` and `format.sh` present and executable (`chmod +x`)
- [ ] `docs/architecture.md` skeleton present
- [ ] `contracts/` vendored and denied for editing
- [ ] `.github/workflows/ci.yml` present

## Control repo

- [ ] `contracts/` present, owned exclusively here
- [ ] `changes/` template present, `new-change.sh` produces a usable directory
- [ ] `scripts/*.sh` executable
- [ ] Submodule `deny` rules in `.claude/settings.json`
- [ ] `no-subrepo-edits.sh` blocks a shell write into a submodule — **tested**
- [ ] `docs/adr/0001-*.md` records the structural decision and its accepted costs

## Gates are real (do not skip)

Per product repo, once the toolchain exists:

- [ ] Toolchain installed, one passing test
- [ ] Gate lines uncommented in `gate.sh`
- [ ] **Break a test on purpose; confirm the Stop hook blocks the turn.** Restore it.
- [ ] CI jobs filled in and set as required status checks
- [ ] Secret scanning enabled

## End-to-end

- [ ] Self-sufficiency: clone one product repo alone into a fresh directory, run a
      session, ask for a small change — nothing essential is missing
- [ ] One deliberately small cross-repo change run end to end: plan → freeze →
      `fanout.sh` → three green PRs → merge in dependency order → `lock.sh`
- [ ] Submodule branching survived it (no work stranded on a detached HEAD)

## Housekeeping

- [ ] Code-intelligence plugin installed per language, so the agent resolves symbols
      via the language server instead of scanning files
- [ ] Agent-opened PRs labelled with tool and session identifier, for traceability
- [ ] Review date set: after ~10 changes, or the next major model release
