# Manifest library (copy-paste)

Production-grade, idiomatic manifests for `k8s-ops`. Latest stable APIs. Adjust namespace, labels,
ports, and resources to taste. Every object uses recommended `app.kubernetes.io/*` labels.

## Deployment + Service (the pair)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: prod
  labels:
    app.kubernetes.io/name: api
    app.kubernetes.io/version: "1.4.2"
    app.kubernetes.io/component: backend
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels: { app.kubernetes.io/name: api }
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
  template:
    metadata:
      labels:
        app.kubernetes.io/name: api
        app.kubernetes.io/version: "1.4.2"
    spec:
      serviceAccountName: api
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        fsGroup: 10001
        seccompProfile: { type: RuntimeDefault }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector: { matchLabels: { app.kubernetes.io/name: api } }
      containers:
        - name: api
          image: registry.example.com/api:1.4.2
          imagePullPolicy: IfNotPresent
          ports:
            - { name: http, containerPort: 8080 }
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits:   { cpu: "1",  memory: 512Mi }
          startupProbe:
            httpGet: { path: /healthz, port: http }
            failureThreshold: 30
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 6
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          envFrom:
            - configMapRef: { name: api-config }
            - secretRef:    { name: api-secret }
          volumeMounts:
            - { name: tmp, mountPath: /tmp }      # writable scratch since rootfs is read-only
      volumes:
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: prod
  labels: { app.kubernetes.io/name: api }
spec:
  type: ClusterIP
  selector: { app.kubernetes.io/name: api }      # MUST match pod labels exactly
  ports:
    - name: http
      port: 80            # the Service port clients dial
      targetPort: http    # the container port (by name) — resilient to port renumbering
      protocol: TCP
```

## HPA (autoscaling/v2) — CPU + custom

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: api, namespace: prod }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: api }
  minReplicas: 3
  maxReplicas: 20
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300     # avoid flapping
      policies: [ { type: Percent, value: 50, periodSeconds: 60 } ]
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
    - type: Resource
      resource: { name: memory, target: { type: Utilization, averageUtilization: 80 } }
```
HPA on CPU requires resource **requests** on the pods and a running metrics-server.

## PodDisruptionBudget (policy/v1)

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: api, namespace: prod }
spec:
  minAvailable: 2                # or maxUnavailable: 1 — never set both
  selector: { matchLabels: { app.kubernetes.io/name: api } }
```

## ConfigMap & Secret

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: api-config, namespace: prod }
data:
  LOG_LEVEL: "info"
  FEATURE_X: "true"
---
apiVersion: v1
kind: Secret
metadata: { name: api-secret, namespace: prod }
type: Opaque
stringData:                       # stringData is auto base64-encoded; readable in Git only if SOPS/sealed
  DB_PASSWORD: "REPLACE_VIA_SEALED_SECRET_OR_EXTERNAL_SECRETS"
```
Don't commit real secrets. Use Sealed Secrets, External Secrets Operator, or the cloud secret manager
CSI driver. Generate imperatively for dev:
```bash
kubectl create secret generic api-secret --from-literal=DB_PASSWORD='dev' -n prod \
  --dry-run=client -o yaml | kubectl apply -f -
```

## CronJob (batch/v1)

```yaml
apiVersion: batch/v1
kind: CronJob
metadata: { name: warmer, namespace: prod }
spec:
  schedule: "0 */3 * * *"
  concurrencyPolicy: Forbid           # don't overlap runs
  startingDeadlineSeconds: 120
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 1800      # kill a run that hangs
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: warmer
              image: registry.example.com/warmer:1.0.0
              resources:
                requests: { cpu: 100m, memory: 128Mi }
                limits:   { cpu: 500m, memory: 256Mi }
```

## NetworkPolicy — default-deny + explicit allows

```yaml
# 1) Default-deny all ingress in the namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-ingress, namespace: prod }
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
# 2) Allow ingress to api from the ingress controller namespace, plus DNS egress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: api-allow, namespace: prod }
spec:
  podSelector: { matchLabels: { app.kubernetes.io/name: api } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: ingress-nginx } }
      ports: [ { protocol: TCP, port: 8080 } ]
  egress:
    - to:
        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to: [ { ipBlock: { cidr: 10.0.0.0/8 } } ]    # internal services/DB
```

## RBAC — least privilege

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: { name: api, namespace: prod }
automountServiceAccountToken: false      # turn on only if the pod calls the API server
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: api-reader, namespace: prod }
rules:
  - apiGroups: [""]
    resources: ["configmaps", "secrets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: api-reader, namespace: prod }
subjects:
  - { kind: ServiceAccount, name: api, namespace: prod }
roleRef:
  kind: Role
  name: api-reader
  apiGroup: rbac.authorization.k8s.io
```
Use `ClusterRole` + `ClusterRoleBinding` only for genuinely cluster-wide reads. Never bind
`cluster-admin` to a workload SA.

## Ingress (networking.k8s.io/v1) with TLS

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api
  namespace: prod
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts: [ api.example.com ]
      secretName: api-tls
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: { name: api, port: { number: 80 } }
```

## StatefulSet (when you need stable identity + storage)

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: db, namespace: prod }
spec:
  serviceName: db                    # headless Service for stable DNS (db-0.db.prod.svc...)
  replicas: 3
  selector: { matchLabels: { app.kubernetes.io/name: db } }
  template:
    metadata: { labels: { app.kubernetes.io/name: db } }
    spec:
      containers:
        - name: db
          image: postgres:16
          ports: [ { name: pg, containerPort: 5432 } ]
          volumeMounts: [ { name: data, mountPath: /var/lib/postgresql/data } ]
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: [ ReadWriteOnce ]
        storageClassName: gp3
        resources: { requests: { storage: 20Gi } }
```
