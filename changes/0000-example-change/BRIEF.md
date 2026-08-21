# 0000 — <change title>

<!-- TEMPLATE-ONLY: Run ./scripts/new-change.sh to scaffold a copy of this
     directory for each cross-repo feature. Written by hand in a planning session, before any
     implementation. -->

## Why

<The problem, in terms of who is affected and how much. Not the solution.>

## Acceptance criteria (these are the oracle)

<!-- Checkable statements, not aspirations. Each must map to a test, a metric, or a
     manual verification step someone can perform. If it cannot fail, it is not a
     criterion. -->

- [ ] <criterion>
- [ ] <criterion>
- [ ] <criterion>

## Out of scope

<Named explicitly, so an agent does not helpfully add it.>

## Contract changes

`contracts/<file>`: <what changes>. Frozen as of <commit sha>.

<!-- If this line has no SHA, the change is not ready to fan out. -->

## Deployment

<!-- The machine-readable version of this lives in change.yaml, which is what the scripts
     actually read. Written here too because the infra decision is a judgement a human
     makes, and a bare `infra: true` in a manifest records the answer without the reason. -->

- Local stack and smoke: always. `./scripts/iterate.sh 0000-<slug>` brings up all repos
  together and runs `smoke.yaml` against the single origin.
- Infra deploy: <no | yes, because ...>. Set `deploy.infra` in `change.yaml` to match.

## Slices

- `chatbot-backend.md`
- `frontend.md`
- `infra.md`
