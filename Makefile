.PHONY: help test lint test-container

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  %-16s %s\n", $$1, $$2}'

test: ## Run the full suite locally (lint + compose + dry-run); runs anywhere
	@bash scripts/test.sh

lint: ## Just the linters: bash -n + shellcheck (if installed)
	@bash -n scripts/*.sh bootstrap.sh && echo "syntax ok"
	@command -v shellcheck >/dev/null 2>&1 && shellcheck -S warning -x scripts/*.sh bootstrap.sh || echo "shellcheck not installed (skipped)"

test-container: ## Build the Arch container and run the suite inside it (macOS via podman machine)
	@bash test/run.sh
