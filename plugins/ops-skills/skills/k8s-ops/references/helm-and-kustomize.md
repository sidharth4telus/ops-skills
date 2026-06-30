# Helm, kustomize, and GitOps

Packaging and environment-promotion patterns for `k8s-ops`.

## Helm chart skeleton

```
chart/
  Chart.yaml
  values.yaml
  values-dev.yaml
  values-prod.yaml
  templates/
    _helpers.tpl
    deployment.yaml
    service.yaml
    hpa.yaml
    ingress.yaml
    NOTES.txt
  templates/tests/
    test-connection.yaml
```

### Chart.yaml

```yaml
apiVersion: v2
name: api
description: API microservice
type: application
version: 0.3.0            # chart version — bump on every chart change
appVersion: "1.4.2"      # the app/image version this chart deploys by default
dependencies:
  - name: redis
    version: "19.x.x"
    repository: https://charts.bitnami.com/bitnami
    condition: redis.enabled
```

### values.yaml (sane defaults)

```yaml
replicaCount: 2
image:
  repository: registry.example.com/api
  tag: ""                 # defaults to .Chart.AppVersion via the template
  pullPolicy: IfNotPresent
resources:
  requests: { cpu: 100m, memory: 256Mi }
  limits:   { cpu: "1",  memory: 512Mi }
service:
  type: ClusterIP
  port: 80
ingress:
  enabled: false
  className: nginx
  hosts: []
autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70
redis:
  enabled: false
```

### templates/_helpers.tpl

```yaml
{{- define "api.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "api.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "api.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
```

### templates/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "api.fullname" . }}
  labels: {{- include "api.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels: {{- include "api.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels: {{- include "api.selectorLabels" . | nindent 8 }}
      annotations:
        # forces a rollout when config changes — Helm best practice
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports: [ { name: http, containerPort: 8080 } ]
          resources: {{- toYaml .Values.resources | nindent 12 }}
          readinessProbe: { httpGet: { path: /readyz, port: http } }
          livenessProbe:  { httpGet: { path: /healthz, port: http } }
```

### Lifecycle commands

```bash
helm lint ./chart
helm template api ./chart -f chart/values-prod.yaml         # render locally
helm template api ./chart -f chart/values-prod.yaml | kubectl apply --dry-run=server -f -

# Install/upgrade idempotently, atomic + wait so a bad release auto-rolls-back:
helm upgrade --install api ./chart \
  -n prod --create-namespace \
  -f chart/values-prod.yaml \
  --set image.tag=1.4.2 \
  --atomic --timeout 5m --wait

helm diff upgrade api ./chart -f chart/values-prod.yaml      # requires `helm plugin install https://github.com/databus23/helm-diff`
helm history api -n prod
helm rollback api 0 -n prod                                   # 0 = previous revision
helm get values api -n prod                                   # what's actually deployed
helm uninstall api -n prod
```

Rules:
- Bump `Chart.version` on every chart change; `appVersion` tracks the image.
- Never put environment-specific values in `values.yaml` — layer `-f values-<env>.yaml`.
- `--atomic` implies `--wait`; on failure it rolls back to the last good release automatically.
- The `checksum/config` annotation pattern forces pods to restart when a ConfigMap/Secret changes.

## kustomize — base + overlays

```
base/
  kustomization.yaml
  deployment.yaml
  service.yaml
overlays/
  dev/
    kustomization.yaml
  prod/
    kustomization.yaml
    resources-patch.yaml
    hpa.yaml
```

### base/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
commonLabels:
  app.kubernetes.io/name: api
images:
  - name: registry.example.com/api
    newTag: 1.0.0
```

### overlays/prod/kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: prod
namePrefix: prod-
resources:
  - ../../base
  - hpa.yaml
images:
  - name: registry.example.com/api
    newTag: 1.4.2
replicas:
  - name: api
    count: 5
configMapGenerator:
  - name: api-config
    literals:
      - LOG_LEVEL=info
patches:
  - path: resources-patch.yaml
    target: { kind: Deployment, name: api }
```

### overlays/prod/resources-patch.yaml (strategic merge)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: api }
spec:
  template:
    spec:
      containers:
        - name: api
          resources:
            requests: { cpu: 250m, memory: 512Mi }
            limits:   { cpu: "2",  memory: 1Gi }
```

### Commands

```bash
kubectl kustomize overlays/prod                   # render
kubectl kustomize overlays/prod | kubectl apply --dry-run=server -f -
kubectl apply -k overlays/prod                    # apply
kubectl diff -k overlays/prod                      # diff vs live
```

`configMapGenerator`/`secretGenerator` append a content hash to the name (e.g. `api-config-7d8f9`),
so changing config forces a new ConfigMap name → automatic pod rollout. Don't disable
`disableNameSuffixHash` unless you have a reason.

## GitOps

### Argo CD Application (self-healing, prune)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: api
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/org/manifests.git
    targetRevision: main
    path: overlays/prod                 # or a Helm chart path + helm.valueFiles
  destination:
    server: https://kubernetes.default.svc
    namespace: prod
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [ CreateNamespace=true, ApplyOutOfSyncOnly=true ]
    retry:
      limit: 3
      backoff: { duration: 10s, factor: 2, maxDuration: 3m }
```

```bash
argocd app get api
argocd app sync api && argocd app wait api --health --timeout 300
argocd app diff api                       # what would change
argocd app rollback api <revision>
```

### Flux (Kustomization + GitRepository)

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata: { name: manifests, namespace: flux-system }
spec:
  interval: 1m
  url: https://github.com/org/manifests.git
  ref: { branch: main }
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: api, namespace: flux-system }
spec:
  interval: 5m
  path: ./overlays/prod
  prune: true
  sourceRef: { kind: GitRepository, name: manifests }
  wait: true
  timeout: 3m
```

```bash
flux reconcile kustomization api --with-source
flux get kustomizations
flux suspend kustomization api      # pause reconciliation (e.g. for a manual hotfix)
flux resume kustomization api
```

GitOps golden rule: **Git is the source of truth.** `kubectl edit`/`helm upgrade` against a
GitOps-managed namespace gets reverted by `selfHeal`. Change Git, let the controller reconcile.
Use `suspend` for an emergency manual override, then reconcile back.
