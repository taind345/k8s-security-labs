#!/usr/bin/env bash
# ==============================================================================
# Script: verify.sh
# Purpose: Applies ingress NetworkPolicies (Phase B: Zero Trust) and executes an
#          automated test matrix using short-lived labeled BusyBox pods with a 3s timeout
#          (Phase C). Evaluates actual traffic flow against security requirements
#          and outputs a PASS/FAIL table to stdout and results/02-after.txt.
#
# Usage:
#   ./verify.sh                # Base lab: applies policies.yaml & tests Ingress
#   ./verify.sh --bonus-egress # Bonus: also applies egress-bonus.yaml & tests Egress
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"
RESULTS_DIR="${SCRIPT_DIR}/../results"

mkdir -p "${RESULTS_DIR}"
AFTER_FILE="${RESULTS_DIR}/02-after.txt"
BONUS_FILE="${RESULTS_DIR}/03-bonus-egress.txt"

RUN_BONUS_EGRESS=false
if [[ "${1:-}" == "--bonus-egress" ]]; then
    RUN_BONUS_EGRESS=true
else
    # Ensure any previous bonus egress policies are cleaned up for base ingress testing
    kubectl delete -f "${MANIFESTS_DIR}/egress-bonus.yaml" --ignore-not-found=true >/dev/null 2>&1 || true
fi

echo "======================================================================"
echo "[STEP 1] Applying Ingress NetworkPolicies (Phase B: Zero Trust)"
echo "======================================================================"
echo "[+] Applying policies from ${MANIFESTS_DIR}/policies.yaml..."
kubectl apply -f "${MANIFESTS_DIR}/policies.yaml"

echo "[+] Active NetworkPolicies in namespace 'shop':"
kubectl get networkpolicy -n shop

# Allow Calico eBPF/iptables data plane a moment to synchronize kernel rules
sleep 2

echo "======================================================================"
echo "[STEP 2] Phase C - Automated Connectivity Test Matrix"
echo "======================================================================"
echo "[*] Launching short-lived BusyBox (1.37.0) probe pods with attached stream (-i)."
echo "[*] Connection timeout: 3 seconds."
echo ""

print_and_log() {
    echo "$1" | tee -a "${AFTER_FILE}"
}

# Clear previous results file
> "${AFTER_FILE}"

print_and_log "================================================================================"
print_and_log "PHASE C: AUTOMATED NETWORKPOLICY VERIFICATION MATRIX (AFTER POLICIES)"
print_and_log "Date: $(date -u)"
print_and_log "Active NetworkPolicies in namespace 'shop':"
kubectl get networkpolicy -n shop | tee -a "${AFTER_FILE}"
print_and_log "--------------------------------------------------------------------------------"
print_and_log "| Source Tier / Pod       | Destination Service | Expected | Actual  | Status |"
print_and_log "|-------------------------|---------------------|----------|---------|--------|"

TOTAL_TESTS=0
PASSED_TESTS=0

# Helper function to run attached ephemeral pod and test connectivity
test_connection() {
    local source_desc="$1"
    local pod_name="$2"
    local labels="$3"
    local dest_desc="$4"
    local target_url="$5"
    local expected="$6" # "ALLOWED" or "BLOCKED"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    # Pre-clean pod name if previously interrupted
    kubectl delete pod "${pod_name}" -n shop --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true

    local actual="BLOCKED"

    # Run ephemeral pod interactively so kubectl waits for container execution
    if kubectl run "${pod_name}" \
        --namespace=shop \
        --image=busybox:1.37.0 \
        --image-pull-policy=IfNotPresent \
        --restart=Never \
        --rm \
        -i \
        --labels="${labels}" \
        --command \
        -- timeout 3 wget -q -O- --timeout=3 "${target_url}" >/dev/null 2>&1; then
        actual="ALLOWED"
    else
        actual="BLOCKED"
    fi

    # Ensure cleanup
    kubectl delete pod "${pod_name}" -n shop --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true

    local status="FAIL"
    if [[ "${actual}" == "${expected}" ]]; then
        status="PASS"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    fi

    local row
    row=$(printf "| %-23s | %-19s | %-8s | %-7s | %-6s |" \
        "${source_desc}" "${dest_desc}" "${expected}" "${actual}" "${status}")
    print_and_log "${row}"
}

# 1. External/Client -> Frontend (Should be ALLOWED)
test_connection "Client (unlabeled)" "probe-client" "app=shop,role=client" "frontend:80" "http://frontend" "ALLOWED"

# 2. Frontend -> Backend (Should be ALLOWED)
test_connection "Frontend (tier=frontend)" "probe-fe-to-be" "app=shop,tier=frontend" "backend:80" "http://backend" "ALLOWED"

# 3. Backend -> Database (Should be ALLOWED)
test_connection "Backend (tier=backend)" "probe-be-to-db" "app=shop,tier=backend" "db:80" "http://db" "ALLOWED"

# 4. Frontend -> Database (CRITICAL TEST: Lateral movement MUST be BLOCKED)
test_connection "Frontend (tier=frontend)" "probe-fe-to-db" "app=shop,tier=frontend" "db:80" "http://db" "BLOCKED"

# 5. Unlabeled/Rogue Pod -> Backend (MUST be BLOCKED by default-deny)
test_connection "Rogue (role=attacker)" "probe-rogue-be" "role=attacker" "backend:80" "http://backend" "BLOCKED"

# 6. Unlabeled/Rogue Pod -> Database (MUST be BLOCKED by default-deny)
test_connection "Rogue (role=attacker)" "probe-rogue-db" "role=attacker" "db:80" "http://db" "BLOCKED"

print_and_log "--------------------------------------------------------------------------------"
print_and_log "Summary: ${PASSED_TESTS}/${TOTAL_TESTS} tests passed."

# Direct verification from the deployed frontend container
print_and_log ""
print_and_log "Direct verification from running deployment/frontend to db:"
print_and_log "Command: kubectl exec -n shop deploy/frontend -- timeout 3 wget -q -O- --timeout=3 http://db"
if kubectl exec -n shop deploy/frontend -- timeout 3 wget -q -O- --timeout=3 http://db >/dev/null 2>&1; then
    print_and_log "[!] Lateral connection succeeded - Policy NOT working!"
else
    print_and_log "[+] Verified: Connection timed out as expected (exit code 143/non-zero)."
    print_and_log "[+] Lateral movement from Frontend to Database is successfully BLOCKED!"
fi

echo ""
echo "======================================================================"
echo "[SUCCESS] Ingress verification complete. Output saved to:"
echo "          ${AFTER_FILE}"
echo "======================================================================"

# ==============================================================================
# Bonus Section: Default-Deny Egress Verification
# ==============================================================================
if [[ "${RUN_BONUS_EGRESS}" == "true" ]]; then
    echo ""
    echo "======================================================================"
    echo "[BONUS STEP] Applying Default-Deny Egress NetworkPolicies"
    echo "======================================================================"
    echo "[+] Applying manifests from ${MANIFESTS_DIR}/egress-bonus.yaml..."
    kubectl apply -f "${MANIFESTS_DIR}/egress-bonus.yaml"
    sleep 2

    print_and_log_bonus() {
        echo "$1" | tee -a "${BONUS_FILE}"
    }

    > "${BONUS_FILE}"
    print_and_log_bonus "================================================================================"
    print_and_log_bonus "BONUS: EGRESS NETWORKPOLICY VERIFICATION"
    print_and_log_bonus "Date: $(date -u)"
    print_and_log_bonus "Active NetworkPolicies in namespace 'shop':"
    kubectl get networkpolicy -n shop | tee -a "${BONUS_FILE}"
    print_and_log_bonus "--------------------------------------------------------------------------------"
    print_and_log_bonus "| Source Tier / Pod       | Destination / Protocol  | Expected | Actual  | Status |"
    print_and_log_bonus "|-------------------------|-------------------------|----------|---------|--------|"

    EGRESS_TOTAL=0
    EGRESS_PASSED=0

    test_egress() {
        local source_desc="$1"
        local pod_name="$2"
        local labels="$3"
        local dest_desc="$4"
        local cmd="$5"
        local expected="$6"

        EGRESS_TOTAL=$((EGRESS_TOTAL + 1))
        kubectl delete pod "${pod_name}" -n shop --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true

        local actual="BLOCKED"
        if kubectl run "${pod_name}" \
            --namespace=shop \
            --image=busybox:1.37.0 \
            --image-pull-policy=IfNotPresent \
            --restart=Never \
            --rm \
            -i \
            --labels="${labels}" \
            --command -- sh -c "${cmd}" >/dev/null 2>&1; then
            actual="ALLOWED"
        else
            actual="BLOCKED"
        fi

        kubectl delete pod "${pod_name}" -n shop --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true

        local status="FAIL"
        if [[ "${actual}" == "${expected}" ]]; then
            status="PASS"
            EGRESS_PASSED=$((EGRESS_PASSED + 1))
        fi

        local row
        row=$(printf "| %-23s | %-23s | %-8s | %-7s | %-6s |" \
            "${source_desc}" "${dest_desc}" "${expected}" "${actual}" "${status}")
        print_and_log_bonus "${row}"
    }

    # 1. DNS Resolution (Must be ALLOWED via CoreDNS UDP/53)
    test_egress "Frontend (tier=frontend)" "probe-dns" "app=shop,tier=frontend" "CoreDNS (UDP 53)" "nslookup backend.shop.svc.cluster.local" "ALLOWED"

    # 2. Frontend -> Backend Egress (ALLOWED)
    test_egress "Frontend (tier=frontend)" "probe-eg-fe-be" "app=shop,tier=frontend" "backend:80" "timeout 3 wget -q -O- --timeout=3 http://backend" "ALLOWED"

    # 3. Frontend -> DB Egress (BLOCKED by both Ingress and Egress policy)
    test_egress "Frontend (tier=frontend)" "probe-eg-fe-db" "app=shop,tier=frontend" "db:80" "timeout 3 wget -q -O- --timeout=3 http://db" "BLOCKED"

    # 4. Database -> Outbound (BLOCKED - DB must not initiate any outbound traffic)
    test_egress "Database (tier=db)" "probe-eg-db-out" "app=shop,tier=db" "External / Internet" "timeout 3 wget -q -O- --timeout=3 http://1.1.1.1" "BLOCKED"

    print_and_log_bonus "--------------------------------------------------------------------------------"
    print_and_log_bonus "Summary: ${EGRESS_PASSED}/${EGRESS_TOTAL} egress tests passed."

    echo "======================================================================"
    echo "[SUCCESS] Bonus egress verification saved to:"
    echo "          ${BONUS_FILE}"
    echo "======================================================================"
fi
