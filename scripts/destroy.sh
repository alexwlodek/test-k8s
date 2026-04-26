#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-local-platform}"

if ! command -v kind >/dev/null 2>&1; then
  printf 'kind is required to delete the cluster.\n' >&2
  exit 1
fi

if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  printf 'Deleting kind cluster %s...\n' "${CLUSTER_NAME}"
  kind delete cluster --name "${CLUSTER_NAME}"
else
  printf 'kind cluster %s does not exist. Nothing to delete.\n' "${CLUSTER_NAME}"
fi

