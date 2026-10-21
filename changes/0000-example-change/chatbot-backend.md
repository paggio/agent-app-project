# 0000 — chatbot-backend slice

<!-- TEMPLATE-ONLY: Read by an agent working alone inside the chatbot-backend repo. It
     can see BRIEF.md and contracts/ (passed in with --add-dir) and nothing else from
     the control repo. Say what changes here; say nothing about the other repos'
     internals. -->

## What to build

- <change>
- <change>

## Contract entries this depends on

- `contracts/<file>` → <entry>

The contracts are FROZEN. If this slice appears to require a contract change, STOP
and report it rather than working around it.

## Verification

- [ ] <test or check that proves it works>
- [ ] the repo's own gates pass (`.claude/hooks/gate.sh`)

## Smoke — what this slice is actually judged on

After every slice lands, the control repo deploys all of them together and runs
`smoke.yaml` against one origin. The steps whose `owner:` is `chatbot-backend` are yours:

- [ ] `<step name>` — <what it asserts>

These run against your code through a reverse proxy, not against your test doubles, and
a failure comes back to this repo with the request, the response and your container log
attached. The assertions belong to the control repo: fix the cause, never the assertion.

## Documentation

Verify fails this slice if its code changes and none of its docs (`README.md`, `CLAUDE.md`,
`docs/`) do:

- `<doc path>` — <what it must now say>

## Notes

- <migration ordering, feature flag, backwards-compatibility constraint>
