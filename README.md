# moca-e2e

[![E2E Status](https://github.com/mocachain/moca-e2e/actions/workflows/test-stack.yml/badge.svg?branch=main)](https://github.com/mocachain/moca-e2e/actions/workflows/test-stack.yml)

Cross-repo integration testing hub for the Moca ecosystem. Ensures all components work together by maintaining a **known-good stack pointer** — a tested combination of commit SHAs across all repos.

## How it works

1. When any Moca repo merges to `main`, it fires a `repository_dispatch` to this hub
2. The hub updates `stack.yaml` with the new SHA and force-pushes a rolling branch
3. CI runs the full E2E test suite on **both AMD64 and ARM64**
4. If tests pass, the rolling PR auto-merges — advancing the known-good pointer
5. If tests fail, the team is notified and the pointer stays at the last known-good state

## Quick start

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (with compose v2)
- [yq](https://github.com/mikefarah/yq) (`brew install yq`)
- [jq](https://jqlang.github.io/jq/) (`brew install jq`)
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (optional, for EVM tests)

### Run locally

```bash
# Full E2E: 6 validators, 6 SPs (default topology)
make test

# Quick smoke: 1 validator, 1 SP
make test-minimal

# Stress: mixed validator modes (docker + cosmovisor + binary)
make test-stress

# Custom topology
make test TOPOLOGY=topology/minimal.yaml

# Against live environments
make test ENV=devnet
make test ENV=testnet
make test ENV=mainnet    # smoke tests only (read-only)
```

### Operational commands

```bash
make help              # Show all targets
make up                # Start services without running tests
make down              # Stop services
make logs              # Follow service logs
make ps                # Show running services
make clone             # Clone repos at stack.yaml refs
make build             # Build Docker images
make validate-stack    # Verify all stack.yaml refs exist
```

### Keep cluster running between test runs

```bash
SKIP_TEARDOWN=true make test
# ... fix things, then re-run tests against the running cluster
make test ENV=local    # tests only, no setup/teardown
```

## Architecture

### Topology-driven

Tests are driven by topology YAML files that define the network shape:

```yaml
# topology/default.yaml
validators:
  - name: validator-0
    mode: docker          # plain mocad in Docker
  - name: validator-1
    mode: cosmovisor      # cosmovisor wrapping mocad
  # ...

storage_providers:
  - name: sp-0
  - name: sp-1
  # ...
```

Available validator modes:
- `docker` — plain `mocad start` in a container
- `cosmovisor` — `cosmovisor run start` wrapping mocad (tests upgrade paths)
- `binary` — native binary on host (local dev only)

### CI pipeline

```
Source repo merges to main
  → repository_dispatch to moca-e2e
  → update-stack.yml: updates stack.yaml, force-pushes rolling branch
  → test-stack.yml:
      ├── AMD64 runner: build → deploy → test
      └── ARM64 runner: build → deploy → test
  → advance-pointer.yml: auto-merge on green
```

### Test suite

| Test | Modules |
|------|---------|
| `smoke_chain_status` | CometBFT — chain reachable, producing blocks |
| `smoke_validator_set` | Staking — all validators active with voting power |
| `smoke_sp_status` | SP module — registration query |
| `test_block_production` | Consensus — block rate over 10s |
| `test_bank_transfer` | Bank — send tokens, verify balance changes |
| `test_staking` | Staking — delegate, unbond, verify entries |
| `test_validator_stake` | Staking — all validators bonded, equal stake |
| `test_evm_transfer` | EVM — native transfer via JSON-RPC |
| `test_evm_erc20` | EVM — contract deploy + interact |
| `test_cross_module` | Bank, Staking, Distribution — sequential txs across modules |
| `test_storage_bucket` | Storage — bucket create/query/delete via `mocad`; if `moca-cmd` is available, full bucket CLI flow |
| `test_storage_object` | Storage — full object CLI flow (`put`, `head`, `setTag`, `ls`, cleanup) when `moca-cmd` is available; else bucket-only `mocad` smoke |
| `test_storage_object_failover` | Storage — pause local primary SP, `object get` through secondary fallback, verify SHA-256 |
| `test_storage_object_seal` | Storage — poll `object get-progress` until sealed, then head/list |
| `test_storage_group` | Storage — group lifecycle via `mocad`; if `moca-cmd` is available, full group CLI flow |
| `test_storage_policy` | Storage — bucket/object/group policy CRUD via `moca-cmd` GRNs when available; else `mocad put-policy` |
| `test_payment` | Payment — `moca-cmd payment-account` flow when available; else `mocad tx payment` |
| `test_sp_gateway` | SP — HTTP gateway reachability |
| `test_sp_registration` | SP — on-chain registration checks |
| `test_sp_params` | SP — module params |
| `test_sp_tools` | SP — `moca-cmd sp ls` / `sp head` / `sp get-price` |
| `test_sp_diagnose` | SP — containers, on-chain list, governance proposals, `moca-cmd sp ls`, gateway ports |
| `test_sp_config` | SP — `config.toml` checks (GRPC, HTTP, metrics, BlockSyncer, GVG fees, Server modules) |
| `test_sp_join` | SP — per-operator queries, container health, `moca-cmd sp ls`, `head`, `get-price` |
| `test_sp_exit` | SP — target SP acts as both primary and secondary, waits for GVG counts to drain, then verifies final SP removal from chain |
| `test_sp_delete` | SP — governance delete pre-checks only (no destructive tx by default) |

`tests/lib.sh` exposes `resolve_moca_cmd` / `exec_moca_cmd` for optional `moca-cmd` in Docker (`moca-cmd` container) or on `PATH`.

## Repository structure

```
.
├── .github/workflows/
│   ├── update-stack.yml       # Updates stack.yaml on repo dispatch
│   ├── test-stack.yml         # E2E tests on both arches
│   ├── advance-pointer.yml    # Auto-merges rolling PR on green CI
│   └── test-environment.yml   # Manual: test against live environments
├── topology/
│   ├── default.yaml           # 6 validators (mixed modes), 6 SPs
│   ├── minimal.yaml           # 1 validator, 1 SP (fast smoke)
│   └── stress.yaml            # 6 validators (all modes), 6 SPs
├── docker/
│   ├── Dockerfile.mocad       # Plain mocad image
│   ├── Dockerfile.cosmovisor  # Cosmovisor + mocad image
│   ├── Dockerfile.sp          # Storage provider image
│   ├── Dockerfile.init        # Genesis init image
│   └── entrypoint-*.sh        # Per-mode entrypoints
├── config/                    # Per-environment endpoint configs
├── scripts/
│   ├── generate-compose.sh    # Topology → docker-compose.generated.yml
│   ├── init-genesis.sh        # Genesis init (keys, accounts, gentxs)
│   ├── run-tests.sh           # Main entry point
│   └── ...                    # clone, build, setup, teardown, wait
├── tests/                     # E2E test suites + lib.sh helpers
├── notify-template/           # Drop-in workflow for source repos
├── stack.yaml                 # Known-good stack pointer
└── Makefile                   # Local-first entry point
```

## Adding a source repo

1. Copy `notify-template/notify-e2e.yml` into the source repo at `.github/workflows/`
2. Ensure the `E2E_HUB_PAT` org-level secret is accessible
3. Add the component to `stack.yaml`

## Adding tests

Add test scripts to `tests/`:
- `smoke_*.sh` — lightweight checks, safe for all environments including mainnet
- `test_*.sh` — full E2E tests, run against local/devnet/testnet only

Each test receives `$1` = environment name, `$2` = config file path.

## Roadmap

- [ ] Slack/Discord notifications on CI failure
- [ ] Dependency-aware test triggering — when `moca-cosmos-sdk` changes, only re-test repos that import it rather than the full matrix. Requires mapping the dependency graph between repos so the hub can make smarter decisions about what to test and skip.
- [x] SP / storage CLI tests (`test_storage_*`, `test_sp_*`) when `moca-cmd` and SPs are available
- [ ] Governance proposal E2E tests
- [ ] Upgrade path testing (old binary → new binary via cosmovisor)
