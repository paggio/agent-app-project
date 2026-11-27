---
lane: ship-iterate
change: 0010-agent-flow-ui
run: changes/0010-agent-flow-ui/runs/20261127T155856Z
date: 2026-11-27
verdict: coherent-with-warnings
findings: 0 proposed, 6 recorded, 3 rejected
pr: https://github.com/paggio/agent-app-project/pull/54
---

## State audit

- **Control repo** — `feat/0010-agent-flow-ui` at `c249d2c` = upstream. Dirty: `.gitignore` (`tmp/`, personal) and three submodule gitlinks (feat heads, uncommitted on purpose). `3e749c6` touches `contracts/` alone; `freeze_sha` in `change.yaml:8`; but its short form is copied into the change's STATUS and brief too (R5).
- **Submodules** — chatbot-backend `36bed16`, frontend `cda4735`, infra `e41593c` on `feat/0010-agent-flow-ui`, off `repos.lock` as a ship lane leaves them; the other three on `main` = lock.
- **Contract against served** — harvested in-run (`attempt-1/harvest.log`): no drift; the six known never-observed 422s.
- **Assertions** — 134/0 local, 23 from the change suite (6 new for the amendment); remote 105/0, 23 from the change suite.
- **Cloud** — `dev-push-46033089871/run/verify-remote.json` `verified`; deploy set = the three PR heads as they stand now.
- **Pull requests** — chatbot-backend #12, frontend #11, infra #6 fetched now: OPEN, heads = deploy set, checks SUCCESS. Control #53 open.
- **Gates** — `manifest --validate` 0, `test-hooks` 0, `check-docs` 1 on the change branch (chatbot-eval vendored `openapi.yaml` 1.8.0 vs 1.9.0). On `origin/main` chatbot-eval matches.

## Findings

None proposed.

## Recorded, not proposed

- **R1 — a contract promise is asserted only on turns where it cannot fail: "one `answer` step last".** `contracts/README.md:358-361`. The change suite checks `coordinate…answer` only on small-talk turns (`smoke.yaml:163,171,180`), which carry no tool steps; the one turn with tools (`a-call-question-steps-through-search-calls`, `:191`) checks `search_calls` is present, not that `answer` follows it. Lane testimony: the local UI showed "Writing the answer" before the metrics agent's `describe_metric`/`query_metrics`. A product defect plus a criterion gap — `/ship-correct` territory, not a harness diff.
- **R2 — a non-slice consumer (chatbot-eval) left on a stale `openapi.yaml`; `check-docs.py` exits 1 on the change branch; second occurrence** (0010 ship R6). The re-vendor route is `realign.md`'s; no harness change would catch anything — downgrading it only quiets an obligation that is real. Decision for the user: re-vendor chatbot-eval at realign (current route) or as a slice whenever the contract bumps.
- **R3 — an ask with no lane: control-repo README screenshots.** Done by hand after green, unasserted, named in STATUS. "README" was ambiguous (control vs frontend). First occurrence.
- **R4 — the lane cannot act as a user on dev.** Registration on dev needs a CI-secret signup code and `DEV_ACCOUNT_*` is local-only, so the screenshots came from the local stack via a throwaway Playwright script. First occurrence.
- **R5 — the freeze commit still gets second homes, and `check-docs.py` [freeze-sha-home] cannot see them.** `STATUS.md:6` ("`3e749c6` … supersedes `76ac577`"), `STATUS.md:50`, and the brief's line 87 ("re-frozen at `3e749c6`"), against CLAUDE.md "nowhere else". The check is a phrase regex: the brief's second shape needs "as of|sha|commit" within 40 chars of "frozen", so "re-frozen at" passes; STATUS.md is never scanned for the hex. The template fix (`30243ea`) is untested on a fresh scaffold — this STATUS.md predates it. No harm this run (copies updated on re-freeze), and a literal hex grep over `changes/*/` would fail six merged changes under `make check` (`Makefile:252`). Propose if a fresh scaffold repeats it.
- **R6 — `.gitignore` `tmp/` still rides uncommitted across branches; fourth occurrence** (0009 ship-iterate R3, 0009 realign R5, 0010 ship R8). Personal, not the harness's.

## Rejected

- **PyYAML absent from system python.** Third mention; rejected twice before (0008 ship-iterate, 0010 ship). Environment.
- **Session-panel badge wrapping.** Cosmetic, product.
- **The six never-observed 422s, the stack left up.** Known, accepted.

## Not verified

- The answer-ordering defect itself: testimony from a screenshot only; no request reproduced here.
- Live dev state: no AWS read (ADR 0018).
