#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${VAULT_NAMESPACE:-vault}"
POD="${VAULT_POD:-vault-0}"
KEY_SHARES="${VAULT_KEY_SHARES:-1}"
KEY_THRESHOLD="${VAULT_KEY_THRESHOLD:-1}"
WAIT_TIMEOUT="${VAULT_WAIT_TIMEOUT:-300s}"

if ! command -v kubectl >/dev/null 2>&1; then
  printf 'kubectl is required.\n' >&2
  exit 1
fi

printf 'Waiting for %s/%s...\n' "${NAMESPACE}" "${POD}"
kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${POD}" --timeout="${WAIT_TIMEOUT}"

status_output="$(kubectl -n "${NAMESPACE}" exec "${POD}" -- vault status 2>&1 || true)"
if printf '%s\n' "${status_output}" | grep -Eq '^Initialized[[:space:]]+true$'; then
  printf 'Vault is already initialized.\n'
  printf '%s\n' "${status_output}"
  exit 0
fi

cat <<EOF
Initializing Vault with:
  key shares:    ${KEY_SHARES}
  key threshold: ${KEY_THRESHOLD}

Store the unseal key and root token outside Git. They are printed once.
EOF

kubectl -n "${NAMESPACE}" exec "${POD}" -- \
  vault operator init \
    -key-shares="${KEY_SHARES}" \
    -key-threshold="${KEY_THRESHOLD}"

