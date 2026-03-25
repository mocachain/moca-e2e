.PHONY: test setup teardown clone build generate help

ENV ?= local
TOPOLOGY ?= topology/default.yaml
STACK_FILE ?= stack.yaml
CONFIG_FILE ?= config/$(ENV).yaml
COMPOSE_FILE ?= docker-compose.generated.yml

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

test: ## Run E2E tests (ENV=local|devnet|testnet|mainnet, TOPOLOGY=topology/*.yaml)
	./scripts/run-tests.sh $(ENV) $(STACK_FILE) $(TOPOLOGY)

test-minimal: ## Quick smoke test with 1 validator, 1 SP
	./scripts/run-tests.sh local $(STACK_FILE) topology/minimal.yaml

test-stress: ## Stress test with mixed validator modes
	./scripts/run-tests.sh local $(STACK_FILE) topology/stress.yaml

setup: ## Set up local docker-compose environment
	./scripts/setup-env.sh $(ENV) $(STACK_FILE) $(TOPOLOGY)

teardown: ## Tear down local environment
	./scripts/teardown.sh $(ENV)

clone: ## Clone all repos at stack.yaml refs
	./scripts/clone-repos.sh $(STACK_FILE)

build: ## Build all Docker images from cloned repos
	./scripts/build.sh $(ENV)

generate: ## Generate docker-compose from topology
	./scripts/generate-compose.sh $(TOPOLOGY) $(COMPOSE_FILE)

up: generate ## Start services (no tests)
	docker compose -f $(COMPOSE_FILE) up -d
	./scripts/wait-for-chain.sh http://localhost:26657 5 120

down: ## Stop services
	docker compose -f $(COMPOSE_FILE) down -v --remove-orphans --timeout 30

logs: ## Show service logs
	docker compose -f $(COMPOSE_FILE) logs -f

ps: ## Show running services
	docker compose -f $(COMPOSE_FILE) ps

update-stack: ## Update a component ref: make update-stack REPO=moca REF=abc1234
	./scripts/update-stack.sh $(STACK_FILE) $(REPO) $(REF)

validate-stack: ## Validate stack.yaml refs exist
	./scripts/validate-stack.sh $(STACK_FILE)
