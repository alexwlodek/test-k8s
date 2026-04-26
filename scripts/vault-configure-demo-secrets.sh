#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${VAULT_NAMESPACE:-vault}"
POD="${VAULT_POD:-vault-0}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-${1:-}}"
DEMO_SECRET_MESSAGE="${DEMO_SECRET_MESSAGE:-hello from Vault}"
DEMO_SECRET_USERNAME="${DEMO_SECRET_USERNAME:-demo-user}"

if ! command -v kubectl >/dev/null 2>&1; then
  printf 'kubectl is required.\n' >&2
  exit 1
fi

if [[ -z "${VAULT_TOKEN}" ]]; then
  printf 'Usage: VAULT_TOKEN=<root-token> %s\n' "$0" >&2
  printf 'Or pass the token as the first argument.\n' >&2
  exit 1
fi

vault_exec() {
  kubectl -n "${NAMESPACE}" exec "${POD}" -- \
    env VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" vault "$@"
}

vault_exec_stdin() {
  kubectl -n "${NAMESPACE}" exec -i "${POD}" -- \
    env VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" vault "$@"
}

printf 'Checking Vault status...\n'
vault_exec status

printf '\nEnabling kv-v2 secrets engine at secret/ if needed...\n'
if ! vault_exec secrets list | awk '{print $1}' | grep -qx 'secret/'; then
  vault_exec secrets enable -path=secret kv-v2
fi

printf '\nWriting demo policy...\n'
printf '%s\n' \
  'path "secret/data/demo/config" {' \
  '  capabilities = ["read"]' \
  '}' \
  'path "secret/metadata/demo/config" {' \
  '  capabilities = ["read"]' \
  '}' |
  vault_exec_stdin policy write demo-read -

printf '\nEnabling Kubernetes auth method if needed...\n'
if ! vault_exec auth list | awk '{print $1}' | grep -qx 'kubernetes/'; then
  vault_exec auth enable kubernetes
fi

printf '\nConfiguring Kubernetes auth method...\n'
kubectl -n "${NAMESPACE}" exec "${POD}" -- \
  env VAULT_ADDR="${VAULT_ADDR}" VAULT_TOKEN="${VAULT_TOKEN}" sh -ec '
    vault write auth/kubernetes/config \
      token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
      kubernetes_host="https://kubernetes.default.svc:443" \
      kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  '

printf '\nWriting Vault role for External Secrets Operator...\n'
vault_exec write auth/kubernetes/role/demo-reader \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  token_policies=demo-read \
  token_ttl=24h \
  audience=vault

printf '\nWriting demo secret to Vault...\n'
vault_exec kv put secret/demo/config \
  message="${DEMO_SECRET_MESSAGE}" \
  username="${DEMO_SECRET_USERNAME}"

cat <<EOF

Vault is configured for the demo ExternalSecret.

Check synchronization:
  kubectl -n demo get externalsecret demo-config
  kubectl -n demo get secret demo-config -o jsonpath='{.data.message}' | base64 -d; echo
EOF
