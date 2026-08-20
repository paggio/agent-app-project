---
name: deploy-to-aws
description: A change that must reach a real AWS environment — provisioning, Terraform, a target environment, or asserting against a deployed origin. Use when planning or shipping a change with deploy.infra true.
---

The deploy lane is the cross-repo lane plus four deltas. Everything in
`plan-cross-repo-change` still applies; this is what changes.

Read `docs/adr/0004` before proposing a redesign of any of it. The costs there are named on
purpose.

## The four deltas

1. **`deploy.infra: true`, and an `infra` slice.** `manifest.py --validate` rejects one
   without the other.
2. **`deploy.environment` names the target.** No default — a default `ENV` is how prod gets
   applied by a typo. The allowlist lives in `scripts/manifest.py`; `prod` is not in it, and
   adding it is a reviewed commit here rather than a change author's decision.
3. **The suite is asserted twice**, local then deployed, from one file. `local` and `remote`
   are the only tags and **untagged runs in both**. Tag a step only to opt it out.
4. **An attempt costs a real apply**, so the budget is 1 by default.

## What infra must satisfy

The control repo never learns Terraform. It knows six Make targets:

| Target | Args | stdout | Exit |
| --- | --- | --- | --- |
| `plan` | `ENV`, `BACKEND_IMAGE`, `FRONTEND_IMAGE` | the plan, and where it was saved | 0 additive · **3 contains a destroy or replace** · 1 failed · 2 usage |
| `deploy` | the same | apply log | 0 **applied and the new revision is serving** · 1 failed · 2 usage |
| `outputs` | `ENV` | **a flat JSON object, and nothing else** | 0 · 1 no state for ENV · 2 usage |
| `bootstrap` | `ENV` | log | one-time; creates state backend and registries. Never called by the loop. |
| `destroy` | `ENV`, `CONFIRM=<env>` | log | never called by the loop, under any flag |
| `fmt` `validate` `lint` | — | — | for the infra repo's own gates |

Four requirements that each exist because something breaks otherwise:

- **`outputs` prints JSON on stdout and nothing else.** A single `@echo "fetching..."` in
  the recipe corrupts it into the parse-failure path. Logging goes to stderr.
- **`outputs` exits non-zero rather than printing `{}`** when the environment has no state.
  An empty object is the input that produces a vacuous pass.
- **`ENV` has no default.** Unset means exit 2 listing the valid environments.
- **`deploy` does not return 0 until the new revision is serving,** or the remote pass races
  the rollout and the failure is attributed to whichever step ran first. This is the remote
  analogue of `stack.sh up --wait`.

Exit 3 from `plan` is the guardrail this design leans on hardest. It is what stands between
"a repair agent rewrote a module on attempt 2" and "the database was replaced". The control
repo reads an exit code rather than parsing `terraform show -json`, so Terraform-schema
knowledge stays in the repo that owns it; the cost is that the code cannot say *which*
resource, and the saved plan is what answers that.

## Promoting an output is a contract pass

`contracts/infra-outputs.yaml` is a contract like `openapi.yaml`. Adding an output is a
`freeze-contract` pass: one commit, `contracts/` alone, recorded as `freeze_sha`. So a
change that needs a new output is really two changes — freeze the promise, then implement
it — and never both in one session.

`kind` decides whether the output reaches the smoke environment. Only `kind: value` is
exported, as `INFRA_<NAME>`. A `secret_ref` promises a *name*; if you find yourself wanting
to export one, the thing you actually want is for the deployed app to read it, which is the
app's environment and not smoke's.

Before any apply, `verify.sh` runs `infra-outputs.py --contract-only`, so a contract that
still promises nothing fails in preflight rather than after spending an apply to find out.

## What you cannot do from the control session

Write into the infra repo. The Make targets, the Terraform, and that repo's CI are a
**slice**: `changes/NNNN-*/infra.md`, dispatched by `fanout.sh`, or a session started inside
that repo.

The first such change is a special case worth stating: it should be `deploy.infra: **false**`
with an `infra` slice. You cannot smoke a deploy interface that does not exist yet, and its
acceptance criteria are the interface itself — all of which are testable without an AWS
account (`make -n plan|deploy|outputs` succeed; `outputs` with no state exits non-zero;
`plan` with no `ENV` exits 2; `plan` exits 3 for a destroying fixture).

## Safety, because the suite mutates a shared environment

- Every identity a step creates is namespaced with `${SMOKE_RUN_ID}` and confined to
  `smoke-*@auth.test`. `.test` is RFC 2606 reserved, so a smoke run can never collide with a
  real user, and preflight refuses a suite containing any other address shape.
- `verify.sh` refuses a remote pass when `SIGNUP_CODE` or `SMOKE_PASSWORD` came from the
  committed placeholder in `stack/dev.env`. Either the register steps would 403 and route a
  nonexistent bug to the backend, or the placeholder really is deployed and registration is
  open with a committed code.
- One run per environment, enforced by a lock held for the whole run. Terraform's state lock
  stops state corruption; it does not stop two runs interleaving their smoke data.
- The loop never calls `destroy`. A half-applied environment is evidence.

## The `/api` prefix

Read `contracts/README.md` § "The `/api` prefix is an asserted invariant" before writing the
ALB or CloudFront routing. The short version: the edge must STRIP the prefix, an ALB rule
does not do that without an explicit rewrite, and because the frontend answers any unmatched
path with the app shell and a 200, getting it wrong produces `200 text/html` for API calls
rather than a loud 404. Four steps in `smoke/baseline.yaml` hold it, and
`infra-crosscheck.py` requires infra, the contract and smoke to name the same prefix.
