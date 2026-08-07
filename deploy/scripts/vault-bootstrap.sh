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

# vault status exits 2 when sealed — run inside sh so kubectl exit stays 0.
vault_status_json() {
  kubectl -n "$NS_VAULT" exec "$POD" -- \
    sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json 2>/dev/null || true'
}

vault_cmd() {
  # Usage: vault_cmd TOKEN args...
  local token="$1"
  shift
  kubectl -n "$NS_VAULT" exec "$POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$token" vault "$@"
}

echo "==> check initialization"
STATUS_JSON="$(vault_status_json)"
# Prefer explicit empty-default: ${var:-{}} is parsed as default '{' plus a stray '}'.
INITIALIZED="$(printf '%s\n' "${STATUS_JSON:-"{}"}" | jq -r '.initialized // false')"

if [[ "$INITIALIZED" != "true" ]]; then
  echo "==> vault operator init"
  kubectl -n "$NS_VAULT" exec "$POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 \
    vault operator init -key-shares=1 -key-threshold=1 -format=json >"$INIT_FILE"
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

SEALED="$(printf '%s\n' "$(vault_status_json)" | jq -r '.sealed // true')"
if [[ "$SEALED" == "true" ]]; then
  echo "==> unseal"
  kubectl -n "$NS_VAULT" exec "$POD" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 \
    vault operator unseal "$UNSEAL"
fi

echo "==> wait for Vault unsealed/ready"
for i in $(seq 1 30); do
  SEALED="$(printf '%s\n' "$(vault_status_json)" | jq -r '.sealed // true')"
  if [[ "$SEALED" == "false" ]]; then
    break
  fi
  sleep 2
done

echo "==> enable KV + kubernetes auth"
vault_cmd "$ROOT_TOKEN" secrets enable -path=secret kv-v2 2>/dev/null || true
vault_cmd "$ROOT_TOKEN" auth enable kubernetes 2>/dev/null || true

echo "==> configure kubernetes auth"
vault_cmd "$ROOT_TOKEN" write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc:443 \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  disable_iss_validation=true

echo "==> policy + role for ESO"
POLICY=$'path "secret/data/chessforge/*" {\n  capabilities = ["read"]\n}\npath "secret/metadata/chessforge/*" {\n  capabilities = ["read"]\n}\n'
printf '%s' "$POLICY" | kubectl -n "$NS_VAULT" exec -i "$POD" -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$ROOT_TOKEN" \
  vault policy write eso -

vault_cmd "$ROOT_TOKEN" write auth/kubernetes/role/eso \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso \
  ttl=1h

echo "==> seed secret/chessforge/db"
vault_cmd "$ROOT_TOKEN" kv put secret/chessforge/db \
  password="$PASSWORD" \
  postgres-password="$PASSWORD" \
  DATABASE_URL="$DB_URL"

echo "==> vault bootstrap complete"
kubectl -n "$NS_VAULT" get pod "$POD"
