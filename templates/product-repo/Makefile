# Every command needed to build, run or inspect this repo is a target here.

.DEFAULT_GOAL := help
.PHONY: help check

help: ## Show this list
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'

# The gate: lint, typecheck, tests. The Stop hook and CI both run it. Until a toolchain is
# chosen it refuses, so a scaffold can never read as a passing build.
check: ## Lint, typecheck and test — the gate
	@echo "make check: no toolchain yet — the first implementing change fills this target" >&2
	@exit 2
