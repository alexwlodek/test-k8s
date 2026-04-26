#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-local-platform}"
KIND_CONFIG="${KIND_CONFIG:-${ROOT_DIR}/kind/cluster.yaml}"
KIND_CONTEXT="kind-${CLUSTER_NAME}"
PRIMARY_KIND_NODE_IMAGE="${PRIMARY_KIND_NODE_IMAGE:-kindest/node:v1.35.1}"
FALLBACK_KIND_NODE_IMAGE="${FALLBACK_KIND_NODE_IMAGE:-kindest/node:v1.34.3}"
DEFAULT_ARGOCD_REPO_URL="${DEFAULT_ARGOCD_REPO_URL:-https://github.com/alexwlodek/test-k8s.git}"
DEFAULT_ARGOCD_TARGET_REVISION="${DEFAULT_ARGOCD_TARGET_REVISION:-main}"
LOCAL_REPO_CONFIGMAP="argocd-local-repo"
LOCAL_REPO_DEPLOYMENT="argocd-local-git"
LOCAL_REPO_URL="git://argocd-local-git.argocd.svc.cluster.local/repo.git"
TMP_FILES=()

cleanup() {
  if ((${#TMP_FILES[@]} > 0)); then
    rm -f "${TMP_FILES[@]}"
  fi
}
trap cleanup EXIT

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf '\nWARN: %s\n' "$*" >&2
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local tool="$1"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    die "${tool} is required for this step."
  fi
}

render_kind_config() {
  local image="$1"
  local rendered_config="$2"
  sed "s#image: kindest/node:.*#image: ${image}#" "${KIND_CONFIG}" >"${rendered_config}"
}

kind_cluster_exists() {
  kind get clusters | grep -qx "${CLUSTER_NAME}"
}

create_kind_cluster_with_image() {
  local image="$1"
  local rendered_config
  rendered_config="$(mktemp -t local-platform-kind.XXXXXX.yaml)"
  TMP_FILES+=("${rendered_config}")
  render_kind_config "${image}" "${rendered_config}"

  log "Creating kind cluster ${CLUSTER_NAME} with ${image}"
  kind create cluster --name "${CLUSTER_NAME}" --config "${rendered_config}"
}

create_cluster() {
  if kind_cluster_exists; then
    log "Using existing kind cluster ${CLUSTER_NAME}"
  elif [[ -n "${KIND_NODE_IMAGE:-}" ]]; then
    create_kind_cluster_with_image "${KIND_NODE_IMAGE}" || die "Failed to create kind cluster with KIND_NODE_IMAGE=${KIND_NODE_IMAGE}."
  else
    if ! create_kind_cluster_with_image "${PRIMARY_KIND_NODE_IMAGE}"; then
      warn "kind failed with ${PRIMARY_KIND_NODE_IMAGE}. Cleaning up and retrying with fallback ${FALLBACK_KIND_NODE_IMAGE}."
      kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
      create_kind_cluster_with_image "${FALLBACK_KIND_NODE_IMAGE}" || die "Failed to create kind cluster with fallback ${FALLBACK_KIND_NODE_IMAGE}."
    fi
  fi

  kubectl config use-context "${KIND_CONTEXT}" >/dev/null
  kubectl wait --for=condition=Ready nodes --all --timeout=180s
}

apply_namespaces() {
  log "Applying platform namespaces"
  kubectl apply -f "${ROOT_DIR}/manifests/namespaces"
}

add_helm_repos() {
  log "Adding Helm repositories"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
  helm repo add istio https://istio-release.storage.googleapis.com/charts --force-update
  helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
  helm repo add argo https://argoproj.github.io/argo-helm --force-update
  helm repo update
}

install_ingress_nginx() {
  log "Installing ingress-nginx"
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --values "${ROOT_DIR}/platform/ingress-nginx/values.yaml" \
    --wait \
    --timeout 5m
}

show_gateway_diagnostics() {
  warn "Istio ingress gateway did not become ready. Recent diagnostics follow."
  helm status istio-ingressgateway -n istio-system || true
  kubectl -n istio-system get pods -l app=istio-ingressgateway -o wide || true
  kubectl -n istio-system describe pods -l app=istio-ingressgateway || true
  kubectl -n istio-system get events --sort-by=.lastTimestamp | tail -n 30 || true
}

cleanup_unhealthy_gateway_release() {
  local release_status
  release_status="$(helm status istio-ingressgateway -n istio-system 2>/dev/null | awk '/^STATUS:/ {print $2; exit}' || true)"

  case "${release_status}" in
    failed|pending-install|pending-upgrade|pending-rollback)
      warn "Removing unhealthy istio-ingressgateway Helm release with status ${release_status} before retrying."
      helm uninstall istio-ingressgateway -n istio-system || true
      ;;
  esac
}

install_istio() {
  log "Installing Istio base"
  helm upgrade --install istio-base istio/base \
    --namespace istio-system \
    --create-namespace \
    --values "${ROOT_DIR}/platform/istio/base-values.yaml" \
    --wait \
    --timeout 5m

  log "Installing istiod"
  helm upgrade --install istiod istio/istiod \
    --namespace istio-system \
    --values "${ROOT_DIR}/platform/istio/istiod-values.yaml" \
    --wait \
    --timeout 5m

  kubectl -n istio-system rollout status deployment/istiod --timeout=300s
  kubectl -n istio-system wait --for=condition=Ready pod -l app=istiod --timeout=300s

  log "Installing Istio ingress gateway"
  cleanup_unhealthy_gateway_release
  if ! helm upgrade --install istio-ingressgateway istio/gateway \
      --namespace istio-system \
      --values "${ROOT_DIR}/platform/istio/ingressgateway-values.yaml" \
      --wait \
      --timeout 10m; then
    show_gateway_diagnostics
    die "Istio ingress gateway failed to install."
  fi

  kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout=300s
}

install_kyverno() {
  log "Installing Kyverno"
  helm upgrade --install kyverno kyverno/kyverno \
    --namespace kyverno \
    --create-namespace \
    --values "${ROOT_DIR}/platform/kyverno/values.yaml" \
    --wait \
    --timeout 8m

  kubectl wait --for=condition=Established crd/clusterpolicies.kyverno.io --timeout=180s
}

install_argocd() {
  log "Installing Argo CD"
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --create-namespace \
    --values "${ROOT_DIR}/platform/argocd/values.yaml" \
    --wait \
    --timeout 10m

  kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=180s
  kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
  kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
  kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
}

seed_local_git_repo() {
  require_command tar

  local bundle deployment_exists local_git_manifest local_git_image escaped_local_git_image
  bundle="$(mktemp -t local-platform-repo.XXXXXX.tar.gz)"
  TMP_FILES+=("${bundle}")
  local_git_manifest="$(mktemp -t local-platform-local-git.XXXXXX.yaml)"
  TMP_FILES+=("${local_git_manifest}")
  local_git_image="${LOCAL_GIT_IMAGE:-$(kubectl -n argocd get deployment argocd-repo-server -o jsonpath='{.spec.template.spec.containers[0].image}')}"
  escaped_local_git_image="$(escape_sed_replacement "${local_git_image}")"

  log "Packaging this checkout for the in-cluster Argo CD Git mirror"
  tar -czf "${bundle}" \
    --exclude=.git \
    --exclude=.codex \
    --exclude=.argocd-source \
    --exclude=.DS_Store \
    --exclude=node_modules \
    --exclude=.terraform \
    -C "${ROOT_DIR}" .

  kubectl -n argocd create configmap "${LOCAL_REPO_CONFIGMAP}" \
    --from-file=repo.tar.gz="${bundle}" \
    --dry-run=client \
    -o yaml | kubectl apply -f -

  if kubectl -n argocd get deployment "${LOCAL_REPO_DEPLOYMENT}" >/dev/null 2>&1; then
    deployment_exists=true
  else
    deployment_exists=false
  fi

  sed "s#__ARGOCD_IMAGE__#${escaped_local_git_image}#g" \
    "${ROOT_DIR}/platform/argocd/local-git-server.yaml" >"${local_git_manifest}"

  log "Deploying local Argo CD Git mirror with image ${local_git_image}"
  kubectl apply -f "${local_git_manifest}"

  if [[ "${deployment_exists}" == "true" ]]; then
    kubectl -n argocd rollout restart deployment/"${LOCAL_REPO_DEPLOYMENT}"
  fi

  kubectl -n argocd rollout status deployment/"${LOCAL_REPO_DEPLOYMENT}" --timeout=180s
}

cleanup_local_git_repo() {
  kubectl -n argocd delete deployment "${LOCAL_REPO_DEPLOYMENT}" --ignore-not-found=true
  kubectl -n argocd delete service "${LOCAL_REPO_DEPLOYMENT}" --ignore-not-found=true
  kubectl -n argocd delete configmap "${LOCAL_REPO_CONFIGMAP}" --ignore-not-found=true
}

resolve_repo_source() {
  if [[ "${USE_LOCAL_GIT_MIRROR:-false}" == "true" ]]; then
    seed_local_git_repo
    ARGOCD_RESOLVED_REPO_URL="${LOCAL_REPO_URL}"
    ARGOCD_RESOLVED_TARGET_REVISION="${ARGOCD_TARGET_REVISION:-main}"
    log "Using in-cluster Argo CD Git mirror ${ARGOCD_RESOLVED_REPO_URL}"
  elif [[ -n "${ARGOCD_REPO_URL:-}" ]]; then
    cleanup_local_git_repo
    ARGOCD_RESOLVED_REPO_URL="${ARGOCD_REPO_URL}"
    ARGOCD_RESOLVED_TARGET_REVISION="${ARGOCD_TARGET_REVISION:-HEAD}"
    log "Using external Argo CD repository ${ARGOCD_RESOLVED_REPO_URL}"
  elif [[ -n "${DEFAULT_ARGOCD_REPO_URL:-}" ]]; then
    cleanup_local_git_repo
    ARGOCD_RESOLVED_REPO_URL="${DEFAULT_ARGOCD_REPO_URL}"
    ARGOCD_RESOLVED_TARGET_REVISION="${ARGOCD_TARGET_REVISION:-${DEFAULT_ARGOCD_TARGET_REVISION}}"
    log "Using default Argo CD repository ${ARGOCD_RESOLVED_REPO_URL}"
  else
    seed_local_git_repo
    ARGOCD_RESOLVED_REPO_URL="${LOCAL_REPO_URL}"
    ARGOCD_RESOLVED_TARGET_REVISION="${ARGOCD_TARGET_REVISION:-main}"
    log "Using in-cluster Argo CD Git mirror ${ARGOCD_RESOLVED_REPO_URL}"
  fi
}

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

apply_root_application() {
  local root_manifest escaped_repo escaped_revision
  root_manifest="$(mktemp -t local-platform-root.XXXXXX.yaml)"
  TMP_FILES+=("${root_manifest}")

  escaped_repo="$(escape_sed_replacement "${ARGOCD_RESOLVED_REPO_URL}")"
  escaped_revision="$(escape_sed_replacement "${ARGOCD_RESOLVED_TARGET_REVISION}")"

  sed \
    -e "s#__REPO_URL__#${escaped_repo}#g" \
    -e "s#__TARGET_REVISION__#${escaped_revision}#g" \
    "${ROOT_DIR}/apps/root-app/root-application.yaml" >"${root_manifest}"

  log "Applying Argo CD root application"
  kubectl apply -f "${root_manifest}"
}

wait_for_application_sync() {
  local app_name="$1"
  local timeout_seconds="$2"
  local deadline=$((SECONDS + timeout_seconds))
  local sync_status health_status

  log "Waiting for Argo CD application ${app_name} to sync"
  while ((SECONDS < deadline)); do
    sync_status="$(kubectl -n argocd get application "${app_name}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health_status="$(kubectl -n argocd get application "${app_name}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"

    if [[ "${sync_status}" == "Synced" ]]; then
      printf 'Application %s synced with health status: %s\n' "${app_name}" "${health_status:-unknown}"
      return 0
    fi

    sleep 5
  done

  kubectl -n argocd get application "${app_name}" -o wide || true
  die "Timed out waiting for Argo CD application ${app_name} to sync."
}

wait_for_demo() {
  wait_for_application_sync root 300
  wait_for_application_sync kyverno-policies 300
  wait_for_application_sync demo-app 300
  wait_for_application_sync istio-demo 300

  log "Waiting for demo workloads"
  kubectl -n demo rollout status deployment/frontend --timeout=300s
  kubectl -n demo rollout status deployment/backend-v1 --timeout=300s
  kubectl -n demo rollout status deployment/backend-v2 --timeout=300s
}

print_access() {
  cat <<EOF

Local Kubernetes platform is ready.

Useful checks:
  kubectl get nodes
  kubectl get pods -A
  kubectl get applications -n argocd
  kubectl get pods -n demo
  kubectl get gateway,virtualservice,destinationrule -n demo

Demo app:
  curl -H "Host: demo.localhost" http://localhost:8080/

Argo CD:
  kubectl -n argocd port-forward svc/argocd-server 8081:80
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  Open http://localhost:8081 and log in as admin.

Destroy:
  ./scripts/destroy.sh
EOF
}

main() {
  "${ROOT_DIR}/scripts/check-tools.sh"
  create_cluster
  apply_namespaces
  add_helm_repos
  install_ingress_nginx
  install_istio
  install_kyverno
  install_argocd
  resolve_repo_source
  apply_root_application
  wait_for_demo
  print_access
}

main "$@"
