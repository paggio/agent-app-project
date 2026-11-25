# Running and inspecting the WHOLE system by hand. Nothing here reimplements the scripts;
# it is a memorable surface over them.
#
# This is NOT the way work gets done. Cross-repo work is `/ship`; correcting or amending it
# before a merge is `/ship-correct` and `/ship-iterate`; coming back into line after a
# merge is `/realign`. Everything below is for looking at the running system, and for the
# gates those lanes call.
#
# The product repos each have their own `make up`, which brings up THAT repo in isolation.
# This one brings them up together, on one network, behind one origin — the only
# arrangement where the seams between them are real. See docs/adr/0002.

PROXY_PORT   ?= 8080
BASE         ?= http://localhost:$(PROXY_PORT)
BACKEND_BASE ?= http://localhost:8000
PHOENIX_BASE ?= http://localhost:6006
MSG          ?= hello
SVC          ?=
CHANGE       ?=
ONLY         ?=
VIA          ?=
ROLE_ARN     ?=

REPOS := $(shell ./scripts/repos.py names)
OWNER := $(shell ./scripts/repos.py owner)

.DEFAULT_GOAL := help
.PHONY: help up down restart ps logs rebuild config urls open health chat smoke verify iterate \
        e2e eval creds phoenix-durability repos lock prs check check-docs diagrams init clean \
        login push-gh-creds gh-setup dev-bootstrap dev-push dev-eval dev-up dev-down dev-status k9s dev-index

help: ## Show this list
	@echo "The full local stack — backend, datastores, frontend, proxy — on one origin."
	@echo
	@echo "  Cross-repo work is /ship, then /ship-correct or /ship-iterate before a"
	@echo "  merge, then /realign after one. These are the hand tools underneath them."
	@echo "  The remote pass is /dev-push, a PR comment — make dev-push starts it from here."
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Variables: PROXY_PORT=$(PROXY_PORT) BASE=$(BASE)"
	@echo "             CHANGE=<change-dir> ONLY=backend|frontend|infra for dev-push,"
	@echo "             VIA=ci for dev-down, ROLE_ARN=<arn> for gh-setup"
	@echo "             CHANGE=<change-dir> for verify/iterate, MSG=\"...\" for chat,"
	@echo "             SVC=<service> for logs/rebuild"

# ── the stack ────────────────────────────────────────────────────────────────────────

up: ## Build and start everything, blocking until every service is healthy
	@./scripts/stack.sh up
	@$(MAKE) --no-print-directory urls

down: ## Stop everything and drop the volumes
	@./scripts/stack.sh down

restart: down up ## Full cycle: down, then up

ps: ## What is running, and whether it is healthy
	@./scripts/stack.sh ps

logs: ## Follow logs; one service with SVC=backend
	@./scripts/stack.sh logs $(SVC)

rebuild: ## Rebuild one service without cycling the rest: make rebuild SVC=backend
	@test -n "$(SVC)" || { echo "usage: make rebuild SVC=backend|frontend|proxy"; exit 2; }
	@./scripts/stack.sh rebuild $(SVC)

config: ## Print the rendered compose config, with secrets redacted
	@./scripts/stack.sh config

# The diagnostic that would have answered "why did make eval JUDGE=bedrock fail" in one
# line. NAMES ONLY, never values: this prints which provider inputs resolved and from
# where, and a missing AWS_REGION is the failure it exists to make obvious.
creds: ## Say whether provider credentials are configured, and from where
	@./scripts/creds.sh

urls: ## Print the endpoints worth knowing
	@echo
	@echo "  app          $(BASE)/"
	@echo "  API          $(BASE)/api/          (proxied; the backend sees it without /api)"
	@echo "  backend      $(BACKEND_BASE)/      (direct, bypassing the proxy)"
	@echo "  phoenix      $(PHOENIX_BASE)/      (traces; not proxied, and not part of the API)"
	@echo
	@echo "  make eval     one eval run against this stack (one-shot container)"
	@echo
	@echo "  make health   check them      make chat MSG=\"hi\"   talk to the backend"
	@echo "  make smoke    run assertions  make logs SVC=backend  watch one service"
	@echo

open: ## Open the app in a browser
	@open "$(BASE)" 2>/dev/null || xdg-open "$(BASE)" 2>/dev/null \
		|| echo "open $(BASE) yourself"

# The two /api checks are the interesting ones: they only answer when the proxy and the
# backend are on the same network, which is what stack/compose.yml exists to arrange.
health: ## Curl every endpoint and print the status codes
	@printf '  %-40s ' "GET $(BASE)/"            ; curl -s -o /dev/null -w '%{http_code}\n' "$(BASE)/"            || echo unreachable
	@printf '  %-40s ' "GET $(BASE)/healthz"     ; curl -s -o /dev/null -w '%{http_code}\n' "$(BASE)/healthz"     || echo unreachable
	@printf '  %-40s ' "GET $(BASE)/api/healthz" ; curl -s -o /dev/null -w '%{http_code}\n' "$(BASE)/api/healthz" || echo unreachable
	@printf '  %-40s ' "GET $(BACKEND_BASE)/healthz" ; curl -s -o /dev/null -w '%{http_code}\n' "$(BACKEND_BASE)/healthz" || echo unreachable

chat: ## POST a message through the proxy: make chat MSG="hello"
	@printf '{"message":"%s"}' '$(MSG)' \
		| curl -sS -X POST '$(BASE)/api/v1/chat' \
			-H 'content-type: application/json' --data-binary @-
	@echo

# ── verification ─────────────────────────────────────────────────────────────────────

# dev-env.sh supplies the variables, so this no longer hand-exports one. That was the
# pattern stack/dev.env exists to eliminate, and it was in the baseline suite, which every
# change runs. `remote` steps are excluded because there is no deployed origin here.
#
# SMOKE_RUN_ID is the run NONCE the suites namespace identities with — verify.sh passes a
# timestamp. This passed the constant `make`, so a second `make smoke` against a stack that
# was not torn down re-registered an account that already existed: 409, and a red baseline
# that says nothing about the seam. `$$$$` is the shell's pid, one per invocation.
# Alphanumeric, like verify.sh's: a suite builds contract ids from it (`CALL-SMOKE<id>`,
# `^CALL-[0-9A-Za-z]{6,48}$`), and `make-<pid>` had the worker refuse every one.
smoke: ## Run the baseline suite against the running stack
	@. ./scripts/dev-env.sh && SMOKE_ORIGIN=$(BASE) SMOKE_RUN_ID=make$$$$ \
		./scripts/smoke.py smoke/baseline.yaml \
		--base $(BASE) --contract contracts/openapi.yaml --exclude-tag remote

check-docs: ## The prose-versus-mechanism checks (see scripts/check-docs.py)
	@./scripts/check-docs.py

diagrams: ## Redraw architecture.svg and cicd.svg (+ .excalidraw) from scripts/diagrams/
	@./scripts/diagrams/build.py

verify: ## Assert what is checked out, without dispatching: make verify CHANGE=0001-auth
	@test -n "$(CHANGE)" || { echo "usage: make verify CHANGE=<change-dir>"; exit 2; }
	@./scripts/verify.sh $(CHANGE) --keep-up

iterate: ## What /ship phase 4 runs, by hand: make iterate CHANGE=0001-auth
	@test -n "$(CHANGE)" || { echo "usage: make iterate CHANGE=<change-dir>"; exit 2; }
	@./scripts/iterate.sh $(CHANGE)

# Sourced for the same reason `smoke` sources it: tests/e2e/real-backend.spec.ts skips
# itself when SIGNUP_CODE or SMOKE_PASSWORD is unset, and that skip is silent. Without this
# the only oracle for "the UI calls the real endpoint" reports green by not running.
e2e: ## Run the frontend's Playwright suite against the joined origin
	@. ./scripts/dev-env.sh && cd frontend && PLAYWRIGHT_BASE_URL=$(BASE) npx playwright test

# One eval run against the stack, exactly as the loop runs it — `stack.sh run` is the same
# entry point `changes/*/change.yaml`'s `jobs:` uses, so a run by hand and a run in the
# loop cannot drift apart. Exit 0 = every threshold met, 1 = a breach or an errored
# example, 2 = the eval refused to judge. Override anything for one run:
#   make eval JUDGE=bedrock
#   make eval THRESHOLDS='EVAL_THRESHOLD_RETRIEVAL_RECALL=0.99'
JUDGE      ?=
THRESHOLDS ?=
eval: ## One eval run against the running stack: make eval [JUDGE=bedrock]
	@./scripts/stack.sh run eval $(if $(JUDGE),EVAL_JUDGE=$(JUDGE),) $(THRESHOLDS)

# The two criteria of 0005 the seam cannot see: a trace outliving a Phoenix restart, and
# the backend's log lines carrying the id its response returned. smoke.py speaks HTTP against
# a stack it did not start, so neither is expressible as a step. See changes/0005 BRIEF.md
# § "A gap in the oracle".
phoenix-durability: ## Prove a trace survives restarting Phoenix, and show the log lines
	@./scripts/phoenix-durability.sh

# ── the dev environment in AWS ───────────────────────────────────────────────────────
# docs/adr/0018. Deploys run in CI, never from here: these start them, wait for them, and
# hand the session to them. The only commands that reach AWS from this machine are the
# bootstrap and a local teardown, through scripts/with-aws.sh.

login: ## Log in with SSO and write the session into stack/secrets.env
	@./scripts/login.sh

push-gh-creds: ## Copy the current session into the GitHub repos that can deploy
	@./scripts/push-gh-creds.sh

gh-setup: ## One-time: deploy keys, reusable-workflow access, the deployer role ARN
	@./scripts/gh-setup.sh $(if $(ROLE_ARN),--role-arn $(ROLE_ARN),)

dev-bootstrap: ## One-time: state bucket, registries, deployer role, budget (local apply)
	@./scripts/with-aws.sh ./scripts/infra.sh bootstrap ENV=dev

dev-push: ## Deploy a change's PR to dev and wait for the verdict: make dev-push CHANGE=0007-x
	@test -n "$(CHANGE)" || { echo "usage: make dev-push CHANGE=<change-dir> [ONLY=backend]"; exit 2; }
	@./scripts/dev-push.sh $(CHANGE) $(if $(ONLY),--only $(ONLY),)

dev-eval: ## Run the eval against what dev runs, from a change's PR: make dev-eval CHANGE=0007-x
	@test -n "$(CHANGE)" || { echo "usage: make dev-eval CHANGE=<change-dir> [JUDGE=heuristic]"; exit 2; }
	@./scripts/dev-eval.sh $(CHANGE) $(if $(JUDGE),--judge $(JUDGE),)

dev-up: ## Bring dev up at main's lock (every repo at the pinned SHAs)
	@./scripts/dev-push.sh --lock --ref main

dev-down: ## Take dev to zero and prove nothing billable is left; VIA=ci runs it in Actions
	@./scripts/dev-down.sh $(if $(VIA),--via $(VIA),)

dev-status: ## The last deploys and teardowns, and what dev runs now
	@gh run list -R $(OWNER)/agent-app-project --workflow dev-push.yml --limit 5
	@gh run list -R $(OWNER)/agent-app-project --workflow dev-down.yml --limit 3
	@./scripts/with-aws.sh ./scripts/infra.sh outputs ENV=dev 2>/dev/null \
		|| echo "  (no outputs: dev is down, infra is not checked out, or the session expired)"

k9s: ## k9s on the dev cluster, namespace agentapp (dev must be up)
	@./scripts/with-aws.sh sh -c 'export KUBECONFIG=$$PWD/.kube/dev; ./scripts/infra.sh kubeconfig ENV=dev >/dev/null && k9s -n agentapp'

dev-index: ## What dev's OpenSearch holds: counts, and the N newest call chunks: make dev-index N=3
	@./scripts/with-aws.sh ./scripts/dev-index.sh $(or $(N),3)

# ── across the repos ─────────────────────────────────────────────────────────────────
# Read-only, and they stay that way: implementation happens in a session started inside
# the repo, or through the dispatch /ship runs. Nothing here writes into a submodule.

# The `uncommitted` column is not decoration. `/realign` step 1 switches every submodule to
# main and says to stop if a repo "still has unmerged work" — and a dirty worktree carries
# across `git switch` silently. The control repo's own `git status` cannot tell the two
# apart: a moved pointer and a dirty submodule both print ` M <repo>`. So the tool step 1
# tells you to read has to be the one that says which.
repos: ## Branch and SHA per submodule, against what repos.lock pins
	@printf '  %-16s %-40s %-9s %-18s %s\n' REPO BRANCH SHA "vs repos.lock" uncommitted
	@for r in $(REPOS); do \
		branch=$$(git -C $$r rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-'); \
		sha=$$(git -C $$r rev-parse --short HEAD 2>/dev/null || echo '-'); \
		pinned=$$(awk -v r=$$r '$$1==r{print substr($$2,1,7)}' repos.lock 2>/dev/null); \
		if [ "$$sha" = "$$pinned" ]; then state="matches"; \
		elif [ -z "$$pinned" ]; then state="not pinned"; \
		else state="ahead of $$pinned"; fi; \
		dirty=$$(git -C $$r status --porcelain 2>/dev/null | wc -l | tr -d ' '); \
		if [ "$$dirty" = "0" ]; then dirty="clean"; else dirty="$$dirty file(s)"; fi; \
		printf '  %-16s %-40s %-9s %-18s %s\n' "$$r" "$$branch" "$$sha" "$$state" "$$dirty"; \
	done

lock: ## Refresh repos.lock from the current submodule SHAs
	@./scripts/lock.sh

prs: ## List the open pull requests in each product repo
	@./scripts/prs.sh --list

# `changes/*/` is a filesystem glob and `changes/*/runs/` is gitignored evidence, so a run
# executed on a change's branch leaves a directory behind that looks like a change on every
# OTHER branch. `make check` then failed with "change.yaml not found — run new-change.sh" on
# a branch off origin/main, which is the branch a retrospective is required to use. git is
# what says which directories are changes; the glob only says which exist.
check: ## This repo's gates, then each product repo's read-only ones
	@echo "── control"
	@./scripts/check-docs.py || exit 1
	@./scripts/test-hooks.py >/dev/null || { ./scripts/test-hooks.py; exit 1; }
	@echo "  the submodule-write guard blocks what it claims, and nothing else"
	@for d in changes/*/; do \
		case "$$d" in changes/0000-example-change/) continue ;; esac; \
		git ls-files --error-unmatch "$$d" >/dev/null 2>&1 || continue; \
		./scripts/manifest.py "$$d" --validate >/dev/null || exit 1; \
	done
	@echo "  every change validates"
	@for r in $(REPOS); do \
		echo "── $$r"; \
		if [ -f $$r/Makefile ]; then \
			t=lint; grep -q '^typecheck:' $$r/Makefile && t='lint typecheck'; \
			$(MAKE) -C $$r $$t || exit 1; \
		else echo "  (no Makefile yet — nothing to gate)"; fi; \
	done

# `git submodule update --init` would yank an already-checked-out submodule back to the
# pinned SHA, discarding in-flight work. This only touches the ones not checked out yet.
init: ## Check out any submodule that is missing, without moving the others
	@missing=$$(git submodule status | awk '$$1 ~ /^-/ {print $$2}'); \
	if [ -n "$$missing" ]; then \
		echo "checking out: $$missing"; \
		git submodule update --init -- $$missing; \
	else \
		echo "every submodule is checked out; leaving them where they are"; \
	fi

clean: down ## Tear the stack down and drop local run evidence
	@rm -rf changes/*/runs
	@echo "removed changes/*/runs"
