# Kubernetes Zero-Trust Microsegmentation Lab

[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.31+-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Calico](https://img.shields.io/badge/CNI-Calico-FA5B31?logo=calico&logoColor=white)](https://www.tigera.io/project-calico/)
[![Security](https://img.shields.io/badge/Security-Zero%20Trust%20Microsegmentation-green)](#threat-model)

An end-to-end, reproducible DevSecOps security lab demonstrating **Zero-Trust Network Microsegmentation** in Kubernetes using **Calico CNI**.

This project models a 3-tier cloud application (`frontend`, `backend`, `database`) to prove that an attacker who achieves initial access or remote code execution on the public web tier is strictly contained and **cannot move laterally** to internal data services.

---

## 🎯 Lab Objectives

1. **Demonstrate Flat Network Insecurity**: Prove that default Kubernetes networking allows any compromised container to reach any other container across tiers without restriction (Phase A).
2. **Implement Declarative Zero-Trust Ingress**: Apply a `default-deny` ingress baseline and whitelist only strictly necessary East-West flows (Phase B).
3. **Automated Regression Verification**: Execute an automated regression test matrix using ephemeral probe containers with strict timeout constraints to ensure policy enforcement (Phase C).
4. **Enforce DNS-Aware Egress Boundaries**: Implement egress filtering to block unauthorized outbound C2 communication while preserving CoreDNS service discovery.

---

## 🏗️ Architecture & Traffic Matrix

```text
       [ External Client / Ingress Probe ]
                       │
                       ▼ (HTTP 80 - ALLOWED)
             ┌───────────────────┐
             │   tier=frontend   │ (Public Web Tier)
             └─────────┬─────────┘
                       │
                       │ (HTTP 80 - ALLOWED)
                       ▼
             ┌───────────────────┐
             │   tier=backend    │ (Internal API Tier)
             └─────────┬─────────┘
                       │
                       │ (HTTP 80 - ALLOWED)
                       ▼
             ┌───────────────────┐
             │      tier=db      │ (Database Tier)
             └───────────────────┘

  [BLOCKED FLOWS - Zero-Trust Boundary]:
  ❌ Frontend  ────── (Direct HTTP 80) ────► DB       (BLOCKED by NetworkPolicy)
  ❌ Rogue Pod ────── (Direct HTTP 80) ────► Backend  (BLOCKED by default-deny)
  ❌ Rogue Pod ────── (Direct HTTP 80) ────► DB       (BLOCKED by default-deny)
  ❌ DB Tier   ────── (Outbound/Egress) ───► Internet (BLOCKED by egress policy)
```

---

## 📁 Repository Layout

```text
k8s-security-labs/
├── README.md                      # Lab portfolio overview, quickstart, and interview guide
└── microsegmentation/
    ├── manifests/
    │   ├── app.yaml               # 3-tier deployment and services (frontend, backend, db)
    │   ├── policies.yaml          # Ingress NetworkPolicies (Default-Deny + Whitelist)
    │   └── egress-bonus.yaml      # Egress NetworkPolicies + CoreDNS (UDP/TCP 53) Whitelist
    ├── scripts/
    │   ├── setup.sh               # Deploys application and records Phase A baseline
    │   ├── verify.sh              # Applies policies and executes automated test matrix
    │   └── cleanup.sh             # Idempotent teardown of all lab resources
    ├── results/
    │   ├── 01-before.txt          # Real output: Frontend -> DB succeeds before policy
    │   ├── 02-after.txt           # Real output: Automated 6/6 PASS/FAIL Ingress matrix
    │   └── 03-bonus-egress.txt    # Real output: Automated 4/4 PASS/FAIL Egress matrix
    └── README.md                  # Comprehensive deep-dive & 5-question interview prep
```

---

## 💻 Environment & Prerequisites

- **Host OS**: Fedora Linux (Bare metal, dual boot).
  - SELinux: `Enforcing` (`targeted` mode).
  - Firewall: `firewalld` active.
- **Container Runtime**: Docker CE.
- **Cluster**: Minikube with Docker driver and **Calico CNI** across 2 nodes:
  ```bash
  minikube start --driver=docker --cni=calico --nodes=2
  ```
- **CLI Tools**: `kubectl`, `minikube`, `docker`.
- **Pinned Container Images**:
  - `nginx:1.27.4-alpine` (Application workloads)
  - `busybox:1.37.0` (Testing probe pods)

---

## ⚡ Quickstart & Reproduction Guide

All scripts are written with `set -euo pipefail` and are 100% idempotent.

### Step 1: Deploy & Record Baseline (Phase A)
```bash
cd microsegmentation/scripts
./setup.sh
```
*Output*: Deploys namespace `shop`, checks cluster readiness, tests the lateral path `frontend -> db`, and records output to `microsegmentation/results/01-before.txt`.

### Step 2: Enforce Ingress Microsegmentation (Phase B & C)
```bash
./verify.sh
```
*Output*: Enforces `default-deny-ingress` and whitelists tier traffic. Runs ephemeral probe pods with attached streams (`--rm -i`) and records the 6-test verification table to `microsegmentation/results/02-after.txt`.

### Step 3: (Optional Bonus) Enforce Egress Filtering
```bash
./verify.sh --bonus-egress
```
*Output*: Adds default-deny egress filtering, whitelists CoreDNS (port 53 UDP/TCP) and allowed East-West egress, and verifies that the database container cannot communicate outbound. Results are saved to `microsegmentation/results/03-bonus-egress.txt`.

### Step 4: Teardown
```bash
./cleanup.sh
```

---

## 📊 Summary of Verified Results

| Result File | Phase / Focus | Key Finding | Status |
| :--- | :--- | :--- | :--- |
| [`01-before.txt`](./microsegmentation/results/01-before.txt) | **Phase A (Baseline)** | `kubectl exec frontend -- wget http://db` returned HTTP 200 OK. Confirmed vulnerable lateral movement. | **VULNERABLE (Expected)** |
| [`02-after.txt`](./microsegmentation/results/02-after.txt) | **Phase C (Ingress Matrix)** | - Client -> Frontend: `ALLOWED`<br>- Frontend -> Backend: `ALLOWED`<br>- Backend -> DB: `ALLOWED`<br>- **Frontend -> DB: `BLOCKED`**<br>- Rogue -> Backend: `BLOCKED`<br>- Rogue -> DB: `BLOCKED` | **6/6 PASSED** |
| [`03-bonus-egress.txt`](./microsegmentation/results/03-bonus-egress.txt) | **Bonus (Egress Matrix)** | - Frontend -> CoreDNS (UDP 53): `ALLOWED`<br>- Frontend -> Backend: `ALLOWED`<br>- Frontend -> DB: `BLOCKED`<br>- Database -> External Internet: `BLOCKED` | **4/4 PASSED** |

---

## 💼 Interview Talking Points (Cybersecurity Intern)

1. **Why NetworkPolicies Require an Active CNI**:
   Kubernetes API accepts `NetworkPolicy` objects out of the box, but default cloud bridge drivers ignore them. A CNI like Calico is required to translate policies into Linux kernel packet filters (`iptables` chains or `eBPF` maps) on node veth interfaces.
2. **Blast Radius Mitigation**:
   Even if an attacker achieves full root/RCE on a public-facing container, network microsegmentation traps them in place: packets sent to unauthorized internal tiers or outbound C2 servers are dropped at the kernel boundary before leaving the pod.
3. **Synergy with CDR & RBI Solutions**:
   - **RBI (Remote Browser Isolation)** and **CDR (Content Disarm & Reconstruction)** prevent malware from entering the environment at the perimeter/content layer.
   - **Network Microsegmentation** provides the critical zero-trust safety net: if an unknown exploit evades upstream filters, microsegmentation contains the compromise and prevents lateral movement.

For detailed question-and-answer scripts and technical deep-dives, see the [Microsegmentation Project README](./microsegmentation/README.md).
