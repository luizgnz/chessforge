#!/usr/bin/env bash
set -euo pipefail
CLUSTER="${CLUSTER:-chessforge}"
kind delete cluster --name "$CLUSTER"
echo "deleted kind cluster: $CLUSTER"
