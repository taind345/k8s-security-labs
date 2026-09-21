# Kubernetes Network Microsegmentation Lab

A practical lab demonstrating zero-trust network isolation for a 3-tier application (`frontend`, `backend`, `db`) running on Kubernetes with **Calico CNI**.

The goal is simple: prove that even if the internet-facing `frontend` is compromised, network policies prevent it from reaching the `db` directly.

---

## Architecture & Traffic Flow

```text
  [ Client ] ──(HTTP 80)──► [ frontend ] ──(HTTP 80)──► [ backend ] ──(HTTP 80)──► [ db ]
                                │
                                └───❌ (Direct HTTP 80 BLOCKED)───────────────────► [ db ]
```

| Source | Destination | Expected | Policy Enforced |
|---|---|---|---|
| Client | `frontend:80` | ALLOWED | `allow-frontend-ingress` |
| `frontend` | `backend:80` | ALLOWED | `allow-frontend-to-backend` |
| `backend` | `db:80` | ALLOWED | `allow-backend-to-db` |
| **`frontend`** | **`db:80`** | **BLOCKED** | **`default-deny-ingress`** |
| Rogue / Unlabeled Pod | `backend:80` | BLOCKED | `default-deny-ingress` |
| Rogue / Unlabeled Pod | `db:80` | BLOCKED | `default-deny-ingress` |

---

## Project Structure

```text
.
├── README.md
└── microsegmentation/
    ├── manifests/
    │   ├── app.yaml              # 3 deployments + clusterIP services
    │   ├── policies.yaml         # Ingress network policies (default-deny + tier rules)
    │   └── egress-bonus.yaml     # Optional: default-deny egress + CoreDNS whitelist
    ├── scripts/
    │   ├── setup.sh              # Deploys app and logs baseline before policy
    │   ├── verify.sh             # Applies policies and runs automated test matrix
    │   └── cleanup.sh            # Deletes the shop namespace
    └── results/
        ├── 01-before.txt         # Raw output showing frontend -> db succeeds
        ├── 02-after.txt          # Raw output showing 6/6 test matrix passed
        └── 03-bonus-egress.txt   # Raw output showing egress & DNS test results
```

---

## Quickstart

### Prerequisites
- Linux host with Docker, `kubectl`, and `minikube` installed.
- Minikube started with Calico (required to enforce `NetworkPolicy`):
  ```bash
  minikube start --driver=docker --cni=calico --nodes=2
  ```

### 1. Deploy App & Check Baseline
```bash
cd microsegmentation/scripts
./setup.sh
```
Deploys the 3 tiers into namespace `shop`. Shows that on a default cluster, `frontend` can query `db` directly (HTTP 200). Output is saved to `results/01-before.txt`.

### 2. Apply Policies & Verify
```bash
./verify.sh
```
Applies `policies.yaml` and spins up ephemeral BusyBox pods to test all traffic paths with a 3-second timeout. Output is saved to `results/02-after.txt`.

### 3. (Optional) Test Egress Filtering
```bash
./verify.sh --bonus-egress
```
Applies `egress-bonus.yaml` to enforce default-deny egress, whitelisting only CoreDNS (UDP/TCP 53) and required tier-to-tier traffic. Output is saved to `results/03-bonus-egress.txt`.

### 4. Cleanup
```bash
./cleanup.sh
```

---

## Real Test Results

### Before Policy (`01-before.txt`)
```text
kubectl exec -n shop deploy/frontend -- wget -q -O- --timeout=3 http://db
HTTP/1.1 200 OK
<title>Welcome to nginx!</title>
...
RESULT: VULNERABLE TO LATERAL MOVEMENT
```

### After Policy (`02-after.txt`)
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
```

---

## Technical Notes & Interview FAQ

### 1. How do NetworkPolicies differ from traditional firewalls?
Traditional firewalls sit at network perimeters and filter by static IP/CIDR and ports (North-South). In Kubernetes, pods are ephemeral and IPs change constantly. NetworkPolicies enforce microsegmentation *inside* the cluster (East-West) using declarative label selectors (`matchLabels: tier=backend`) at the pod veth interface.

### 2. Why is Calico needed in Minikube?
The Kubernetes API accepts and stores `NetworkPolicy` objects regardless of CNI. However, the default basic CNI does not implement a network policy controller. Without a CNI like Calico or Cilium, policies are silently ignored and traffic remains completely open. Calico reads the policy objects and programs the actual `iptables` or `eBPF` rules in the Linux kernel on each node.

### 3. What happens if you apply default-deny egress without allowing DNS?
Everything breaks. In Kubernetes, service discovery relies on CoreDNS running in `kube-system` on port 53. If you drop all egress, pods can no longer resolve names like `backend.shop.svc.cluster.local`. Egress policies must explicitly allow UDP/TCP port 53 to `kube-system`.

### 4. What is the blast radius if an attacker gets RCE on the frontend?
Without NetworkPolicy, the attacker can port scan the internal subnet, reach the database directly, or query internal APIs. With microsegmentation, packets from `frontend` to `db` are dropped at the kernel level. The attacker cannot pivot deeper into the database tier or establish reverse shells to unauthorized destinations.

### 5. How does microsegmentation fit into defense-in-depth?
It provides containment:
- **RBI / CDR**: Protects the entry point by neutralizing threats before they hit internal systems.
- **Network Microsegmentation**: Assumes a breach will eventually happen (Zero Trust) and restricts lateral movement so an initial foothold cannot become a full cluster compromise.
