# 0007 — the dev environment

## Why

Everything so far has only ever run on a laptop. This change stands up `dev` in AWS:
EKS behind CloudFront, deployed by CI from the pull request (`docs/adr/0018`), so a
change can be `verified` — both suites green against a real deployment — before it
merges.

## Acceptance criteria

1. `make -C infra bootstrap ENV=dev` creates the state bucket, the ECR repositories, the
   deployer role, the budget and the cost export, and a second run changes nothing.
2. `/dev-push` on this change's control PR deploys infra, frontend and backend at the
   PR heads and reports `verified`: every baseline step not tagged `local` plus every step
   below holds through `app_base_url`.
3. The origin is HTTPS with HSTS; the session cookie is `Secure`; a browser-shaped POST
   (with `Origin`) is accepted through CloudFront.
4. The deployed backend reports the image tag it was deployed with and `chat_model:
   bedrock`, and a chat turn gets a real model reply.
5. The proxy is an image built by the frontend repo; its security headers are on the
   shell and on API responses, locally and through CloudFront.
6. `make dev-down` leaves `make -C infra leftovers ENV=dev` reporting nothing billable,
   and `/dev-push` brings the environment back.
7. Every resource carries `Project=agentapp`, `Environment=dev`, `ManagedBy=terraform`,
   `Repository`.
8. `outputs`, `plan`, `destroy` honour `docs/infra-interface.md`: no `ENV` is exit 2,
   no state is non-zero, a destroying plan is exit 3, `destroy` refuses without `CONFIRM`.

9. The Phoenix UI of `dev` is served over HTTPS at `phoenix_base_url`, its own CloudFront
   origin, with authentication on: the login page loads, an unauthenticated API request is
   refused with 401, and the deployed backend's traces still land.
10. `/dev-eval` commented on a control PR runs `chatbot-eval` against `dev` and files the
    experiment in `dev`'s Phoenix; the PR gets the verdict and the experiment link.

Criteria 1, 6, 8 and 10 are processes, not requests; they are proved by running them, and
`STATUS.md` records the run. Criterion 7 is proved by `leftovers` finding the resources
while up and none after `down`.

## Out of scope

- **prod.** `release-prod.yml` refuses and deploys nothing (ADR 0018).
- **A custom domain.** CloudFront's default certificate; no Route 53 zone exists.
- **The eval as a Kubernetes Job**, and `/dev-push` or `/dev-eval` from `chatbot-eval`
  PRs. `/dev-eval` runs the eval on the CI runner against the deployed origins; nothing
  deploys the eval.
- **Phoenix users beyond the admin.** One admin, password in Secrets Manager; the same
  secret is the bearer key the backend and the eval write with. Per-writer keys are a
  later change.
- **The backend repo's `/dev-push` caller.** Nothing in the backend moves here, so it is
  a single-repo PR in that repo, not a slice of this change.
- **Managed OpenSearch, ElastiCache.** OpenSearch runs in-cluster on EBS; redis is unused.
- **A WAF.** Revisit when anything but smoke identities uses `dev`.
- **Tag-filtered cost views.** The account cannot activate cost-allocation tags; cost is
  read from the CUR 2.0 export by resource id.

## Contract

`contracts/infra-outputs.yaml`, additive: `proxy_image_repository`,
`deployed_proxy_image`, `cluster_name`, `aws_region` (all `kind: value`); the examples
move from `staging` to `dev`, and so does `contracts/README.md`'s prose.
Amended (`/ship-iterate`, 2026-09-24): `phoenix_base_url` (`kind: value`) and
`phoenix_api_key_secret_ref` (`kind: secret_ref`), additive.
`contracts/openapi.yaml` does not move.
