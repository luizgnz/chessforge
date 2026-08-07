#!/usr/bin/env bash
set -euo pipefail
CLUSTER="${CLUSTER:-chessforge}"
kind delete cluster --name "$CLUSTER"
echo "deleted kind cluster: $CLUSTER"
# Optional local unseal material from demo bootstrap
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rm -f "$ROOT/.vault-init.json"
