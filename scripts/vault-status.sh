#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${VAULT_NAMESPACE:-vault}"
POD="${VAULT_POD:-vault-0}"

if ! command -v kubectl >/dev/null 2>&1; then
  printf 'kubectl is required.\n' >&2
  exit 1
fi

kubectl -n "${NAMESPACE}" exec "${POD}" -- vault status
printf '\n'
kubectl -n vault get pods
printf '\n'
kubectl get clustersecretstore vault 2>/dev/null || true
kubectl -n demo get externalsecret demo-config 2>/dev/null || true
kubectl -n demo get secret demo-config 2>/dev/null || true

