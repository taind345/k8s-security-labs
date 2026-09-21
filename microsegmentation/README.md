# Microsegmentation Details

Deep-dive documentation for the 3-tier microsegmentation lab.

## Flow & Policy Design

We use a standard 3-tier architecture inside namespace `shop`:
- `frontend` (public web, TCP 80)
- `backend` (internal API, TCP 80)
- `db` (database, TCP 80)

All container images are pinned to `nginx:1.27.4-alpine`.

### Ingress Rules (`manifests/policies.yaml`)

1. **`default-deny-ingress`**: Selects `{}` in namespace `shop`. With an empty ingress rule list, all incoming traffic to all pods in the namespace is dropped by default.
2. **`allow-frontend-ingress`**: Matches `tier: frontend`, opens port 80 to external traffic/clients.
3. **`allow-frontend-to-backend`**: Matches `tier: backend`, allows ingress on port 80 only from pods with `tier: frontend`.
4. **`allow-backend-to-db`**: Matches `tier: db`, allows ingress on port 80 only from pods with `tier: backend`. Frontend and unauthorized pods are blocked.

### Bonus Egress Rules (`manifests/egress-bonus.yaml`)

1. **`default-deny-egress`**: Selects `{}` in namespace `shop`. Drops all outbound packets by default.
2. **`allow-dns-egress`**: Selects `{}`, allows UDP & TCP on port 53 to namespace `kube-system`. Without this rule, pods cannot resolve internal Kubernetes Service names via CoreDNS.
3. **`allow-frontend-egress-to-backend`**: Matches `tier: frontend`, allows outbound TCP 80 to `tier: backend`.
4. **`allow-backend-egress-to-db`**: Matches `tier: backend`, allows outbound TCP 80 to `tier: db`.
5. The `db` tier has no outbound rules, preventing it from initiating any connections (stops reverse shells and data exfiltration).

---

## Test Automation (`scripts/verify.sh`)

Testing network policies requires running commands with the right pod labels. Instead of relying on manual `kubectl exec`, `verify.sh` automates this using ephemeral BusyBox pods (`busybox:1.37.0`):

```bash
kubectl run probe --rm -i --restart=Never \
  --namespace=shop \
  --image=busybox:1.37.0 \
  --labels="tier=frontend" \
  --command -- timeout 3 wget -q -O- --timeout=3 http://backend
```

Using `--rm -i` attaches to the container stdout/stderr, allowing the script to evaluate the real exit code of the probe:
- Exit code `0` = connection succeeded.
- Exit code non-zero (timed out after 3s) = connection blocked by kernel policy.

---

## Technical Lessons Learned

1. **CNI Enforcement**: Kubernetes stores NetworkPolicy resources, but Calico does the actual filtering by generating iptables/eBPF rules on the host node's virtual ethernet interfaces.
2. **DNS in Egress Policies**: Applying `default-deny-egress` without whitelisting CoreDNS breaks all hostname resolution. The cluster will appear completely down for application pods even if the target service is alive.
3. **Interactive Probe Attachment**: When scripting automated network tests with `kubectl run`, omitting `-i` causes `kubectl` to return exit code 0 as soon as the API creates the pod object, giving false positive "ALLOWED" results. Attached streaming (`-i`) is needed to capture the actual network return code.
