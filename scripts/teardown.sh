#!/usr/bin/env bash
set -euo pipefail

ENV="${1:-local}"

if [ "$ENV" != "local" ]; then
  echo "Teardown not applicable for remote environment: $ENV"
  exit 0
fi

CLUSTER_NAME="moca-e2e"

echo "=== Tearing down Kind cluster: $CLUSTER_NAME ==="
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  kind delete cluster --name "$CLUSTER_NAME"
  echo "Cluster deleted."
else
  echo "Cluster not found, nothing to tear down."
fi

rm -f kubeconfig
