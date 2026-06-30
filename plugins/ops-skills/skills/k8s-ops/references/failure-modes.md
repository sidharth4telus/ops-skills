# Kubernetes failure-mode catalog (extended)

Deep reference for `k8s-ops`. Each entry: the exact signature you'll see, the confirming commands,
the root cause, and the fix. Use this when SKILL.md's decision tree narrows you to a case and you
need the long form.

## Container exit codes (the Rosetta stone)

```bash
kubectl get pod <pod> -n <ns> -o jsonpath='{range .status.containerStatuses[*]}{.name}{": exit="}{.lastState.terminated.exitCode}{" reason="}{.lastState.terminated.reason}{" signal="}{.lastState.terminated.signal}{"\n"}{end}'
```

| Exit | Signal | Meaning | Typical cause |
|------|--------|---------|---------------|
| 0    | —      | Clean exit | Process not meant to be long-lived; wrong workload kind |
| 1    | —      | App error | Uncaught exception, bad config |
| 2    | —      | Shell/CLI misuse | Bad flag, malformed args |
| 126  | —      | Cannot execute | Entrypoint not executable / wrong arch |
| 127  | —      | Command not found | Typo in `command`, missing binary in image |
| 128+n| —      | Killed by signal n | See below |
| 130  | SIGINT (2)  | Ctrl-C | Interactive interrupt |
| 137  | SIGKILL (9) | Hard kill | **OOMKilled** (cgroup limit) or liveness kill that ignored SIGTERM |
| 139  | SIGSEGV (11)| Segfault | Native crash, corrupt lib, arch mismatch |
| 143  | SIGTERM (15)| Graceful kill | Pod terminated; app didn't exit 0 on SIGTERM |

`128 + signal_number` is the rule: 137 = 128 + 9, 143 = 128 + 15, 139 = 128 + 11.

## CrashLoopBackOff — full diagnostic transcript

```bash
$ kubectl get pod api-7d9 -n prod
NAME      READY   STATUS             RESTARTS      AGE
api-7d9   0/1     CrashLoopBackOff   5 (40s ago)   3m

$ kubectl logs api-7d9 -n prod --previous
Error: connect ECONNREFUSED 10.0.0.5:5432   # ← DB unreachable at startup

$ kubectl get pod api-7d9 -n prod -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'
1
```

Decision branches:
1. **exitCode 1/2 + clear app error in `--previous`** → fix config/dependency. Check that the
   dependency (DB, cache, downstream) is reachable: `kubectl exec` + `nc -zv host port`.
2. **exitCode 0** → the workload finished. Should be a `Job`, not a `Deployment`; or the entrypoint
   forks to background and the foreground process exits.
3. **No logs at all, exitCode 127/126** → entrypoint/command broken. `kubectl get pod -o yaml` and
   inspect `spec.containers[].command/args`; run the image manually to find the real entrypoint.
4. **exitCode 137 with `reason: OOMKilled`** → memory limit too low (see OOM section).
5. **exitCode 143 shortly after start, on a loop** → liveness probe killing a slow starter. Add a
   `startupProbe`.

## ImagePullBackOff — registry matrix

```bash
$ kubectl describe pod web-x -n prod | grep -A2 Failed
  Warning  Failed  kubelet  Failed to pull image "ghcr.io/org/web:v9": rpc error: code = NotFound
           desc = failed to pull and unpack image ... not found
```

| Substring in the error | Cause | Fix |
|------------------------|-------|-----|
| `not found` / `manifest unknown` | Tag/digest doesn't exist | `crane manifest <img>:<tag>` or `docker manifest inspect`; correct the tag |
| `unauthorized` / `denied` | Auth | `imagePullSecrets` (docker-registry secret) in the **pod's** namespace |
| `toomanyrequests` | Docker Hub rate limit | Authenticate, or mirror to a private registry |
| `i/o timeout` / `connection refused` | Network egress | Node can't reach the registry — NAT/firewall/proxy |
| `x509` / `certificate` | TLS trust | Add registry CA to the node container runtime |
| `no match for platform` | Arch mismatch | Build/pull the node's arch; use a manifest list |

Verify the secret is well-formed:
```bash
kubectl get secret regcred -n prod -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

## OOMKilled — confirm and right-size

```bash
kubectl get pod <pod> -n <ns> -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}'  # OOMKilled
kubectl top pod <pod> -n <ns> --containers     # current usage
# historical peak (if you have Prometheus):
#   container_memory_working_set_bytes{pod="<pod>"} → max over the pod's lifetime
```

Right-sizing rules:
- `requests.memory` = steady-state working set. `limits.memory` = peak + ~20% headroom.
- `requests.memory == limits.memory` → **Guaranteed** QoS class — last to be evicted under node pressure.
- Runtimes that don't auto-detect cgroup limits: set heap explicitly.
  - JVM: `-XX:+UseContainerSupport` (default on modern JDKs) + `-XX:MaxRAMPercentage=75.0`.
  - Node.js: `--max-old-space-size=<MB ≈ 0.75 × limitMB>`.
  - Go: usually fine; watch `GOMEMLIMIT` for soft limits.

## Pending / FailedScheduling — the scheduler's reasons verbatim

```bash
kubectl get events -n <ns> --field-selector reason=FailedScheduling --sort-by=.lastTimestamp
```

| Reason string | Meaning |
|---------------|---------|
| `N Insufficient cpu` / `Insufficient memory` | No node satisfies requests |
| `N node(s) had untolerated taint {k=v:NoSchedule}` | Need a toleration |
| `N node(s) didn't match Pod's node affinity/selector` | Labels/affinity don't match |
| `N node(s) didn't match pod topology spread constraints` | Spread can't be satisfied |
| `N node(s) had volume node affinity conflict` | PV zone ≠ schedulable node zone |
| `pod has unbound immediate PersistentVolumeClaims` | PVC not Bound |
| `N node(s) were unschedulable` | Cordoned nodes |
| `N Too many pods` | Node `maxPods` reached (common on small EKS instance types) |

```bash
# Capacity vs allocation per node:
kubectl describe node <node> | sed -n '/Allocated resources/,/Events/p'
kubectl get nodes -o custom-columns='NODE:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory'
```

## Probes — flapping diagnosis

```bash
kubectl get events -n <ns> --field-selector involvedObject.name=<pod> | grep -i probe
```
- Liveness failures restart the container (`RESTARTS` climbs while logs look healthy).
- Readiness failures only pull the pod out of Service endpoints (`READY 0/1`, but no restart).
- If both fail at boot on a JVM/migration-heavy app: add a `startupProbe`. While it runs, liveness
  and readiness are **suspended**, so a slow boot won't trigger a kill.
- App binding `127.0.0.1` instead of `0.0.0.0` → probe from the kubelet (pod IP) fails even though
  `curl localhost` inside the container works. Fix the bind address.

## Service / endpoints — selector algebra

```bash
SEL=$(kubectl get svc <svc> -n <ns> -o jsonpath='{.spec.selector}')
echo "$SEL"
kubectl get pods -n <ns> -l "$(echo "$SEL" | jq -r 'to_entries|map("\(.key)=\(.value)")|join(",")')"
kubectl get endpointslices -n <ns> -l kubernetes.io/service-name=<svc> -o yaml
```
- Empty endpoints + matching pods that are `Ready` → `targetPort`/`port` mismatch.
- Endpoints contain only `notReadyAddresses` → readiness failing.
- `headless` Service (`clusterIP: None`) returns pod IPs directly; verify the client expects that.

## CoreDNS deep dive

```bash
kubectl -n kube-system get configmap coredns -o yaml      # inspect Corefile / forward block
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=100 | grep -i 'error\|SERVFAIL\|timeout'
```
- `plugin/errors` lines with `SERVFAIL` → upstream resolver unreachable from CoreDNS pods.
- High latency / intermittent NXDOMAIN → `ndots:5` causes search-domain expansion; use FQDN with a
  trailing dot (`db.prod.svc.cluster.local.`) or set `dnsConfig.options: [{name: ndots, value: "2"}]`.
- After scaling nodes, conntrack races on UDP can drop DNS; consider NodeLocal DNSCache.

## Ingress — controller-side confirmation

```bash
kubectl get ingressclass
kubectl -n <ingress-ns> logs deploy/ingress-nginx-controller --tail=200 | grep <host>
```
- 404 with no log entry for the host → the controller never reconciled it (missing/wrong
  `ingressClassName`, or annotation-based class on a controller that wants the field).
- 502 → backend spoke a different protocol; check `nginx.ingress.kubernetes.io/backend-protocol`.
- 503 → backend Service has zero ready endpoints (cascade from probe/selector issues).

## RBAC — explain & grant

```bash
kubectl auth can-i --list --as=system:serviceaccount:<ns>:<sa> -n <ns>     # full matrix for the SA
kubectl auth can-i create deployments.apps -n <ns> --as=system:serviceaccount:<ns>:<sa>
```
Parse the Forbidden error into `<verb> <resource>.<apiGroup>` and grant exactly that. Remember
subresources (`pods/log`, `pods/exec`, `pods/portforward`) and that `apps`, `batch`,
`networking.k8s.io`, `rbac.authorization.k8s.io` are distinct API groups from core (`""`).

## PVC & PV lifecycle

```bash
kubectl get pvc <pvc> -n <ns> -o jsonpath='{.status.phase}'        # Pending|Bound|Lost
kubectl get pv | grep <pvc>
kubectl get storageclass -o custom-columns='NAME:.metadata.name,PROVISIONER:.provisioner,BINDINGMODE:.volumeBindingMode,DEFAULT:.metadata.annotations.storageclass\.kubernetes\.io/is-default-class'
```
- `WaitForFirstConsumer` binding mode is normal-pending until a consuming pod is scheduled.
- Stuck `Terminating`: a pod still mounts it (`kubectl get pods -o json | jq '... volumes'`), or a
  finalizer hangs. Delete/relocate the consumer first; patch finalizers only as a last resort after
  confirming no data loss.

## Node conditions

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,READY:.status.conditions[-1].type,REASON:.status.conditions[-1].reason'
kubectl describe node <node> | sed -n '/Conditions/,/Addresses/p'
```
- `DiskPressure` → image/log GC: `crictl rmi --prune`, rotate logs, grow disk.
- `NotReady` for one node only → kubelet/runtime on that node; SSH and `journalctl -u kubelet`.
- Many nodes `NotReady` at once → control-plane/CNI/network — check API server reachability and CNI pods.
