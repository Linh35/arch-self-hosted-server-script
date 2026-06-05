.PHONY: help test unit lint test-container staging-up staging-down staging-sh staging-logs staging-ps

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  %-16s %s\n", $$1, $$2}'

test: ## Run the full suite locally (lint + compose + dry-run + unit); runs anywhere
	@bash scripts/test.sh

unit: ## Just the assertion-based unit tests (test/unit.sh)
	@bash test/unit.sh

lint: ## Just the linters: bash -n + shellcheck (if installed)
	@bash -n scripts/*.sh bootstrap.sh && echo "syntax ok"
	@command -v shellcheck >/dev/null 2>&1 && shellcheck -S warning -x scripts/*.sh bootstrap.sh || echo "shellcheck not installed (skipped)"

test-container: ## Build the Arch container and run the suite inside it (macOS via podman machine)
	@bash test/run.sh

staging-up: ## Boot a disposable server-in-a-box to actually run the stacks (PROFILE=lite|full)
	@bash staging/run.sh

staging-down: ## Destroy the staging container and everything inside it
	@podman rm -f selfhost-staging >/dev/null 2>&1 && echo "staging destroyed" || echo "staging not running"

staging-sh: ## Open a shell inside the running staging container
	@podman exec -it selfhost-staging bash

staging-logs: ## Follow the staging container's startup output
	@podman logs -f selfhost-staging

staging-ps: ## List the inner service containers
	@podman exec selfhost-staging podman ps
