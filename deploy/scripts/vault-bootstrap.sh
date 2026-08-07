#!/usr/bin/env bash
# Demo bootstrap for kind: init/unseal Vault, seed KV, configure K8s auth for ESO.
# Unseal material goes to .vault-init.json (gitignored) and Secret vault-init in the vault namespace.
set -euo pipefail

NS_VAULT="${NS_VAULT:-vault}"
POD="${POD:-vault-0}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INIT_FILE="${INIT_FILE:-$ROOT/.vault-init.json}"
PASSWORD="${CHESSFORGE_DB_PASSWORD:-chessforge}"
DB_URL="${CHESSFORGE_DATABASE_URL:-postgresql://chessforge:${PASSWORD}@chessforge-postgresql:5432/chessforge}"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need kubectl
need jq

echo "==> wait for $NS_VAULT/$POD Running"
kubectl -n "$NS_VAULT" wait --for=jsonpath='{.status.phase}'=Running pod/"$POD" --timeout=300s

vault_sh() {
  kubectl -n "$NS_VAULT" exec "$POD" -- sh -c "export VAULT_ADDR=http://127.0.0.1:8200; $*"
}

echo "==> check initialization"
set +e
STATUS_JSON="$(vault_sh 'vault status -format=json' 2>/dev/null)"
set -e

if [[ -z "${STATUS_JSON:-}" ]] || [[ "$(echo "$STATUS_JSON" | jq -r '.initialized' 2>/dev/null || echo false)" != "true" ]]; then
  if [[ ! -f "$INIT_FILE" ]]; then
    echo "==> vault operator init"
    vault_sh 'vault operator init -key-shares=1 -key-threshold=1 -format=json' >"$INIT_FILE"
  fi
elif [[ ! -f "$INIT_FILE" ]]; then
  if kubectl -n "$NS_VAULT" get secret vault-init >/dev/null 2>&1; then
    kubectl -n "$NS_VAULT" get secret vault-init -o jsonpath='{.data.init\.json}' | base64 -d >"$INIT_FILE"
  else
    echo "Vault initialized but no $INIT_FILE / vault-init secret; recreate cluster." >&2
    exit 1
  fi
fi

UNSEAL="$(jq -r '.unseal_keys_b64[0]' "$INIT_FILE")"
ROOT_TOKEN="$(jq -r '.root_token' "$INIT_FILE")"

kubectl -n "$NS_VAULT" create secret generic vault-init \
  --from-file=init.json="$INIT_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

SEALED="$(vault_sh 'vault status -format=json' | jq -r '.sealed')"
if [[ "$SEALED" == "true" ]]; then
  echo "==> unseal"
  vault_sh "vault operator unseal ${UNSEAL}"
fi

echo "==> enable KV + kubernetes auth"
vault_sh "VAULT_TOKEN=${ROOT_TOKEN} vault secrets enable -path=secret kv-v2" || true
vault_sh "VAULT_TOKEN=${ROOT_TOKEN} vault auth enable kubernetes" || true

echo "==> configure kubernetes auth"
vault_sh "VAULT_TOKEN=${ROOT_TOKEN} vault write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc:443 \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  disable_iss_validation=true"

echo "==> policy + role for ESO"
POLICY='path "secret/data/chessforge/*" { capabilities = ["read"] }
path "secret/metadata/chessforge/*" { capabilities = ["read"] }'
kubectl -n "$NS_VAULT" exec "$POD" -- sh -c \
  "export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN='${ROOT_TOKEN}'; printf '%s\n' \"$POLICY\" | vault policy write eso -"

vault_sh "VAULT_TOKEN=${ROOT_TOKEN} vault write auth/kubernetes/role/eso \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso \
  ttl=1h"

echo "==> seed secret/chessforge/db"
vault_sh "VAULT_TOKEN=${ROOT_TOKEN} vault kv put secret/chessforge/db \
  password=${PASSWORD} \
  postgres-password=${PASSWORD} \
  DATABASE_URL=${DB_URL}"

echo "==> vault bootstrap complete"
