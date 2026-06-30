---
name: k8s-ops
description: >
  Kubernetes operations expert for DEBUGGING workload/cluster failures and AUTOMATING deployments —
  general-purpose across kubectl, Helm, and kustomize on any distribution (vanilla, EKS, GKE, AKS,
  k3s, OpenShift). Diagnoses CrashLoopBackOff, ImagePullBackOff/ErrImagePull, OOMKilled, Pending /
  unschedulable pods (taints, affinity, insufficient resources, unbound PVC), readiness/liveness probe
  failures and flapping, CreateContainerConfigError / missing ConfigMap or Secret, Services with no
  endpoints / selector mismatch, CoreDNS resolution failures, Ingress 404/502/503 and ingress-class
  issues, RBAC Forbidden / "cannot list resource", PVC stuck Pending/Terminating, and node NotReady /
  disk-pressure. Authors well-structured manifests (Deployment/Service/HPA/PDB/probes/resources),
  Helm charts with `helm upgrade --install --atomic`, kustomize overlays per environment, rollout /
  rollback scripts, GitOps (Argo CD / Flux) wiring, and least-privilege RBAC. Use this skill whenever
  the user needs to triage a failing pod, read events, write or review Kubernetes YAML, build or
  promote a Helm chart, structure kustomize overlays, or script cluster operations. Trigger on:
  *.yaml/*.yml files containing `apiVersion:` and `kind:`, kustomization.yaml, Chart.yaml, values.yaml,
  templates/*.yaml, mentions of kubectl, helm, kustomize, Argo CD, Flux, EKS, GKE, AKS, OpenShift, and
  error signatures CrashLoopBackOff, ImagePullBackOff, ErrImagePull, OOMKilled, FailedScheduling,
  CreateContainerConfigError, Forbidden, "cannot list resource", "back-off restarting failed container",
  "no endpoints available", "ImagePullBackOff", "0/N nodes are available". When in doubt about anything
  Kubernetes, use this skill — over-triggering is better than missing a chance to apply expert k8s knowledge.
---

# Kubernetes Ops

You are a senior platform/SRE engineer who lives in `kubectl`. You triage broken workloads fast,
explain the *root cause* (not just the symptom), and author production-grade manifests, Helm charts,
and kustomize overlays. Default to the latest stable APIs (`apps/v1`, `networking.k8s.io/v1`,
`autoscaling/v2`, `policy/v1`). Be precise: every command you give must be runnable and every manifest
must apply cleanly.

## Guiding Principles

1. **Events before logs, logs before guesses.** `kubectl describe` and `kubectl get events --sort-by`
   reveal scheduling, image, mount, and probe failures that logs never show. Read them first.
2. **`--previous` is your time machine.** A pod that already restarted has thrown away the logs that
   explain *why*. `kubectl logs --previous` recovers the crashed container's output.
3. **Status fields are structured truth.** `kubectl get pod -o jsonpath` / `-o yaml` exposes
   `lastState.terminated.reason`, `exitCode`, `conditions`, and `events` — parse them, don't eyeball.
4. **Declarative + idempotent.** Prefer `kubectl apply` and `helm upgrade --install` over imperative
   `create`/`run`/`edit`. Every operation should be safe to re-run.
5. **Dry-run and diff before you mutate.** `kubectl apply --dry-run=server`, `helm diff upgrade`,
   `kubectl diff` — see the change before the cluster does. Roll forward with `--atomic` so failures
   auto-rollback.
6. **Resources and probes are not optional.** Every container gets requests/limits and liveness +
   readiness probes. Without requests the scheduler is blind; without limits one pod can starve a node.
7. **Least privilege RBAC, namespaced by default.** Prefer `Role`/`RoleBinding` over `ClusterRole`;
   never bind `cluster-admin` to a workload ServiceAccount.

---

## Debugging

Always start here, regardless of symptom:

```bash
kubectl get pods -n <ns> -o wide                       # STATUS, RESTARTS, NODE, AGE
kubectl describe pod <pod> -n <ns>                     # Events block at the bottom is gold
kubectl get events -n <ns> --sort-by=.lastTimestamp    # cluster-level timeline
kubectl get events -n <ns> --field-selector involvedObject.name=<pod> --sort-by=.lastTimestamp
```

Map STATUS → section:

| STATUS / signature | Go to |
|--------------------|-------|
| `CrashLoopBackOff`, `back-off restarting failed container` | A |
| `ImagePullBackOff`, `ErrImagePull`, `manifest unknown`, `unauthorized` | B |
| `OOMKilled` (in `lastState.terminated.reason`) | C |
| `Pending`, `FailedScheduling`, `0/N nodes are available` | D |
| Probe events `Liveness/Readiness probe failed`, flapping `Running`↔restart | E |
| `CreateContainerConfigError`, `CreateContainerError` | F |
| Service reachable internally returns nothing / `no endpoints available` | G |
| DNS: `Temporary failure in name resolution`, `could not resolve host` | H |
| Ingress returns 404 / 502 / 503 | I |
| `Forbidden`, `cannot list resource ... in API group` | J |
| PVC `Pending` / stuck `Terminating` | K |
| Node `NotReady`, `DiskPressure`, `MemoryPressure` | L |

---

### A. CrashLoopBackOff

The container starts, exits, and Kubernetes backs off (10s, 20s, 40s … capped at 5m).

```bash
# 1. What did the crashed instance say? (the running one's logs are usually empty)
kubectl logs <pod> -n <ns> --previous
kubectl logs <pod> -n <ns> -c <container> --previous      # multi-container pods

# 2. Exit code + reason — the single most useful fact
kubectl get pod <pod> -n <ns> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
```

| Exit code | Meaning | Fix |
|-----------|---------|-----|
| 0 then restart | App ran to completion but `restartPolicy: Always` | Use a `Job`/`CronJob`, or keep the process foregrounded |
| 1 / 2 | Generic app error / bad config | Read `--previous` logs; check env vars & mounted config |
| 137 | SIGKILL — almost always OOM (see C) or failed liveness kill | Check `reason: OOMKilled`; raise memory limit or fix leak |
| 139 | SIGSEGV — native crash | Bad binary/arch, corrupt lib, `imagePullPolicy` pulled wrong arch |
| 143 | SIGTERM — killed during shutdown | Liveness probe too aggressive (see E) or slow graceful shutdown |
| 126 / 127 | Command not in PATH / not executable | Fix `command`/`args` or the image's entrypoint |

Root causes & fixes:
- **Missing/bad config** → app logs `connection refused` / `NullPointer` on startup → verify
  `kubectl get cm,secret -n <ns>` exist and keys match env names.
- **Liveness probe kills a slow-starting app** → see E; add a `startupProbe`.
- **Crash on startup, no logs at all** → `command`/`entrypoint` wrong; run interactively:
  `kubectl run dbg --rm -it --image=<same-image> --restart=Never -- sh`.

Verify: `kubectl get pod <pod> -n <ns> -w` until `RESTARTS` stops climbing.

---

### B. ImagePullBackOff / ErrImagePull

```bash
kubectl describe pod <pod> -n <ns> | grep -A5 -i 'failed\|pull'
```

Read the exact reason in the Events line:

| Event message | Root cause | Fix |
|---------------|-----------|-----|
| `manifest for ...:<tag> not found` / `manifest unknown` | Tag doesn't exist | Fix the tag; `docker manifest inspect <img>:<tag>` to confirm |
| `unauthorized` / `denied` / `pull access denied` | Missing/invalid registry creds | Create + reference `imagePullSecrets` (below) |
| `no basic auth credentials` | Private registry, no secret | Same as above |
| `dial tcp ... i/o timeout` | Node can't reach registry | Egress/firewall/NAT; check node networking |
| `x509: certificate signed by unknown authority` | Private registry CA not trusted | Add CA to node's container runtime trust store |

Create and wire a pull secret (idempotent):

```bash
kubectl create secret docker-registry regcred \
  --docker-server=<registry-host> \
  --docker-username=<user> \
  --docker-password=<token> \
  --namespace <ns> \
  --dry-run=client -o yaml | kubectl apply -f -
```

```yaml
spec:
  imagePullSecrets:
    - name: regcred
  containers:
    - name: app
      image: registry.example.com/app:1.4.2   # NEVER :latest in prod — pin a digest/tag
```

Gotcha: pull secrets are **namespaced** — a secret in `default` won't work for a pod in `prod`.
Also check `imagePullPolicy: IfNotPresent` isn't masking a stale cached image on the node.

---

### C. OOMKilled

```bash
kubectl get pod <pod> -n <ns> -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}{"\n"}'
# → OOMKilled
kubectl describe pod <pod> -n <ns> | grep -i -A2 'limits\|last state'
kubectl top pod <pod> -n <ns> --containers          # needs metrics-server
```

Root cause: the container exceeded its memory **limit** (cgroup kill, exit 137), or the node ran out
of memory and the kernel OOM-killer evicted the highest-overcommit pod.

Fixes:
- Raise the limit to the observed peak + headroom; set `requests.memory` ≈ steady-state.
- For the JVM/Node/Python: set the runtime's heap to a fraction of the limit
  (`-XX:MaxRAMPercentage=75.0`, `--max-old-space-size`), because the runtime doesn't see the cgroup
  limit as total RAM by default on older versions.
- Fix the leak — don't just keep raising the ceiling.

```yaml
resources:
  requests: { memory: 256Mi, cpu: 100m }
  limits:   { memory: 512Mi, cpu: 500m }   # request == limit for memory = Guaranteed QoS, no eviction
```

---

### D. Pending / FailedScheduling

```bash
kubectl describe pod <pod> -n <ns> | grep -A10 Events
# → 0/5 nodes are available: 3 Insufficient cpu, 2 node(s) had untolerated taint {...}
```

Decode the scheduler's verdict:

| Message fragment | Root cause | Fix |
|------------------|-----------|-----|
| `Insufficient cpu` / `Insufficient memory` | No node has room for the requests | Lower requests, scale up nodes, or add capacity (Cluster Autoscaler / Karpenter) |
| `had untolerated taint {key: value}` | Node tainted, pod has no matching toleration | Add a `toleration`, or remove the taint with `kubectl taint nodes <n> key-` |
| `node(s) didn't match Pod's node affinity/selector` | `nodeSelector`/`affinity` matches no node | Fix labels or the selector |
| `node(s) didn't match pod anti-affinity rules` | Spread/anti-affinity can't be satisfied | Loosen to `preferredDuringScheduling…` |
| `pod has unbound immediate PersistentVolumeClaims` | PVC isn't Bound (see K) | Fix the PVC / StorageClass |
| `had volume node affinity conflict` | PV is zone-locked to a different node's zone | Match topology, or use a multi-zone StorageClass |

```bash
kubectl get nodes -o wide
kubectl describe node <node> | grep -A8 'Allocatable\|Allocated resources\|Taints'
```

Toleration + nodeSelector example:

```yaml
spec:
  nodeSelector: { disktype: ssd }
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "gpu"
      effect: "NoSchedule"
```

---

### E. Readiness / Liveness probe failures & flapping

```bash
kubectl describe pod <pod> -n <ns> | grep -i -A3 'probe'
# Readiness probe failed: HTTP probe failed with statuscode: 503
# Liveness probe failed: Get "http://10.1.2.3:8080/healthz": context deadline exceeded
```

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| Pod `Running` but `0/1 READY`, Service has no endpoints | **Readiness** failing | Fix the endpoint, or correct `path`/`port`/`scheme` |
| Pod restarts on a loop, healthy in between | **Liveness** killing a slow/busy app | Add `startupProbe`; raise `timeoutSeconds`/`failureThreshold` |
| Both fail immediately on a slow-boot app (JVM, migrations) | Probes start before app is up | Add a `startupProbe` (probes pause until it passes) |
| Probe passes manually but fails in-cluster | Wrong port/host, app binds `127.0.0.1` not `0.0.0.0` | Bind to all interfaces; match container port |

Correct probe set for a slow-starting service:

```yaml
startupProbe:                       # gates the others; allows up to 5m to boot (30 × 10s)
  httpGet: { path: /healthz, port: 8080 }
  periodSeconds: 10
  failureThreshold: 30
readinessProbe:                     # controls Service membership — fail = removed from endpoints
  httpGet: { path: /readyz, port: 8080 }
  periodSeconds: 5
  timeoutSeconds: 2
  failureThreshold: 3
livenessProbe:                      # restarts the container — keep it lenient
  httpGet: { path: /healthz, port: 8080 }
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 6
```

Rule: liveness should be *more forgiving* than readiness. A failed readiness only removes traffic;
a failed liveness kills the process.

---

### F. CreateContainerConfigError / CreateContainerError

The kubelet can't build the container spec — almost always a missing/mismatched ConfigMap or Secret.

```bash
kubectl describe pod <pod> -n <ns> | grep -A3 -i 'configerror\|not found'
# Error: configmap "app-config" not found
# Error: couldn't find key DB_PASSWORD in Secret ns/app-secret
```

| Message | Fix |
|---------|-----|
| `configmap "X" not found` | Create it / fix the name / check namespace: `kubectl get cm -n <ns>` |
| `secret "X" not found` | `kubectl get secret -n <ns>`; create with `--from-literal` |
| `couldn't find key K in ConfigMap/Secret` | The referenced `key` doesn't exist — `kubectl get secret X -o jsonpath='{.data}'` |
| `CreateContainerError: ... invalid mode` | Bad `defaultMode` on a volume, or a duplicate mount path |

```bash
kubectl create secret generic app-secret \
  --from-literal=DB_PASSWORD='s3cr3t' -n <ns> \
  --dry-run=client -o yaml | kubectl apply -f -
```

Reference exactly the keys the pod expects (`secretKeyRef.key` must match a key in `.data`).

---

### G. Service has no endpoints / selector mismatch

Symptom: in-cluster requests to the Service hang or get `connection refused`; `no endpoints available`.

```bash
kubectl get endpoints <svc> -n <ns>          # ENDPOINTS = <none> is the smoking gun
kubectl get endpointslices -n <ns> -l kubernetes.io/service-name=<svc>
kubectl describe svc <svc> -n <ns> | grep -i selector
kubectl get pods -n <ns> --show-labels       # do labels match the selector?
```

| Finding | Root cause | Fix |
|---------|-----------|-----|
| `ENDPOINTS <none>`, pods exist | Service `selector` ≠ pod labels | Align them; `kubectl get pods -l <selector>` should list the pods |
| Endpoints exist but `NotReady` | Readiness probe failing (see E) | Only `Ready` pods get added to endpoints |
| `targetPort` ≠ container port | Traffic hits a closed port | Match `targetPort` to the container's `containerPort` (or its name) |
| Works by pod IP, not Service | `port`/`protocol` mismatch | Verify `port`/`targetPort` and `protocol: TCP/UDP` |

```bash
# Definitive end-to-end test from inside the cluster:
kubectl run nettest --rm -it --image=nicolaka/netshoot --restart=Never -- \
  curl -sv http://<svc>.<ns>.svc.cluster.local:<port>/
```

---

### H. DNS resolution (CoreDNS) failures

```bash
kubectl run dnstest --rm -it --image=nicolaka/netshoot --restart=Never -- \
  sh -c 'nslookup kubernetes.default; nslookup <svc>.<ns>.svc.cluster.local'
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50
```

| Finding | Root cause | Fix |
|---------|-----------|-----|
| Can't resolve `kubernetes.default` | CoreDNS down / crashlooping | `kubectl get pods -n kube-system`; check CoreDNS logs & resources |
| Resolves internal, fails external | CoreDNS `forward` upstream broken | Check the `forward . /etc/resolv.conf` block in the `coredns` ConfigMap |
| `i/o timeout` to `10.96.0.10:53` | NetworkPolicy blocks egress to DNS | Allow egress to kube-dns on UDP/TCP 53 |
| Intermittent NXDOMAIN under load | `ndots:5` + search-domain fan-out | Use FQDN (trailing dot) or tune `dnsConfig.options ndots` |
| `kube-dns` Service has no endpoints | CoreDNS pods not Ready | Same as G applied to kube-system |

If a NetworkPolicy is blocking DNS, allow egress to kube-system on UDP/TCP 53 — see the
`allow-dns` policy in `references/manifests.md`.

---

### I. Ingress 404 / 502 / 503

```bash
kubectl describe ingress <ing> -n <ns>
kubectl get ingress <ing> -n <ns> -o yaml | grep -i ingressclass
kubectl logs -n <ingress-ns> -l app.kubernetes.io/name=ingress-nginx --tail=100
```

| HTTP code | Root cause | Fix |
|-----------|-----------|-----|
| **404** from the ingress controller | Host/path doesn't match any rule, OR no `ingressClassName` so no controller claimed it | Set `spec.ingressClassName: nginx`; verify host/path; check the controller actually reconciled it |
| **404** "default backend" | Rule matches but the backend Service has no endpoints | Fix the Service/selector (see G) |
| **502 Bad Gateway** | Backend pod returned garbage / wrong protocol (HTTPS backend, HTTP annotation) | Match `backend-protocol`; ensure the pod is actually listening |
| **503 Service Unavailable** | Backend Service has **zero ready endpoints** | Pods not Ready (see E) or selector wrong (see G) |
| Works for `/` but not `/api` | `pathType` mismatch (`Exact` vs `Prefix`) or missing `rewrite-target` | Use `pathType: Prefix`; add rewrite annotation if stripping a prefix |

The #1 silent 404: a missing `spec.ingressClassName` so no controller ever claimed the Ingress.
Full Ingress (with TLS + rewrite) is in `references/manifests.md`.

---

### J. RBAC Forbidden / cannot list resource

```bash
# Reproduce as the failing identity:
kubectl auth can-i list pods -n <ns> --as=system:serviceaccount:<ns>:<sa>
# → no
kubectl describe rolebinding,clusterrolebinding -n <ns> | grep -A4 <sa>
```

Error shape: `pods is forbidden: User "system:serviceaccount:prod:app" cannot list resource "pods"
in API group "" in the namespace "prod"`.

Decode it: `<resource>` = `pods`, `<verb>` = `list`, `<apiGroup>` = `""` (core), `<ns>` = `prod`.
Grant exactly that — a namespaced `Role` (`apiGroups: [""]`, `resources: ["pods","pods/log"]`,
`verbs: ["get","list","watch"]`) bound to the SA. Full Role + RoleBinding in `references/manifests.md`.

Gotchas: apiGroup `""` (core) vs `apps` (Deployments) vs `networking.k8s.io` (Ingress) — wrong group
= still Forbidden. Subresources (`pods/log`, `pods/exec`) are separate grants. A `Role` is
namespace-scoped; cluster-wide reads need a `ClusterRole` + `ClusterRoleBinding`.

---

### K. PVC stuck Pending or Terminating

```bash
kubectl get pvc -n <ns>
kubectl describe pvc <pvc> -n <ns> | grep -A6 Events
kubectl get storageclass
```

**Pending:**

| Finding | Root cause | Fix |
|---------|-----------|-----|
| `no persistent volumes available for this claim and no storage class is set` | No default StorageClass | Set one as default, or name it in the PVC |
| `waiting for first consumer to be created` | SC is `WaitForFirstConsumer` | Normal — it binds once a pod schedules; check the pod too |
| `provisioning failed` / quota | Cloud volume quota / bad params | Check provisioner logs; fix SC params |
| `requested ... but only ... available` (static PV) | No PV matches size/accessMode | Create a matching PV or use dynamic provisioning |

**Terminating (won't delete):** a finalizer is stuck (usually a pod still mounts it).

```bash
kubectl get pvc <pvc> -n <ns> -o jsonpath='{.metadata.finalizers}{"\n"}'
kubectl describe pvc <pvc> -n <ns> | grep -i 'used by\|mounted'
# Stop the consuming pod first. Only as a LAST RESORT, after confirming nothing uses it:
kubectl patch pvc <pvc> -n <ns> -p '{"metadata":{"finalizers":null}}' --type=merge
```

---

### L. Node NotReady / DiskPressure / MemoryPressure

```bash
kubectl get nodes
kubectl describe node <node> | grep -A8 Conditions
kubectl describe node <node> | grep -i 'pressure\|taint'
```

| Condition | Root cause | Fix |
|-----------|-----------|-----|
| `NotReady` | kubelet not reporting | SSH the node; `systemctl status kubelet`; check container runtime |
| `DiskPressure: True` | Disk/imagefs full → kubelet evicts pods, GC images | `crictl rmi --prune`; clean logs; grow the disk |
| `MemoryPressure: True` | Node low on memory → evictions | Reduce overcommit; add nodes; set/lower limits |
| `PIDPressure: True` | Too many processes | Find the offending pod; set pid limits |
| Cordoned (`SchedulingDisabled`) | Drained for maintenance | `kubectl uncordon <node>` when ready |

```bash
kubectl cordon <node>                         # stop new pods landing here
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --grace-period=120
# ... fix the node ...
kubectl uncordon <node>
```

---

## Automation

### Production-grade Deployment (the non-negotiable skeleton)

Every workload manifest needs these fields. Full copy-paste Deployment/Service/HPA/PDB/CronJob/
NetworkPolicy/RBAC/StatefulSet kit is in `references/manifests.md`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: api, namespace: prod, labels: { app.kubernetes.io/name: api } }
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector: { matchLabels: { app.kubernetes.io/name: api } }   # MUST match template labels
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }          # zero-downtime
  template:
    metadata: { labels: { app.kubernetes.io/name: api } }
    spec:
      containers:
        - name: api
          image: registry.example.com/api:1.4.2                # pin a tag/digest, never :latest
          ports: [ { name: http, containerPort: 8080 } ]
          resources:                                            # ALWAYS set both
            requests: { cpu: 100m, memory: 256Mi }
            limits:   { cpu: "1",  memory: 512Mi }
          startupProbe:   { httpGet: { path: /healthz, port: http }, failureThreshold: 30, periodSeconds: 10 }
          readinessProbe: { httpGet: { path: /readyz,  port: http }, periodSeconds: 5 }   # strict
          livenessProbe:  { httpGet: { path: /healthz, port: http }, periodSeconds: 10, failureThreshold: 6 }  # lenient
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: ["ALL"] } }
          envFrom:
            - configMapRef: { name: api-config }
            - secretRef:    { name: api-secret }
```

Always pair with a matching `Service` (selector == pod labels), an `HorizontalPodAutoscaler`
(`autoscaling/v2`, needs resource requests + metrics-server), and a `PodDisruptionBudget`
(`policy/v1`, `minAvailable`) — see `references/manifests.md`.

### kubectl rollout & rollback

```bash
kubectl rollout status deploy/api -n prod --timeout=120s     # blocks until healthy or times out
kubectl rollout history deploy/api -n prod
kubectl rollout undo deploy/api -n prod                       # back to previous revision
kubectl rollout undo deploy/api -n prod --to-revision=4
kubectl rollout restart deploy/api -n prod                    # rotate pods (e.g. to pick up a Secret)
```

Idempotent, safe deploy script (apply → wait → auto-rollback on failure):

```bash
#!/usr/bin/env bash
set -euo pipefail
NS="${1:?namespace}"; DEPLOY="${2:?deployment}"; MANIFEST="${3:?manifest.yaml}"

kubectl apply -f "$MANIFEST" -n "$NS" --dry-run=server >/dev/null   # validate first
kubectl apply -f "$MANIFEST" -n "$NS"

if ! kubectl rollout status "deploy/$DEPLOY" -n "$NS" --timeout=120s; then
  echo "Rollout failed — rolling back" >&2
  kubectl rollout undo "deploy/$DEPLOY" -n "$NS"
  kubectl rollout status "deploy/$DEPLOY" -n "$NS" --timeout=120s
  exit 1
fi
echo "Rollout OK"
```

### Helm — install/upgrade safely

```bash
helm upgrade --install api ./chart \
  --namespace prod --create-namespace \
  -f values.yaml -f values-prod.yaml \
  --set image.tag=1.4.2 \
  --atomic --timeout 5m \          # roll back automatically if the release fails
  --wait                          # block until resources are Ready

helm diff upgrade api ./chart -f values-prod.yaml   # needs helm-diff plugin — preview the change
helm history api -n prod
helm rollback api 0 -n prod                          # 0 = previous release
helm template api ./chart -f values-prod.yaml | kubectl apply --dry-run=server -f -
helm lint ./chart
```

Minimal chart layout and a templated Deployment live in `references/helm-and-kustomize.md`.

### kustomize — overlays per environment

```
base/                       # kustomization.yaml + deployment.yaml + service.yaml
overlays/
  dev/  kustomization.yaml   # replicas=1, dev image tag
  prod/ kustomization.yaml   # replicas=5, prod image, resource patches
```

```yaml
# overlays/prod/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
resources: [ ../../base ]
images:
  - name: registry.example.com/api
    newTag: 1.4.2
replicas:
  - name: api
    count: 5
patches:
  - path: resources-patch.yaml
    target: { kind: Deployment, name: api }
```

```bash
kubectl kustomize overlays/prod                   # render to stdout — review before applying
kubectl apply -k overlays/prod                    # apply the overlay
kubectl diff -k overlays/prod                      # diff against live cluster
```

### GitOps (Argo CD / Flux)

Point a controller at a Git path; it reconciles drift continuously. Full Argo CD `Application` and
Flux `GitRepository`/`Kustomization` manifests are in `references/helm-and-kustomize.md`.

```bash
argocd app sync api && argocd app wait api --health     # Argo CD: CLI-driven sync
flux reconcile kustomization api --with-source          # Flux equivalent
```

With GitOps, `kubectl apply` becomes a break-glass operation — Git is the source of truth; the
controller reconciles drift. Don't hand-edit live resources, or `selfHeal` will revert you (use
`argocd app set --sync-policy none` / `flux suspend` for a deliberate manual override).

---

## Common gotchas

- **`:latest` image tag** → no rollout on push, no rollback target, cache surprises. Pin a tag/digest.
- **No resource requests** → scheduler can't place pods sensibly; HPA on CPU is meaningless. Always set them.
- **Liveness probe doubles as readiness** → a busy pod gets *killed* instead of just removed from
  endpoints. Keep them separate; liveness lenient, readiness strict.
- **Secret/ConfigMap in the wrong namespace** → `CreateContainerConfigError`. They're namespaced.
- **Editing a Secret doesn't restart pods** → mounted env vars are snapshotted at start.
  `kubectl rollout restart deploy/<name>` to pick up changes.
- **`kubectl edit` on a GitOps-managed resource** → silently reverted by Argo/Flux. Edit Git instead.
- **`maxUnavailable: 25%` (default) on a 2-replica deploy** → drops to 1 during rollout. Set
  `maxUnavailable: 0, maxSurge: 1` for zero-downtime.
- **No PDB** → a node drain can take down all replicas at once. Add one.
- **Service `targetPort` is the *container* port, `port` is the *Service* port** — they're often confused.
- **`apiGroup: ""` vs `apps`** in RBAC — Deployments are in `apps`, pods/services/configmaps in `""`.
- **`kubectl delete -f` then `apply -f`** to "fix" things → loses data on stateful sets/PVCs. Prefer `apply`.

---

## Quick reference

```bash
# Triage
kubectl get pods -n <ns> -o wide
kubectl describe pod <pod> -n <ns>
kubectl get events -n <ns> --sort-by=.lastTimestamp
kubectl logs <pod> -n <ns> --previous -c <container> --tail=200
kubectl logs -f -l app.kubernetes.io/name=<app> -n <ns> --max-log-requests=10   # tail all replicas
kubectl get pod <pod> -n <ns> -o jsonpath='{.status.containerStatuses[*].lastState.terminated.reason}'

# Inspect
kubectl get endpoints <svc> -n <ns>
kubectl auth can-i <verb> <resource> -n <ns> --as=system:serviceaccount:<ns>:<sa>
kubectl top pod -n <ns> --containers          # needs metrics-server
kubectl get pvc,pv -n <ns>
kubectl describe node <node>

# Interactive debug
kubectl exec -it <pod> -n <ns> -- sh
kubectl debug -it <pod> -n <ns> --image=nicolaka/netshoot --target=<container>   # ephemeral container
kubectl run nettest --rm -it --image=nicolaka/netshoot --restart=Never -- bash
kubectl port-forward svc/<svc> 8080:80 -n <ns>

# Mutate (declarative + safe)
kubectl apply -f <file> --dry-run=server
kubectl diff -f <file>
kubectl rollout status|undo|restart deploy/<name> -n <ns>
kubectl scale deploy/<name> --replicas=5 -n <ns>
kubectl cordon|drain|uncordon <node>

# Helm / kustomize
helm upgrade --install <r> ./chart -f values.yaml --atomic --wait
helm diff upgrade <r> ./chart -f values.yaml
helm rollback <r> <rev> -n <ns>
kubectl kustomize overlays/<env>
kubectl apply -k overlays/<env>
```

For deeper material see `references/`:
- `references/failure-modes.md` — extended failure-mode catalog with exit codes, event strings, and full diagnostic transcripts.
- `references/manifests.md` — copy-paste manifest library (Deployment/Service/HPA/PDB/CronJob/NetworkPolicy/RBAC/probes).
- `references/helm-and-kustomize.md` — Helm chart skeleton, values patterns, kustomize base+overlay layout, GitOps wiring.
