.PHONY: test setup teardown clone build help

ENV ?= local
STACK_FILE ?= stack.yaml
CONFIG_FILE ?= config/$(ENV).yaml

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

test: ## Run E2E tests (ENV=local|devnet|testnet|mainnet)
	@echo "Running E2E tests against: $(ENV)"
	./scripts/run-tests.sh $(ENV) $(STACK_FILE)

setup: ## Set up test environment (Kind for local, noop for remote)
	./scripts/setup-env.sh $(ENV) $(STACK_FILE)

teardown: ## Tear down local Kind cluster
	./scripts/teardown.sh $(ENV)

clone: ## Clone all repos at stack.yaml refs into ./build/
	./scripts/clone-repos.sh $(STACK_FILE)

build: clone ## Build all components from cloned repos
	./scripts/build.sh $(ENV)

update-stack: ## Update a component ref: make update-stack REPO=moca REF=abc1234
	./scripts/update-stack.sh $(STACK_FILE) $(REPO) $(REF)

validate-stack: ## Validate stack.yaml refs exist
	./scripts/validate-stack.sh $(STACK_FILE)
