# Every command needed to run or inspect the WHOLE system lives here — the same reason
# each product repo has a Makefile, one level up. Nothing here reimplements the scripts;
# it is a memorable surface over them, so that "bring the whole thing up and poke at it"
# does not require remembering which script takes which flag.
#
# The product repos each have their own `make up`, which brings up THAT repo in isolation.
# This one brings them up together, on one network, behind one origin — which is the only
# arrangement where the seams between them are real. See docs/adr/0002.

PROXY_PORT   ?= 8080
BASE         ?= http://localhost:$(PROXY_PORT)
BACKEND_BASE ?= http://localhost:8000
MSG          ?= hello
SVC          ?=
CHANGE       ?=

REPOS := chatbot-backend frontend infra

.DEFAULT_GOAL := help
.PHONY: help up down restart ps logs rebuild urls open health chat smoke verify iterate \
        e2e repos lock prs check check-docs init clean

help: ## Show this list
	@echo "The full local stack — backend, datastores, frontend, proxy — on one origin."
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  Variables: PROXY_PORT=$(PROXY_PORT) BASE=$(BASE)"
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

urls: ## Print the endpoints worth knowing
	@echo
	@echo "  app          $(BASE)/"
	@echo "  API          $(BASE)/api/          (proxied; the backend sees it without /api)"
	@echo "  backend      $(BACKEND_BASE)/      (direct, bypassing the proxy)"
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
smoke: ## Run the baseline suite against the running stack
	@. ./scripts/dev-env.sh && SMOKE_ORIGIN=$(BASE) SMOKE_RUN_ID=make \
		./scripts/smoke.py smoke/baseline.yaml \
		--base $(BASE) --contract contracts/openapi.yaml --exclude-tag remote

check-docs: ## The prose-versus-mechanism checks (see scripts/check-docs.py)
	@./scripts/check-docs.py

verify: ## Deploy a change and assert it: make verify CHANGE=0001-auth
	@test -n "$(CHANGE)" || { echo "usage: make verify CHANGE=<change-dir>"; exit 2; }
	@./scripts/verify.sh $(CHANGE) --keep-up

iterate: ## The full loop — dispatch, deploy, smoke, repair: make iterate CHANGE=0001-auth
	@test -n "$(CHANGE)" || { echo "usage: make iterate CHANGE=<change-dir>"; exit 2; }
	@./scripts/iterate.sh $(CHANGE)

e2e: ## Run the frontend's Playwright suite against the joined origin
	@cd frontend && PLAYWRIGHT_BASE_URL=$(BASE) npx playwright test

# ── across the repos ─────────────────────────────────────────────────────────────────
# Read-only, and they stay that way: implementation happens in a session started inside
# the repo, or through ./scripts/fanout.sh. Nothing here writes into a submodule.

repos: ## Branch and SHA per submodule, against what repos.lock pins
	@printf '  %-16s %-40s %-9s %s\n' REPO BRANCH SHA "vs repos.lock"
	@for r in $(REPOS); do \
		branch=$$(git -C $$r rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-'); \
		sha=$$(git -C $$r rev-parse --short HEAD 2>/dev/null || echo '-'); \
		pinned=$$(awk -v r=$$r '$$1==r{print substr($$2,1,7)}' repos.lock 2>/dev/null); \
		if [ "$$sha" = "$$pinned" ]; then state="matches"; \
		elif [ -z "$$pinned" ]; then state="not pinned"; \
		else state="ahead of $$pinned"; fi; \
		printf '  %-16s %-40s %-9s %s\n' "$$r" "$$branch" "$$sha" "$$state"; \
	done

lock: ## Refresh repos.lock from the current submodule SHAs
	@./scripts/lock.sh

prs: ## Open pull requests in each product repo
	@for r in $(REPOS); do \
		echo "── $$r"; \
		(cd $$r && gh pr list --limit 10 2>/dev/null) || echo "  (gh unavailable here)"; \
	done

check: ## This repo's gates, then each product repo's read-only ones
	@echo "── control"
	@./scripts/check-docs.py || exit 1
	@for d in changes/*/; do \
		case "$$d" in changes/0000-example-change/) continue ;; esac; \
		./scripts/manifest.py "$$d" --validate >/dev/null || exit 1; \
	done
	@echo "  every change validates"
	@for r in chatbot-backend frontend; do \
		echo "── $$r"; \
		$(MAKE) -C $$r lint typecheck || exit 1; \
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
