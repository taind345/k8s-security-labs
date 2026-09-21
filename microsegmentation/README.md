# Kubernetes Microsegmentation Lab (3-Tier App)

## 1. Goal
Demonstrate practical Zero-Trust Network Microsegmentation in Kubernetes by proving that an attacker who compromises an internet-facing `frontend` container cannot move laterally to access the internal `db` (database) tier directly.

---

## 2. Architecture & Traffic Flow

```text
       [ External Client / Test Probe ]
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

  [BLOCKED FLOWS - Zero Trust Boundary]:
  ❌ Frontend  ────── (Direct HTTP 80) ────► DB       (BLOCKED by NetworkPolicy)
  ❌ Rogue Pod ────── (Direct HTTP 80) ────► Backend  (BLOCKED by default-deny)
  ❌ Rogue Pod ────── (Direct HTTP 80) ────► DB       (BLOCKED by default-deny)
  ❌ DB Tier   ────── (Outbound/Egress) ───► Internet (BLOCKED by egress policy)
```

---

## 3. Threat Model
- **Vulnerability Scenario**: In standard Kubernetes without NetworkPolicies, pod-to-pod networking is completely flat. Any container in any namespace can reach any port on any other container by default.
- **Attack Scenario**: An external adversary compromises the `frontend` pod (e.g., through an application vulnerability such as SSRF, SQLi, or command injection). From that compromised container, the attacker runs network probes (`wget`, `curl`, `nc`) to query `http://db` directly, bypassing the `backend` authentication logic and dumping records.
- **Remediation**: Implement declarative Kubernetes `NetworkPolicy` objects enforced by the **Calico CNI** data-plane at the Linux kernel level (iptables/eBPF), establishing an ingress and egress whitelist (least-privilege model).

---

## 4. Prerequisites
- **OS**: Fedora Linux (bare metal, SELinux Enforcing, firewalld active).
- **Cluster**: Minikube with Docker driver, Calico CNI, and 2 worker nodes:
  ```bash
  minikube start --driver=docker --cni=calico --nodes=2
  ```
- **Tools**: `kubectl`, `docker`.
- **Pinned Container Images**:
  - `nginx:1.27.4-alpine` (Application tiers)
  - `busybox:1.37.0` (Testing probe pods)

---

## 5. How to Run and Reproduce

All commands are idempotent and adhere to `set -euo pipefail`.

### Step 1: Deploy App and Record Phase A Baseline (Before Policy)
```bash
./scripts/setup.sh
```
*What it does*:
1. Deploys namespace `shop` with 3 tiers: `frontend`, `backend`, and `db`.
2. Waits for all deployments to reach `Available` status.
3. Tests direct connection from `frontend` to `http://db`.
4. Saves the real command output to `results/01-before.txt`, confirming that the flat network allows lateral movement before policies are installed.

### Step 2: Enforce Microsegmentation & Run Verification Matrix (Phase B & C)
```bash
./scripts/verify.sh
```
*What it does*:
1. Applies `manifests/policies.yaml` (default-deny ingress + whitelisted tier communication).
2. Spawns short-lived BusyBox probe pods with distinct labels and a 3-second connection timeout.
3. Evaluates actual traffic results against expected access rules.
4. Directly verifies connection timeout from the running `frontend` container to `db`.
5. Saves the resulting PASS/FAIL matrix to `results/02-after.txt`.

### Step 3: (Bonus) Test Egress Filtering & CoreDNS Resolution
```bash
./scripts/verify.sh --bonus-egress
```
*What it does*:
1. Applies `manifests/egress-bonus.yaml` (default-deny egress for `shop`).
2. Whitelists CoreDNS (UDP/TCP port 53 to namespace `kube-system`).
3. Whitelists egress from `frontend` -> `backend` and `backend` -> `db`.
4. Verifies that the `db` pod cannot initiate outbound connections to the internet.
5. Saves results to `results/03-bonus-egress.txt`.

### Step 4: Cleanup
```bash
./scripts/cleanup.sh
```
*What it does*: Deletes namespace `shop` and all associated policies and services.

---

## 6. Real Verification Results

### A. Phase A: Before Policy Enforcement (`results/01-before.txt`)
Direct HTTP request from `frontend` pod to `http://db`:
```text
Connecting to db (10.101.121.17:80)
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
RESULT: VULNERABLE TO LATERAL MOVEMENT (HTTP 200 OK received from database)
```

### B. Phase C: Automated Verification Matrix (`results/02-after.txt`)
```text
| Source Tier / Pod       | Destination Service | Expected | Actual  | Status |
|-------------------------|---------------------|----------|---------|--------|
| Client (unlabeled)      | frontend:80         | ALLOWED  | ALLOWED | PASS   |
| Frontend (tier=frontend)| backend:80          | ALLOWED  | ALLOWED | PASS   |
| Backend (tier=backend)  | db:80               | ALLOWED  | ALLOWED | PASS   |
| Frontend (tier=frontend)| db:80               | BLOCKED  | BLOCKED | PASS   |
| Rogue (role=attacker)   | backend:80          | BLOCKED  | BLOCKED | PASS   |
| Rogue (role=attacker)   | db:80               | BLOCKED  | BLOCKED | PASS   |

Summary: 6/6 tests passed.

Direct verification from running deployment/frontend to db:
Command: kubectl exec -n shop deploy/frontend -- timeout 3 wget -q -O- --timeout=3 http://db
[+] Verified: Connection timed out as expected (exit code 143/non-zero).
[+] Lateral movement from Frontend to Database is successfully BLOCKED!
```

### C. Bonus: Egress Policy Verification (`results/03-bonus-egress.txt`)
```text
| Source Tier / Pod       | Destination / Protocol  | Expected | Actual  | Status |
|-------------------------|-------------------------|----------|---------|--------|
| Frontend (tier=frontend)| CoreDNS (UDP 53)        | ALLOWED  | ALLOWED | PASS   |
| Frontend (tier=frontend)| backend:80              | ALLOWED  | ALLOWED | PASS   |
| Frontend (tier=frontend)| db:80                   | BLOCKED  | BLOCKED | PASS   |
| Database (tier=db)      | External / Internet     | BLOCKED  | BLOCKED | PASS   |

Summary: 4/4 egress tests passed.
```

---

## 7. Lessons Learned & Technical Takeaways

1. **CNI Enforcement Requirement**:
   Kubernetes standard API defines `NetworkPolicy` objects, but the default `kubenet` or simple bridge CNI ignores them completely without returning errors. An active NetworkPolicy controller (such as Calico, Cilium, or Antrea) is required to translate policy objects into host Linux kernel rules (iptables chains or eBPF maps).
2. **The Default-Deny Egress DNS Trap**:
   Enforcing `default-deny-egress` blocks ALL outbound packets, including Kubernetes internal DNS queries to `10.96.0.10:53`. Without an explicit egress rule allowing UDP/TCP port 53 to namespace `kube-system`, pods can no longer resolve service hostnames like `backend.shop.svc.cluster.local`, causing application outages.
3. **Defense in Depth Beyond Microsegmentation**:
   NetworkPolicies protect Layer 3/4 (IP and Port). They do not inspect Layer 7 payload data (e.g., malicious SQL injection within allowed HTTP traffic). True Zero Trust requires combining Network Microsegmentation with Layer 7 controls (API gateways, mTLS via Service Mesh) and upstream content inspection (CDR/RBI).

---

## 8. Interview Q&A (Cybersecurity Intern Focus)

### Q1: How does Kubernetes NetworkPolicy differ from traditional perimeter firewalls?
> **Answer**: Traditional firewalls guard the perimeter (North-South traffic at the edge IP/subnet level). In contrast, Kubernetes NetworkPolicies enforce microsegmentation *inside* the perimeter (East-West traffic between individual pods). Because pods are ephemeral and dynamically assigned internal IPs, NetworkPolicies rely on cryptographic/declarative metadata labels (`matchLabels`) rather than static IP addresses.

### Q2: Why is Calico needed in Minikube, and what happens if you apply a NetworkPolicy on a standard cluster without Calico?
> **Answer**: Kubernetes API server will gladly store and validate `NetworkPolicy` resources even if no network policy controller is installed. However, without a CNI plugin like Calico or Cilium running on the nodes to read those objects and program kernel packet-filtering rules (via iptables or eBPF), the policies have zero effect. Traffic remains wide open, creating a dangerous false sense of security.

### Q3: What happens when you apply a `default-deny-egress` policy without allowing DNS, and how do you fix it?
> **Answer**: All outbound traffic from matched pods is immediately dropped. When a container tries to reach `http://backend`, its resolver attempts to query CoreDNS on port 53 in `kube-system`. Because egress is blocked, the DNS lookup times out before any TCP handshake can even begin. To fix it, you must explicitly create an egress rule permitting UDP and TCP traffic on port 53 to pods in `kube-system` matching the `k8s-app: kube-dns` label.

### Q4: If an attacker gets Remote Code Execution (RCE) on the frontend pod, how does microsegmentation change the blast radius?
> **Answer**: Without microsegmentation, the attacker can use the frontend container as a staging ground to scan the internal network, connect directly to the database on port 80/3306/5432, or call internal administrative APIs. With microsegmentation, the blast radius is strictly confined to the frontend: the kernel drops any packet sent from frontend to the database. The attacker is blocked from lateral movement and cannot establish outbound C2 connections to exfiltrate data.

### Q5: How does network microsegmentation complement solutions like CDR (Content Disarm & Reconstruction) and RBI (Remote Browser Isolation)?
> **Answer**: They form a layered defense-in-depth model across the kill chain:
> 1. **RBI** insulates users from malicious web code by executing browser sessions in an isolated disposable sandbox.
> 2. **CDR** sanitizes inbound documents and attachments before they enter corporate infrastructure by stripping zero-day exploits and executable macros.
> 3. **Microsegmentation** provides post-compromise containment: if an unknown exploit slips past the boundary controls and compromises an internal workload, microsegmentation prevents that workload from moving laterally to sensitive database or management tiers.
