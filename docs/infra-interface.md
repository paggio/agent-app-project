# What the control repo requires of `infra/`

The control repo never learns Terraform or Helm. It knows these targets, invoked as
**`infra/bin/infra <target> [VAR=value ...]`** — through `scripts/infra.sh` — and this file
is the interface — a contract like `contracts/infra-outputs.yaml`, not a procedure. Read it
before writing the infra slice of a deploying change, or before proposing a redesign of the
deploy path. The reasoning and the accepted costs are in `docs/adr/0004` and
`docs/adr/0018`. The caller is `scripts/verify-remote.sh`, in CI; the only local callers
are `make dev-bootstrap` and `make dev-down`, through `scripts/with-aws.sh`.

| Target | Args | stdout | Exit |
| --- | --- | --- | --- |
| `plan` | `ENV`, `BACKEND_IMAGE`, `FRONTEND_IMAGE`, `PROXY_IMAGE` | the plan, and where it was saved | 0 additive · **3 contains a destroy or replace** · 1 failed · 2 usage |
| `deploy` | the same | apply and rollout log | 0 **applied and the new revision is serving** · 1 failed · 2 usage |
| `outputs` | `ENV` | **a flat JSON object, and nothing else** | 0 · 1 no state for `ENV` · 2 usage |
| `registries` | `ENV` | one `<image>_image_repository` per image (`.gitmodules` `images`) from the **bootstrap** state, as one flat JSON object | 0 · 1 not bootstrapped · 2 usage |
| `bootstrap` | `ENV` | log, ending with the deployer role ARN | one-time, local; state backend, registries, the deployer role. Survives `destroy`. |
| `destroy` | `ENV`, `CONFIRM=<env>` | log | 0 everything outside bootstrap is gone · never called by a loop |
| `leftovers` | `ENV` | one line per billable resource still tagged for `ENV` | 0 none · 1 some remain |
| `fmt` `validate` `lint` | — | — | the infra repo's own gates |

`ENV` is `dev` — the only environment `scripts/manifest.py` allows.

**The exit codes below are `bin/infra`'s, not make's.** GNU make exits 2 for any failing
recipe, so through `make -C infra` a destroying plan and "no state" both arrive as 2
(infra's `docs/adr/0003`). The Make targets are for humans; every machine caller here uses
`bin/infra`, and `check-docs.py [infra-invocation]` holds it.

The requirements, each because something breaks otherwise:

- **`outputs` prints JSON on stdout and nothing else.** A single `@echo "fetching..."` in
  the recipe corrupts it into the parse-failure path. Logging goes to stderr.
- **`outputs` exits non-zero rather than printing `{}`** when the environment has no state.
  An empty object is the input that produces a vacuous pass.
- **`ENV` has no default.** Unset means exit 2 listing the valid environments. A default
  `ENV` is how prod gets applied by a typo.
- **A failed `deploy` leaves its evidence before it rolls back**: `describe`, `logs
  --previous` and events for every unready pod, into `$DEPLOY_EVIDENCE_DIR`. A rollback
  deletes the pods, and with them the only record of why they died.
- **`deploy` does not return 0 until the new revision is serving,** or the remote pass races
  the rollout and the failure lands on whichever step ran first — `terraform apply`, then
  `helm upgrade --install --atomic --wait`. This is the remote analogue of
  `stack.sh up --wait`.
- **`destroy` leaves nothing that bills, and `leftovers` proves it.** Controller-created
  resources — load balancers, volumes, ENIs — are what a plain `terraform destroy` misses;
  `destroy` removes the release first, and `leftovers` asks the tagging API rather than the
  state, because the state is exactly what does not know about them.
- **Every resource carries `Project`, `Environment`, `ManagedBy`, `Repository`** through
  provider `default_tags`, so `leftovers` and the Resource Group see all of it.

**Exit 3 from `plan` is the guardrail this design leans on hardest.** It stands between "a
repair agent rewrote a module on attempt 2" and "the database was replaced". The control
repo reads an exit code rather than parsing `terraform show -json`, so Terraform-schema
knowledge stays in the repo that owns it; the cost is that the code cannot say *which*
resource, and the saved plan is what answers that.

## Outputs are a contract

Adding one to `contracts/infra-outputs.yaml` is a freeze pass: one commit, `contracts/`
alone, recorded as `freeze_sha`. So a change needing a new output is really two changes —
freeze the promise, then implement it.

`kind` decides whether an output reaches the smoke environment. Only `kind: value` is
exported, as `INFRA_<NAME>`. A `secret_ref` promises a *name*; if you want to export one,
what you actually want is for the deployed app to read it, which is the app's environment
and not smoke's. Before any apply, `verify-remote.sh` runs `infra-outputs.py --contract-only`, so a
contract that still promises nothing fails in preflight rather than after spending an apply.

## A new image

An image is declared once, as `images` on its repo in `.gitmodules` (`scripts/repos.py`).
`publish.sh` then needs `<image>_image_repository` from `registries`, and the deploy set
reads `deployed_<image>_image` from `outputs` — both in `contracts/infra-outputs.yaml`,
so a repo born with an image (`docs/adr/0020`) brings an infra slice that adds them.

## The first infra change

Its interface criteria are testable without an AWS account — `make -n plan|deploy|outputs`
succeed; `outputs` with no state exits non-zero; `plan` with no `ENV` exits 2; `plan` exits
3 for a destroying fixture — and belong in the infra repo's own tests. What only a deploy
can show is `/dev-push`'s, once `make dev-bootstrap` has run.

## Safety, because the suite mutates a shared environment

- Every identity a step creates is namespaced with `${SMOKE_RUN_ID}` and confined to
  `smoke-*@auth.test`. `.test` is RFC 2606 reserved, so a smoke run can never collide with a
  real user, and preflight refuses a suite containing any other address shape.
- The remote suite never registers with a committed placeholder. `SMOKE_PASSWORD` is
  generated per run; `SIGNUP_CODE` is read from `signup_code_secret_ref` after the deploy —
  a Secrets Manager ARN or an SSM parameter name the deployer role can read. Otherwise the
  register steps 403 and route a nonexistent bug to the backend, or the placeholder really
  is deployed and registration is open with a committed code.
- `/dev-eval` (`scripts/eval-remote.sh`) reads `phoenix_base_url`, and the bearer key from
  `phoenix_api_key_secret_ref` — a plain string, or a JSON secret with one string value —
  with the deployer role, and `call_queue_url`, when present, as `EVAL_CALL_QUEUE_URL`. It
  registers `eval-<run>@auth.test` per run.
- One run per environment: `concurrency: env-dev` within a repo, the state lock across
  repos, and a re-read of what `dev` runs after the suite. Terraform's lock alone stops
  state corruption, not two runs interleaving against one origin.
- No loop calls `destroy`. A half-applied environment is evidence.
- `prod` is absent from the allowlist in `scripts/manifest.py`. What actually stops a
  production deploy is credentials — these are guardrails against absent-mindedness, not a
  security boundary, and must not be read as one.

## Routing

`contracts/README.md` § "The `/api/` prefix is an asserted invariant" before writing any ALB
or CloudFront routing. The short version: the edge must STRIP the prefix, an ALB path rule
does not do that without an explicit rewrite, and because the frontend answers any unmatched
path with the app shell and a 200, getting it wrong produces `200 text/html` for API calls
rather than a loud 404. Steps in `smoke/baseline.yaml` hold it, and `infra-crosscheck.py`
requires infra, the contract and smoke to name the same prefix.
