# __NAME__

__PURPOSE__

Standalone repo. Everything needed to work here is in this repo; do not assume a session
here can see the control repo or another service's source.

## Commands

`make help` lists everything. `make check` is the gate — lint, typecheck, tests — and MUST
pass before work is considered done. Toolchain: not chosen yet; the first change that
implements this repo chooses it, fills `make check`, and replaces this line.

## Git

- Never edit files while HEAD is on `main`: `git switch -c <type>/<slug>` first.
- Commit in logical units; each commit leaves the gates passing.

## Code

- Prefer concrete, simple implementations over abstractions. Comments sparse and concise.
- `contracts/` is vendored from the control repo. NEVER edit it here. If an interface
  needs to change, STOP and say so — that is a control-repo change.
- Reach other services only through what `contracts/` declares. Never import another
  service's code or read its datastore.

## Docs

- Update `docs/` in the same commit as any behaviour change. Concise, always current.
  Gated: `src/` changed without `docs/` blocks the turn.
- A decision a future reader would ask "why?" about gets an ADR in `docs/adr/`.

## Exit codes

0 pass · 1 the thing under test failed · 2 this process refused (precondition unmet).

## Source of truth

- Architecture and module boundaries: `docs/architecture.md`
- Why things are the way they are: `docs/adr/` — read before proposing a redesign
