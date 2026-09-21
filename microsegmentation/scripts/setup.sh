#!/usr/bin/env bash
# ==============================================================================
# Script: setup.sh
# Purpose: Deploys the 3-tier application in namespace 'shop' and records Phase A
#          baseline connectivity (showing unrestricted lateral access before
#          NetworkPolicies are applied).
#
# Rules adhered to:
#   - set -euo pipefail for robust error handling.
#   - Idempotent: safe to run multiple times without duplicating or failing.
#   - Real cluster output captured and saved to results/01-before.txt.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"
RESULTS_DIR="${SCRIPT_DIR}/../results"

mkdir -p "${RESULTS_DIR}"

echo "======================================================================"
echo "[STEP 1] Validating cluster connectivity & Calico CNI status"
echo "======================================================================"
kubectl cluster-info >/dev/null 2>&1 || {
    echo "[-] Error: Kubernetes cluster is not reachable. Ensure Minikube is running." >&2
    exit 1
}

# Verify Calico pods are healthy in kube-system
echo "[+] Checking Calico CNI daemonset/controllers in kube-system..."
kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers | grep -q "Running" || {
    echo "[-] Warning: Calico node pods not running. NetworkPolicy enforcement requires Calico." >&2
}

echo "======================================================================"
echo "[STEP 2] Deploying 3-Tier Application (Namespace: shop)"
echo "======================================================================"
echo "[+] Applying manifests from ${MANIFESTS_DIR}/app.yaml..."
kubectl apply -f "${MANIFESTS_DIR}/app.yaml"

echo "[+] Waiting for Deployments (frontend, backend, db) to be Available..."
kubectl wait --for=condition=Available deployment/frontend -n shop --timeout=90s
kubectl wait --for=condition=Available deployment/backend -n shop --timeout=90s
kubectl wait --for=condition=Available deployment/db -n shop --timeout=90s

echo "[+] Pods currently running in namespace 'shop':"
kubectl get pods -n shop -o wide --show-labels

echo "======================================================================"
echo "[STEP 3] Phase A - Baseline Lateral Movement Check (Before Policy)"
echo "======================================================================"
echo "[*] Threat Scenario: An attacker compromises the internet-facing Frontend"
echo "    and attempts direct HTTP access to the internal Database service (db:80)."
echo "[*] In a default Kubernetes cluster, the network is flat: Ingress is open."

# Capture real execution output to results/01-before.txt
BEFORE_FILE="${RESULTS_DIR}/01-before.txt"

{
    echo "================================================================================"
    echo "PHASE A: BASELINE CONNECTIVITY TEST (BEFORE NETWORKPOLICY ENFORCEMENT)"
    echo "Date: $(date -u)"
    echo "Cluster Nodes:"
    kubectl get nodes -o wide
    echo ""
    echo "Pods in namespace 'shop':"
    kubectl get pods -n shop -o wide --show-labels
    echo ""
    echo "Testing lateral connection: Frontend Pod -> Database Service (http://db.shop.svc.cluster.local:80)"
    echo "Command executed from inside frontend pod:"
    echo "kubectl exec -n shop deploy/frontend -- wget -q -O- --timeout=3 http://db"
    echo "--------------------------------------------------------------------------------"
} > "${BEFORE_FILE}"

echo "[+] Executing probe: frontend -> db..."
if kubectl exec -n shop deploy/frontend -- wget -q -O- --timeout=3 http://db >> "${BEFORE_FILE}" 2>&1; then
    echo "[!] CRITICAL FINDING: Direct access frontend -> db SUCCEEDED!"
    echo "[!] A compromised frontend can read/write to the database directly without going through the backend."
    echo "" >> "${BEFORE_FILE}"
    echo "--------------------------------------------------------------------------------" >> "${BEFORE_FILE}"
    echo "RESULT: VULNERABLE TO LATERAL MOVEMENT (HTTP 200 OK received from database)" >> "${BEFORE_FILE}"
else
    echo "[-] Unexpected: Connection failed before policies were applied."
    echo "RESULT: FAILED" >> "${BEFORE_FILE}"
    exit 1
fi

echo "======================================================================"
echo "[SUCCESS] Phase A complete. Output saved to:"
echo "          ${BEFORE_FILE}"
echo "======================================================================"
