#!/usr/bin/env bash
# Zero-cost local DevOps stack: kind + MinIO + Jenkins + Postgres + Prometheus + Grafana.
# Prereqs on your laptop: docker, kind, kubectl, helm.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not installed"; exit 1; }; }
need docker; need kind; need kubectl; need helm

CLUSTER=devops-notes
IMAGE_TAG="${IMAGE_TAG:-local}"
IMAGE="notes-app:${IMAGE_TAG}"

echo ">>> 1/7  Creating kind cluster '$CLUSTER' (idempotent)..."
if ! kind get clusters | grep -q "^${CLUSTER}$"; then
  kind create cluster --config "$HERE/kind-cluster.yaml"
fi
kubectl cluster-info --context "kind-${CLUSTER}" >/dev/null

echo ">>> 2/7  Building notes-app image & loading into kind..."
docker build -t "$IMAGE" "$ROOT"
kind load docker-image "$IMAGE" --name "$CLUSTER"

echo ">>> 3/7  Deploying Postgres + notes-app..."
kubectl apply -f "$ROOT/k8s/namespace.yaml"
kubectl apply -f "$ROOT/k8s/configmap.yaml" -n notes
# Create a local secret with dev values if missing.
# Google OAuth: set these two env vars before running the script, OR edit the secret
# afterwards with `kubectl -n notes edit secret notes-app-secret`:
#   export GOOGLE_CLIENT_ID=...
#   export GOOGLE_CLIENT_SECRET=...
JWT_SECRET_VAL="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
SESSION_SECRET_VAL="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
kubectl -n notes get secret notes-app-secret >/dev/null 2>&1 || \
  kubectl -n notes create secret generic notes-app-secret \
    --from-literal=DB_USER=notes \
    --from-literal=DB_PASSWORD=notes_local_dev \
    --from-literal=GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}" \
    --from-literal=GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}" \
    --from-literal=JWT_SECRET="${JWT_SECRET_VAL}" \
    --from-literal=SESSION_SECRET="${SESSION_SECRET_VAL}"
kubectl apply -f "$ROOT/k8s/postgres.yaml" -n notes
sed "s|IMAGE_PLACEHOLDER|${IMAGE}|g" "$ROOT/k8s/app-deployment.yaml" \
  | kubectl apply -n notes -f -
kubectl apply -f "$ROOT/k8s/app-service.yaml" -n notes
kubectl -n notes rollout status deploy/notes-app --timeout=180s

echo ">>> 4/7  Deploying MinIO (S3-compatible artifact store)..."
kubectl apply -f "$HERE/minio.yaml"
kubectl -n minio rollout status deploy/minio --timeout=120s

echo ">>> 5/7  Deploying Jenkins in-cluster..."
kubectl apply -f "$HERE/jenkins.yaml"
kubectl -n jenkins rollout status deploy/jenkins --timeout=240s

echo ">>> 6/7  Installing kube-prometheus-stack + ServiceMonitor + alerts + dashboard..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1 || \
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password=admin_local_dev
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  -n monitoring -f "$ROOT/monitoring/values.yaml" --wait --timeout 10m
kubectl apply -f "$ROOT/monitoring/servicemonitor.yaml"
kubectl apply -f "$ROOT/monitoring/prometheusrule.yaml"
kubectl apply -f "$ROOT/monitoring/grafana-dashboard-configmap.yaml"

echo ">>> 7/7  Smoke test..."
sleep 3
curl -fsS http://localhost:30080/health && echo

cat <<EOF

======================================================================
  Zero-cost DevOps stack is UP. Open these in your browser:

    Notes app        http://localhost:30080  ( /health /metrics /auth/google/login /notes )
    Jenkins          http://localhost:8080   (setup wizard will run)
    Grafana          http://localhost:30030  (admin / admin_local_dev)
    Prometheus       http://localhost:30090
    MinIO console    http://localhost:9001   (minioadmin / minioadmin123)

  Google OAuth:
    1. Google Cloud Console -> APIs & Services -> Credentials -> Create OAuth client ID
       Application type: Web application
       Authorized redirect URI:  http://localhost:30080/auth/google/callback
    2. kubectl -n notes edit secret notes-app-secret
       Fill GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET (base64-encode manually, or
       recreate the secret via kubectl create secret generic with --from-literal).
    3. kubectl -n notes rollout restart deploy/notes-app
    4. Open http://localhost:30080/auth/google/login

  Tear everything down:  ./local/teardown-local.sh
======================================================================
EOF
