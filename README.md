# Local Kubernetes Platform on kind

This repository builds a complete local Kubernetes demo platform on kind with:

- ingress-nginx
- Istio base, istiod, and istio-ingressgateway
- Kyverno
- Argo CD
- An Argo CD app-of-apps root application
- A demo frontend/backend app with Istio traffic splitting

The kind cluster tries `kindest/node:v1.35.1` first. At the time this repo was generated, that Kubernetes v1.35 image was available on Docker Hub. If kind cannot bring up the v1.35 node, the bootstrap script cleans up the failed attempt and retries with the newest available v1.34 fallback, `kindest/node:v1.34.3`.

To force a specific node image yourself, run:

```bash
KIND_NODE_IMAGE=kindest/node:v1.34.3 ./scripts/bootstrap.sh
```

## Prerequisites

Install and start:

- Docker
- kind
- kubectl
- Helm

The bootstrap script also uses `tar` only when `USE_LOCAL_GIT_MIRROR=true`.

## Bootstrap

```bash
chmod +x scripts/*.sh
./scripts/bootstrap.sh
```

The script is idempotent where practical. It creates or reuses a kind cluster named `local-platform`, installs the platform components with Helm, and applies the Argo CD root Application from:

```text
https://github.com/alexwlodek/test-k8s.git
```

If the v1.35 kind node image fails during kubelet startup, bootstrap automatically retries with `kindest/node:v1.34.3`. Set `KIND_NODE_IMAGE` to disable the automatic image choice and use the exact image you provide.

To use a different Git repository, set:

```bash
ARGOCD_REPO_URL=https://github.com/your-org/your-repo.git \
  ARGOCD_TARGET_REVISION=main \
  ./scripts/bootstrap.sh
```

To force the original local in-cluster Git mirror instead of GitHub, run:

```bash
USE_LOCAL_GIT_MIRROR=true ./scripts/bootstrap.sh
```

For private repositories, add credentials to Argo CD yourself; this demo does not hardcode secrets.

## Destroy

```bash
./scripts/destroy.sh
```

Set `CLUSTER_NAME` if you used a non-default cluster name:

```bash
CLUSTER_NAME=my-platform ./scripts/destroy.sh
```

## Access Argo CD

Port-forward the Argo CD API/UI:

```bash
kubectl -n argocd port-forward svc/argocd-server 8081:80
```

Get the initial admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Open:

```text
http://localhost:8081
```

Username: `admin`

## Access the Demo App

Use the Host header:

```bash
curl -H "Host: demo.localhost" http://localhost:8080/
```

For browser access, add this to `/etc/hosts` if your system does not resolve `demo.localhost` automatically:

```text
127.0.0.1 demo.localhost demo.local
```

Then open:

```text
http://demo.localhost:8080/
```

## Useful Checks

These commands should work after bootstrap:

```bash
kubectl get nodes
kubectl get pods -A
kubectl get applications -n argocd
kubectl get pods -n demo
kubectl get gateway,virtualservice,destinationrule -n demo
curl -H "Host: demo.localhost" http://localhost:8080/
```

## Verify Istio Sidecar Injection

The `demo` namespace is labeled with `istio-injection=enabled`.

Check that demo pods include the `istio-proxy` sidecar:

```bash
kubectl get pods -n demo \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[*].name}{"\n"}{end}'
```

You should see both the app container and `istio-proxy`.

## Test Traffic Splitting

The frontend proxies to the backend service. Istio applies an internal backend `VirtualService` with:

- 80% to `backend-v1`
- 20% to `backend-v2`

Run:

```bash
for i in {1..30}; do
  curl -s -H "Host: demo.localhost" http://localhost:8080/
done | sort | uniq -c
```

The frontend returns a small JSON response from `agnhost` showing the backend response it received. You should see mostly `backend version: v1` and some `backend version: v2`.

## Test Kyverno

This repo installs a simple Kyverno `ClusterPolicy` that requires pods in the `demo` namespace to set the `app.kubernetes.io/name` label.

Try the invalid example:

```bash
kubectl apply -f examples/kyverno-invalid/pod-missing-app-label.yaml
```

Kyverno should deny the pod because it lacks `app.kubernetes.io/name`.

## Layout

```text
kind/
  cluster.yaml
scripts/
  bootstrap.sh
  check-tools.sh
  destroy.sh
platform/
  ingress-nginx/
  istio/
  kyverno/
  argocd/
apps/
  root-app/
  demo-app/
manifests/
  namespaces/
  istio-demo/
examples/
  kyverno-invalid/
```

## Troubleshooting

If kind cannot pull or start `kindest/node:v1.35.1`, the bootstrap script automatically falls back to `kindest/node:v1.34.3`. To skip the v1.35 attempt, use:

```bash
KIND_NODE_IMAGE=kindest/node:v1.34.3 ./scripts/bootstrap.sh
```

If both v1.35 and v1.34 fail with `failed while waiting for the kubelet to start`, check Docker resources and cgroup support. On WSL2, make sure Docker Desktop integration is enabled for the distro, restart Docker Desktop, then rerun bootstrap.

If ports are already in use, stop the process using `localhost:8080` or `localhost:8443`, then rerun bootstrap.

If Argo CD Applications stay `OutOfSync` or `Unknown`, inspect:

```bash
kubectl get applications -n argocd
kubectl describe application root -n argocd
kubectl logs -n argocd deploy/argocd-repo-server
```

If you are using `USE_LOCAL_GIT_MIRROR=true` and the local Git mirror needs to be refreshed after edits, rerun:

```bash
USE_LOCAL_GIT_MIRROR=true ./scripts/bootstrap.sh
```

If demo pods do not have sidecars, restart them after confirming the namespace label:

```bash
kubectl get namespace demo --show-labels
kubectl rollout restart deployment -n demo
```
# test-k8s
