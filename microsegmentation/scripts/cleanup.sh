#!/usr/bin/env bash
# ==============================================================================
# Script: cleanup.sh
# Purpose: Clean up all resources created for the Microsegmentation lab.
#          Ensures cluster is returned to a clean baseline state.
# ==============================================================================

set -euo pipefail

echo "======================================================================"
echo "[CLEANUP] Removing Microsegmentation Lab Resources"
echo "======================================================================"

if kubectl get ns shop >/dev/null 2>&1; then
    echo "[+] Deleting namespace 'shop' (all pods, services, and network policies)..."
    kubectl delete ns shop --timeout=60s
    echo "[+] Namespace 'shop' successfully removed."
else
    echo "[+] Namespace 'shop' does not exist. Nothing to clean."
fi

echo "======================================================================"
echo "[CLEANUP] Complete."
echo "======================================================================"
