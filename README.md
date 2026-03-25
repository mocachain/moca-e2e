# moca-e2e

Cross-repo integration testing hub for the Moca ecosystem. Ensures all components work together by maintaining a **known-good stack pointer** — a tested combination of commit SHAs across all repos.

## How it works

1. When any Moca repo merges to `main`, it fires a `repository_dispatch` to this hub
2. The hub updates `stack.yaml` with the new SHA and force-pushes a rolling branch
3. CI runs the full E2E test suite on **both AMD64 and ARM64**
4. A state determinism check compares app hashes across architectures
5. If tests pass on both arches, the rolling PR auto-merges — advancing the known-good pointer
6. If tests fail, the team is notified and the pointer stays at the last known-good state

## Quick start

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (with compose v2)
- [yq](https://github.com/mikefarah/yq) (`brew install yq`)
- [jq](https://jqlang.github.io/jq/) (`brew install jq`)

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
make export-state      # Export state hashes for determinism check
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

### State determinism check

CI runs the same topology on both AMD64 and ARM64. After tests, it exports the app hash (merkle root of all chain state) at multiple checkpoint heights. A comparison job then diffs the hashes:

- **Match** = state machine is deterministic across architectures
- **Mismatch** = architecture-dependent bug (CGO, BLST, floating-point)

This catches subtle non-determinism bugs that would cause consensus failures in mixed-arch validator sets.

### CI pipeline

```
Source repo merges to main
  → repository_dispatch to moca-e2e
  → update-stack.yml: updates stack.yaml, force-pushes rolling branch
  → test-stack.yml:
      ├── AMD64 runner: build → deploy → test → export state
      └── ARM64 runner: build → deploy → test → export state
      └── compare-state: diff app hashes
  → advance-pointer.yml: auto-merge on green (all 3 jobs pass)
```

## Repository structure

```
.
├── .github/workflows/
│   ├── update-stack.yml       # Updates stack.yaml on repo dispatch
│   ├── test-stack.yml         # E2E tests on both arches + state comparison
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
│   ├── export-state.sh        # Export app hashes for determinism check
│   ├── compare-state.sh       # Diff state hashes across arches
│   └── ...                    # clone, build, setup, teardown, wait
├── tests/                     # E2E test suites
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
