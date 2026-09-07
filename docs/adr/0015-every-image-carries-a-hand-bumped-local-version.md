# 0015 — Every image in the joined stack carries a hand-bumped local version

**Status:** accepted
**Date:** 2026-09-07
**Relation to 0013:** extends it. 0013 made the eval record what it measured by *reading*
the backend rather than being told. This says what the thing it reads has to be worth
reading.

## Context

`changes/0006-chatbot-eval` added `GET /v1/version`, whose whole purpose is to let a run
record which build produced its scores, and `contracts/README.md` is emphatic about the
rule that makes the field trustworthy: `image_tag` is supplied from outside the image, and
an application that derives its own build identity is not reporting one.

That rule held. The value did not. `stack/dev.env` set `BACKEND_IMAGE_TAG=dev`, so every
experiment in Phoenix recorded `image_tag: "dev"` — the same string for every build, in the
one field meant to distinguish builds. The rule was honoured and the field was useless, which
is a worse state than an obviously missing one because it reads as working.

The eval image was worse still: it had no version anywhere. Its metadata recorded the
fixture hash, the question hash, the judge and the judge's prompt version — every input to a
score except the code that computed it. Two runs over an identical corpus with a rewritten
groundedness evaluator were indistinguishable.

`git_sha` was already available and is not the answer. It answers "which commit", which is a
different question from "which build am I comparing against last week's": it changes on every
commit including ones that cannot affect a score, and nobody chooses it. A comparison needs an
identifier a person cut on purpose.

## Decision

**Every image in the joined stack carries a hand-bumped local version, `local-<major>.<minor>.<patch>`,
declared in `stack/dev.env`, and a change that touches a product repo must bump that repo's tag.**

1. **`stack/dev.env` is the home**, not the product repos. The tag belongs to the joined
   stack, and the decisive argument is mechanical rather than aesthetic: a session inside
   `chatbot-backend` cannot edit a control-repo file, so a rule in that repo's `CLAUDE.md`
   telling it to bump would be unactionable — the exact contradiction `docs/adr/0008` was
   written to dissolve for `contracts/`.

2. **A gate, not prose.** `scripts/check-docs.py` § `[image-tags]` enforces two things: every
   `*_IMAGE_TAG` matches the shape, and a change **in flight** — one whose directory does not
   exist on `origin/main` — whose `slices:` names a mapped repo has a tag differing from its
   value on `origin/main`. "In flight" is a git question rather than a judgement, and a merged
   change is left alone because its tag is already history.

3. **The shape is asserted at the seam too.** `smoke.yaml` matches `image_tag` against
   `local-<n>.<n>.<n>`, so a tag carrying no version fails when the change ships rather than
   when somebody first tries to tell two experiments apart.

4. **The eval records its own tag as a comparability factor**, in `experiment_metadata`
   beside `fixture_hash` — and it never invents it. Null when nothing supplied one, the same
   rule `image_tag` has, for the same reason.

5. **Not every image is gated yet.** The map is `chatbot-backend → BACKEND_IMAGE_TAG` and
   `chatbot-eval → EVAL_IMAGE_TAG`. `frontend` ships an image and is deliberately absent:
   nothing reads a frontend build identity today, and a gate over a value nobody consumes is
   the speculative check `check-docs.py`'s own doctrine rejects. `infra` ships no image. A
   repo absent from the map is not gated, and adding one is a line in the map.

## Consequences

**Makes easy.** Two experiments a month apart are comparable, or provably not, by string
equality on fields a person chose. A score regression can be attributed to a build, an
evaluator change or a fixture change, because all three are recorded separately and all three
now move only when somebody moves them.

**Accepted costs.**

- **A human has to remember, and the gate is what makes forgetting cheap rather than
  impossible.** It fires at `make check` and in CI, which is late enough to be annoying and
  early enough to be free. It cannot tell a bump that means something from one that was made
  to satisfy it — nothing can, and a version somebody incremented without thinking is still
  a version that distinguishes two builds.
- **The number carries no meaning.** `local-0.0.2` is not "a patch release"; it is the second
  local build. Semantic versioning is not being claimed and should not be read in. The
  `local-` prefix exists to make that obvious and to keep these tags from being mistaken for
  anything publishable.
- **`origin/main` has to be reachable for half the gate.** A fresh clone or a shallow CI
  checkout has no such ref, and the bump check then **skips** rather than failing — a gate
  that cannot see the baseline must not invent one. The shape check still runs. So the bump
  half is enforced where a person works and not in every environment, which is a real
  weakening and is why the seam assertion in §3 exists independently of it.
- **A change touching a product repo in a way that cannot affect its image** — a README, a
  comment — still has to bump. Over-broad on purpose: the alternative is judging which diffs
  are behavioural, and a wrong judgement there produces exactly the silent-sameness this ADR
  exists to remove.
- **Two more variables in `stack/dev.env`**, and `check-docs.py [env-layers]` now has two
  more names to keep out of `chatbot-backend/.env`. Neither is a secret and neither is
  plausibly a submodule's to set.

## Alternatives considered

- **Derive the tag from the git SHA.** Rejected: `git_sha` already reports it and answers a
  different question. A SHA also moves on every commit, so it cannot express "the build I am
  comparing against", which is the only thing this field is for.
- **Use the application's own version** (`pyproject.toml`, already reported as `version`).
  Rejected: it is a release version, moves for different reasons and at a different rate, and
  making one string serve both purposes means neither can change without lying about the
  other.
- **Let each product repo own its tag and have the control repo read it.** The instinct is
  right — the repo that changes should own its version — and it is rejected on the mechanism
  in §1: the value has to reach `docker compose`, the control session may not write in a
  submodule, and `dev-env.sh` reading a fourth file is the generalisation `docs/adr/0013`
  explicitly declined.
- **Generate the tag automatically from the submodule pointer at `up` time.** No bump to
  forget, and rejected because it recreates the SHA's problem with extra machinery: the tag
  would change whenever the pointer moved, including for changes nobody meant to compare.
- **Leave `dev` and rely on `git_sha`.** The status quo. It is what produced a month of
  experiments all claiming to be the same build, and `git_sha` was null in every one of them
  because nothing supplied it either.
