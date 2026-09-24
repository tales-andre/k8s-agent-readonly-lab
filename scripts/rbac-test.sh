#!/usr/bin/env bash
# Runs mcp-server-kubernetes with ALL tools exposed (no filtering flag) and makes the same
# tool calls twice: once as cluster-admin, once as a ServiceAccount bound to "view".
# Everything happens in a throwaway kind cluster that is deleted at the end.
set -euo pipefail

VERSION="${1:-4.1.7}"
CLUSTER=readonly-lab
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
ADMIN_KUBECONFIG="$WORK/admin.yaml"
AGENT_KUBECONFIG="$WORK/agent.yaml"
trap 'kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

kind create cluster --name "$CLUSTER" --kubeconfig "$ADMIN_KUBECONFIG" --wait 120s
export KUBECONFIG="$ADMIN_KUBECONFIG"
kubectl apply -f "$ROOT/manifests/workload.yaml" -f "$ROOT/manifests/agent-readonly-rbac.yaml"
kubectl -n demo rollout status deploy/web --timeout=180s
POD="$(kubectl -n demo get pod -l app=web -o jsonpath='{.items[0].metadata.name}')"

# Kubeconfig for the agent identity: same server and CA, ServiceAccount token instead of admin cert.
TOKEN="$(kubectl -n agent-system create token ai-agent-readonly --duration=1h)"
SERVER="$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')"
CA="$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
cat > "$AGENT_KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: $CLUSTER
  cluster: {server: $SERVER, certificate-authority-data: $CA}
users:
- name: ai-agent-readonly
  user: {token: $TOKEN}
contexts:
- name: agent
  context: {cluster: $CLUSTER, user: ai-agent-readonly}
current-context: agent
EOF

CM='{"manifest":"apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: written-by-agent\n  namespace: demo\ndata:\n  hello: world\n","namespace":"demo"}'
run_calls() {
  KUBECONFIG="$1" node "$ROOT/scripts/mcp-tools.mjs" "$VERSION" \
    --call kubectl_get     --args '{"resourceType":"pods","namespace":"demo"}' \
    --call kubectl_apply   --args "$CM" \
    --call kubectl_scale   --args '{"name":"web","namespace":"demo","replicas":2,"resourceType":"deployment"}' \
    --call kubectl_patch   --args '{"resourceType":"deployment","name":"web","namespace":"demo","patchType":"merge","patchData":{"metadata":{"labels":{"patched-by":"agent"}}}}' \
    --call exec_in_pod     --args "{\"name\":\"$POD\",\"namespace\":\"demo\",\"command\":[\"cat\",\"/etc/hostname\"]}" \
    --call kubectl_delete  --args '{"resourceType":"configmap","name":"written-by-agent","namespace":"demo"}'
}

mkdir -p "$ROOT/evidence"
run_calls "$AGENT_KUBECONFIG" > "$ROOT/evidence/rbac-as-view-serviceaccount.json"
run_calls "$ADMIN_KUBECONFIG" > "$ROOT/evidence/rbac-as-cluster-admin.json"
echo "done: evidence/rbac-as-*.json"
