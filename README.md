# moca-e2e

Cross-repo integration testing hub for the Moca ecosystem. Ensures all components work together by maintaining a **known-good stack pointer** — a tested combination of commit SHAs across all repos.

## How it works

1. When any Moca repo merges to `main`, it fires a `repository_dispatch` to this hub
2. The hub updates `stack.yaml` with the new SHA and force-pushes a rolling branch
3. CI runs the full E2E test suite against the updated combination
4. If tests pass, the rolling PR auto-merges — advancing the known-good pointer
5. If tests fail, the team is notified and the pointer stays at the last known-good state

## Quick start

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) (for local tests)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [yq](https://github.com/mikefarah/yq) (`brew install yq`)

### Run locally

```bash
# Run E2E tests against a local Kind cluster
make test ENV=local

# Run against devnet
make test ENV=devnet

# Run against testnet
make test ENV=testnet

# Run smoke tests against mainnet (read-only)
make test ENV=mainnet
```

### Other commands

```bash
make help              # Show all available targets
make setup ENV=local   # Set up Kind cluster without running tests
make teardown          # Tear down local Kind cluster
make validate-stack    # Verify all stack.yaml refs exist
make clone             # Clone all repos at stack.yaml refs
```

### Run via Docker

```bash
docker build -t moca-e2e .
docker run --rm moca-e2e test ENV=local
```

## Repository structure

```
.
├── .github/workflows/
│   ├── update-stack.yml       # Updates stack.yaml on repo dispatch
│   ├── test-stack.yml         # Runs E2E tests on rolling PR
│   ├── advance-pointer.yml    # Auto-merges PR on green CI
│   └── test-environment.yml   # Manual: test against live environments
├── config/
│   ├── local.yaml             # Kind cluster config
│   ├── devnet.yaml            # Devnet endpoints
│   ├── testnet.yaml           # Testnet endpoints
│   └── mainnet.yaml           # Mainnet endpoints (read-only)
├── scripts/                   # Shared scripts (setup, clone, build, test)
├── tests/                     # E2E test suites (smoke_*.sh, *.sh)
├── notify-template/           # Template workflow for source repos
├── stack.yaml                 # Known-good stack pointer
├── kind-config.yaml           # Kind cluster definition
├── Makefile                   # Local-first entry point
└── Dockerfile                 # Containerized test runner
```

## Adding a source repo

1. Copy `notify-template/notify-e2e.yml` into the source repo at `.github/workflows/notify-e2e.yml`
2. Add the `E2E_HUB_PAT` secret to the source repo (PAT with `repo` scope)
3. Add the component to `stack.yaml`

## Adding tests

Add test scripts to `tests/`:
- `smoke_*.sh` — lightweight checks, safe for all environments including mainnet
- `test_*.sh` — full E2E tests, run against local/devnet/testnet only

Each test receives two arguments: `$1` = environment name, `$2` = config file path.
