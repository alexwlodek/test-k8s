#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${VAULT_NAMESPACE:-vault}"
POD="${VAULT_POD:-vault-0}"
UNSEAL_KEY="${VAULT_UNSEAL_KEY:-${1:-}}"

if ! command -v kubectl >/dev/null 2>&1; then
  printf 'kubectl is required.\n' >&2
  exit 1
fi

if [[ -z "${UNSEAL_KEY}" ]]; then
  printf 'Usage: %s <unseal-key>\n' "$0" >&2
  printf 'Or set VAULT_UNSEAL_KEY.\n' >&2
  exit 1
fi

kubectl -n "${NAMESPACE}" exec "${POD}" -- vault operator unseal "${UNSEAL_KEY}"
kubectl -n "${NAMESPACE}" exec "${POD}" -- vault status

