# Chart Modernization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Modernize Ditto, Hono, HawkBit Helm charts to latest versions with ESO support and external infrastructure, deployed via ArgoCD on the existing cluster.

**Architecture:** Wrapper-minimum approach — charts updated in-place (Hono, HawkBit) or converted to OCI wrappers (Ditto), subcharts disabled in favor of existing cluster services (MariaDB, Redpanda, SeaweedFS, Percona MongoDB). Secrets managed via ESO + Vault. Two repos: `packages` (charts), `k8s-on-lxd` (ArgoCD apps + manifests).

**Tech Stack:** Helm 3, ArgoCD, ESO, Vault, Percona MongoDB Operator (psmdb-operator 1.22.0), kube-prometheus-stack, Keycloak, Traefik Gateway API, MariaDB operator (existing), Redpanda (existing), SeaweedFS (existing).

---

## Phase 1 — MongoDB Infrastructure

### Task 1: Add `packages` repo to ArgoCD

**Files:**
- Modify: `manifests/argocd-oidc/` or create `manifests/argocd-repos/` in `k8s-on-lxd`

ArgoCD currently only knows `k8s-on-lxd` repo. The `packages` repo must be registered so ArgoCD can use it as a chart source.

**Step 1: Create repository secret in ArgoCD namespace**

```bash
kubectl create secret generic packages-repo \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/fcraviolatti/packages.git \
  --dry-run=client -o yaml | kubectl label --local -f - \
  argocd.argoproj.io/secret-type=repository -o yaml | kubectl apply -f -
```

**Step 2: Verify repo is recognized by ArgoCD**

```bash
kubectl get secret packages-repo -n argocd -o jsonpath='{.metadata.labels}'
# Expected: {"argocd.argoproj.io/secret-type":"repository"}
argocd repo list 2>/dev/null | grep packages || kubectl exec -n argocd deploy/argocd-self-server -- argocd repo list --grpc-web | grep packages
```

**Step 3: Commit the repo secret as a manifest in k8s-on-lxd**

Create `manifests/argocd-repos/packages-repo-secret.yaml`:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: packages-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: https://github.com/fcraviolatti/packages.git
```

Add to `manifests/argocd-repos/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - packages-repo-secret.yaml
```

Add to `apps/root-app.yaml` sources (or as a new ArgoCD app at wave 0):
```yaml
# In apps/ create apps/argocd-repos.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-repos
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: git@github.com:fcraviolatti/k8s-on-lxd.git
    targetRevision: main
    path: manifests/argocd-repos
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

**Step 4: Commit**
```bash
cd /root/projects/k8s-on-lxd
git add manifests/argocd-repos/ apps/argocd-repos.yaml
git commit -m "feat: add packages repo to ArgoCD and argocd-repos app"
```

---

### Task 2: Percona MongoDB Operator

**Files (k8s-on-lxd):**
- Create: `apps/percona-mongodb-operator.yaml`
- Create: `manifests/percona-mongodb-operator/values-psmdb-operator.yaml`

**Step 1: Inspect Percona operator default values**

```bash
helm show values percona/psmdb-operator --version 1.22.0 | head -60
```

Key values to override: `watchNamespace` (set to `mongodb` or empty for cluster-wide).

**Step 2: Create values file**

`manifests/percona-mongodb-operator/values-psmdb-operator.yaml`:
```yaml
# Watch all namespaces (cluster-wide operator)
watchNamespace: ""
```

**Step 3: Create ArgoCD Application**

`apps/percona-mongodb-operator.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: percona-mongodb-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  project: default
  source:
    repoURL: https://percona.github.io/percona-helm-charts/
    chart: psmdb-operator
    targetRevision: 1.22.0
    helm:
      valuesFiles:
        - $values/manifests/percona-mongodb-operator/values-psmdb-operator.yaml
  sources:
    - repoURL: https://percona.github.io/percona-helm-charts/
      chart: psmdb-operator
      targetRevision: 1.22.0
      helm:
        valueFiles:
          - $values/manifests/percona-mongodb-operator/values-psmdb-operator.yaml
    - repoURL: git@github.com:fcraviolatti/k8s-on-lxd.git
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: percona-mongodb-operator
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

**Step 4: Commit and verify sync**

```bash
git add apps/percona-mongodb-operator.yaml manifests/percona-mongodb-operator/
git commit -m "feat: add Percona MongoDB Operator ArgoCD app (wave 4)"
git push

# After ArgoCD syncs:
kubectl get pods -n percona-mongodb-operator
# Expected: psmdb-operator pod Running
kubectl get crd | grep percona
# Expected: perconaservermongodbs.psmdb.percona.com
```

---

### Task 3: MongoDB ReplicaSet instance

**Files (k8s-on-lxd):**
- Create: `apps/mongodb.yaml`
- Create: `manifests/mongodb/values-psmdb-db.yaml`
- Create: `manifests/mongodb/externalsecret-mongodb-root.yaml`
- Create: `manifests/mongodb/externalsecret-mongodb-users.yaml`
- Create: `manifests/mongodb/kustomization.yaml`

**Step 1: Create Vault secrets for MongoDB**

```bash
# Root password
kubectl exec -n vault vault-0 -- vault kv put secret/mongodb/root \
  rootPassword="$(openssl rand -base64 24)"

# Ditto user
kubectl exec -n vault vault-0 -- vault kv put secret/mongodb/ditto \
  username=ditto \
  password="$(openssl rand -base64 24)"

# Hono user
kubectl exec -n vault vault-0 -- vault kv put secret/mongodb/hono \
  username=hono \
  password="$(openssl rand -base64 24)"
```

**Step 2: Create ExternalSecrets**

`manifests/mongodb/externalsecret-mongodb-users.yaml`:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: mongodb-users
  namespace: mongodb
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: mongodb-users
    template:
      data:
        # Percona PSMDB expects users in this format for CR spec.secrets.users
        DITTO_PASSWORD: "{{ .dittoPassword }}"
        HONO_PASSWORD: "{{ .honoPassword }}"
  data:
    - secretKey: dittoPassword
      remoteRef:
        key: mongodb/ditto
        property: password
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: honoPassword
      remoteRef:
        key: mongodb/hono
        property: password
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
```

**Step 3: Create values file for psmdb-db chart**

`manifests/mongodb/values-psmdb-db.yaml`:
```yaml
# PerconaServerMongoDB CR values
# Ref: https://www.percona.com/doc/kubernetes-operator-for-psmongodb/

# 3-node ReplicaSet for HA
replsets:
  - name: rs0
    size: 3
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 1Gi
    volumeSpec:
      pvc:
        resources:
          requests:
            storage: 10Gi
        storageClassName: local-path

# Users to create at init time
# Passwords come from a Secret (managed by ESO)
users:
  - name: ditto
    db: admin
    passwordSecretRef:
      name: mongodb-users
      key: DITTO_PASSWORD
    roles:
      - name: readWrite
        db: ditto-things
      - name: readWrite
        db: ditto-connectivity
      - name: readWrite
        db: ditto-policies
      - name: readWrite
        db: ditto-search
  - name: hono
    db: admin
    passwordSecretRef:
      name: mongodb-users
      key: HONO_PASSWORD
    roles:
      - name: readWrite
        db: hono-device-registry

# Backup via PBM - configure in production with S3 target
backup:
  enabled: false

# Disable sharding (not needed for this use case)
sharding:
  enabled: false

secrets:
  # Secret containing MONGODB_DATABASE_ADMIN_PASSWORD etc.
  # psmdb-db chart can auto-generate or reference existing
  users: mongodb-users
```

**Step 4: Create ArgoCD Application**

`apps/mongodb.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mongodb
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  project: default
  sources:
    - repoURL: https://percona.github.io/percona-helm-charts/
      chart: psmdb-db
      targetRevision: 1.22.0
      helm:
        valueFiles:
          - $values/manifests/mongodb/values-psmdb-db.yaml
    - repoURL: git@github.com:fcraviolatti/k8s-on-lxd.git
      targetRevision: main
      ref: values
    - repoURL: git@github.com:fcraviolatti/k8s-on-lxd.git
      targetRevision: main
      path: manifests/mongodb
  destination:
    server: https://kubernetes.default.svc
    namespace: mongodb
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

**Step 5: Commit and verify**

```bash
git add apps/mongodb.yaml manifests/mongodb/
git commit -m "feat: add MongoDB ReplicaSet (Percona) ArgoCD app (wave 5)"
git push

# After ArgoCD syncs:
kubectl get pods -n mongodb
# Expected: 3x rs0 pods Running
kubectl get perconaservermongodbs -n mongodb
# Expected: READY state
```

---

## Phase 2 — Ditto Chart Wrapper

### Task 4: Convert Ditto to OCI wrapper (packages repo)

**Files (packages repo, branch k8s-deploy):**
- Modify: `charts/ditto/Chart.yaml`
- Replace: `charts/ditto/values.yaml`
- Remove: all files in `charts/ditto/templates/` except `_helpers.tpl`
- Create: `charts/ditto/templates/externalsecret-gateway.yaml` (optional helper)

**Step 1: Lint current chart to establish baseline**

```bash
cd /root/projects/packages
helm dependency update charts/ditto
helm lint charts/ditto
```

**Step 2: Rewrite Chart.yaml as OCI wrapper**

`charts/ditto/Chart.yaml`:
```yaml
apiVersion: v2
name: ditto
description: Wrapper chart for Eclipse Ditto — routes to official OCI chart with ESO support and external MongoDB
type: application
version: 3.8.12
appVersion: "3.8.12"
keywords:
  - iot-chart
  - digital-twin
  - IoT
home: https://www.eclipse.org/ditto
sources:
  - https://github.com/eclipse-ditto/ditto
dependencies:
  - name: ditto
    version: "3.8.12"
    repository: "oci://registry-1.docker.io/eclipse"
    alias: ditto
```

**Step 3: Rewrite values.yaml — disable bundled MongoDB, add ESO flags**

`charts/ditto/values.yaml`:
```yaml
# ESO integration — when true, skip Secret generation and use existingSecretName
gateway:
  useExternalSecret: false
  existingSecretName: ""

dbconfig:
  useExternalSecret: false
  existingSecretName: ""

# Pass-through values to the upstream ditto subchart
# Ref: https://github.com/eclipse-ditto/ditto/tree/master/deployment/helm/ditto
ditto:
  # Disable bundled MongoDB — use external instance
  mongodb:
    enabled: false

  # MongoDB connection — override with external URI
  # When useExternalSecret=true, set these via existingSecretName secret
  dbconfig:
    connectivity:
      uri: ""
    things:
      uri: ""
    policies:
      uri: ""
    searchDB:
      uri: ""

  # Gateway credentials — set via existingSecretName when useExternalSecret=true
  gateway:
    devopsPassword: ""
    statusPassword: ""
```

**Step 4: Create minimal templates/ for ESO flag handling**

`charts/ditto/templates/gateway-secret.yaml`:
```yaml
{{- if not .Values.gateway.useExternalSecret }}
# When useExternalSecret=false, defer to upstream ditto subchart's own Secret generation.
# The upstream chart handles gateway.devopsPassword / gateway.statusPassword.
{{- end }}
```

`charts/ditto/templates/NOTES.txt`:
```
Eclipse Ditto {{ .Chart.AppVersion }} deployed.

Gateway API: https://{{ .Values.ditto.ingress.host | default "ditto.<your-domain>" }}

When using ESO (useExternalSecret: true):
  Gateway secret: {{ .Values.gateway.existingSecretName }}
  DB config secret: {{ .Values.dbconfig.existingSecretName }}
```

**Step 5: Lint the wrapper**

```bash
cd /root/projects/packages
helm dependency update charts/ditto
helm lint charts/ditto
# Expected: 1 chart(s) linted, 0 chart(s) failed
```

**Step 6: Commit**

```bash
git add charts/ditto/
git commit -m "feat(ditto): convert deprecated local chart to OCI wrapper for 3.8.12"
git push origin k8s-deploy
```

---

### Task 5: Ditto Vault secrets + ExternalSecrets + ArgoCD app (k8s-on-lxd)

**Files (k8s-on-lxd):**
- Create: `manifests/ditto/externalsecret-ditto-gateway.yaml`
- Create: `manifests/ditto/externalsecret-ditto-mongodb.yaml`
- Create: `manifests/ditto/values-ditto.yaml`
- Create: `manifests/ditto/kustomization.yaml`
- Create: `apps/ditto.yaml`

**Step 1: Create Vault secrets for Ditto**

```bash
kubectl exec -n vault vault-0 -- vault kv put secret/ditto/gateway \
  devopsPassword="$(openssl rand -base64 24)" \
  statusPassword="$(openssl rand -base64 24)"

# MongoDB URIs — replace MONGO_PASS with value from secret/mongodb/ditto
MONGO_PASS=$(kubectl exec -n vault vault-0 -- vault kv get -field=password secret/mongodb/ditto)
MONGO_HOST="mongodb-rs0.mongodb.svc.cluster.local"
kubectl exec -n vault vault-0 -- vault kv put secret/ditto/mongodb \
  thingsUri="mongodb://ditto:${MONGO_PASS}@${MONGO_HOST}:27017/ditto-things?authSource=admin" \
  connectivityUri="mongodb://ditto:${MONGO_PASS}@${MONGO_HOST}:27017/ditto-connectivity?authSource=admin" \
  policiesUri="mongodb://ditto:${MONGO_PASS}@${MONGO_HOST}:27017/ditto-policies?authSource=admin" \
  searchUri="mongodb://ditto:${MONGO_PASS}@${MONGO_HOST}:27017/ditto-search?authSource=admin"
```

**Step 2: Create ExternalSecrets**

`manifests/ditto/externalsecret-ditto-gateway.yaml`:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ditto-gateway-secret
  namespace: ditto
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: ditto-gateway-secret
  data:
    - secretKey: devops-password
      remoteRef:
        key: ditto/gateway
        property: devopsPassword
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: status-password
      remoteRef:
        key: ditto/gateway
        property: statusPassword
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
```

`manifests/ditto/externalsecret-ditto-mongodb.yaml`:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ditto-mongodb-secret
  namespace: ditto
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: ditto-mongodb-secret
  data:
    - secretKey: things-uri
      remoteRef:
        key: ditto/mongodb
        property: thingsUri
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: connectivity-uri
      remoteRef:
        key: ditto/mongodb
        property: connectivityUri
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: policies-uri
      remoteRef:
        key: ditto/mongodb
        property: policiesUri
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: searchDB-uri
      remoteRef:
        key: ditto/mongodb
        property: searchUri
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
```

**Step 3: Create values file**

`manifests/ditto/values-ditto.yaml`:
```yaml
gateway:
  useExternalSecret: true
  existingSecretName: ditto-gateway-secret

dbconfig:
  useExternalSecret: true
  existingSecretName: ditto-mongodb-secret

ditto:
  mongodb:
    enabled: false

  # Ingress via Traefik Gateway API — configure HTTPRoute separately
  ingress:
    enabled: false
```

**Step 4: Create kustomization**

`manifests/ditto/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - externalsecret-ditto-gateway.yaml
  - externalsecret-ditto-mongodb.yaml
```

**Step 5: Create ArgoCD Application**

`apps/ditto.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ditto
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "8"
spec:
  project: default
  sources:
    - repoURL: https://github.com/fcraviolatti/packages.git
      targetRevision: k8s-deploy
      path: charts/ditto
      helm:
        valueFiles:
          - $values/manifests/ditto/values-ditto.yaml
    - repoURL: git@github.com:fcraviolatti/k8s-on-lxd.git
      targetRevision: main
      ref: values
    - repoURL: git@github.com:fcraviolatti/k8s-on-lxd.git
      targetRevision: main
      path: manifests/ditto
  destination:
    server: https://kubernetes.default.svc
    namespace: ditto
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

**Step 6: Commit and verify**

```bash
cd /root/projects/k8s-on-lxd
git add apps/ditto.yaml manifests/ditto/
git commit -m "feat: add Ditto ArgoCD app with ESO secrets (wave 8)"
git push

kubectl get pods -n ditto
# Expected: ditto-gateway, ditto-things, ditto-policies, ditto-connectivity, ditto-thingssearch all Running
kubectl get externalsecret -n ditto
# Expected: ditto-gateway-secret Ready, ditto-mongodb-secret Ready
```

---

## Phase 3 — Hono Chart Update

### Task 6: Update Hono chart to 2.7.0 with ESO support (packages repo)

**Files (packages repo):**
- Modify: `charts/hono/Chart.yaml`
- Modify: `charts/hono/values.yaml` (add `envSecret` per service, update image tags)
- Modify: `charts/hono/templates/hono-service-auth/hono-service-auth-secret.yaml`
- Modify: `charts/hono/templates/hono-service-device-registry-mongodb/hono-service-device-registry-secret.yaml`
- Modify: `charts/hono/templates/hono-service-command-router/hono-service-command-router-secret.yaml`
- Modify: `charts/hono/templates/hono-adapter-http/hono-adapter-http-secret.yaml`
- Modify: `charts/hono/templates/hono-adapter-mqtt/hono-adapter-mqtt-secret.yaml`
- Modify: `charts/hono/templates/hono-adapter-amqp/hono-adapter-amqp-secret.yaml`
- Modify: `charts/hono/templates/hono-adapter-coap/hono-adapter-coap-secret.yaml`

**Step 1: Update Chart.yaml**

In `charts/hono/Chart.yaml`, change:
```yaml
version: 2.7.0
appVersion: 2.7.0
```

Subcharts to keep (for optional bundled mode) but default to disabled:
- `prometheus`: keep, `condition: prometheus.createInstance` (default false)
- `grafana`: keep, `condition: grafana.enabled` (default false)
- `mongodb`: keep, `condition: mongodb.createInstance` (default false)
- `kafka`: keep, `condition: kafka.createInstance` (default false)

**Step 2: Update all image tags in values.yaml**

Find all `imageName: "eclipse/hono-*"` entries and change image registry to `eclipsehono` and tag to `2.7.0`.

In `charts/hono/values.yaml`, the `defaults` section sets the image tag globally. Find:
```yaml
# defaults.image section
```
Set `tag: "2.7.0"` globally and update `imageName` entries that still use `eclipse/` prefix to `eclipsehono/`.

Specific entries to update (use grep to find all):
```bash
grep -n "imageName\|imageTag" charts/hono/values.yaml
```

**Step 3: Add `envSecret` field and `useExternalSecret` flag per service**

The Hono `_helpers.tpl` already supports `envSecret` in `hono.component.envFrom`. We extend this pattern.

For each service section in `values.yaml`, add:
```yaml
# Example for authServer section
authServer:
  useExternalSecret: false   # when true, skip Secret generation
  envSecret: ""              # name of existing Secret with env vars (e.g. hono-auth-secret)
  # ... existing fields ...
```

Services to update: `authServer`, `deviceRegistryExample` (mongodb variant), `commandRouter`, `adapters.http`, `adapters.mqtt`, `adapters.amqp`, `adapters.coap`.

**Step 4: Wrap each secret template with useExternalSecret guard**

For each `*-secret.yaml` template, wrap the entire content:

```yaml
{{- if not .Values.authServer.useExternalSecret }}
# ... existing secret template content ...
{{- end }}
```

For adapter secrets (inside `{{- if .Values.adapters.http.enabled }}`):
```yaml
{{- if .Values.adapters.http.enabled }}
{{- if not .Values.adapters.http.useExternalSecret }}
# ... existing secret template content ...
{{- end }}
{{- end }}
```

**Step 5: Replace hardcoded credential values with env var references**

In each `application.yml` within the secret templates, find credential fields and replace with env var references that Quarkus will resolve:

Example in `hono-service-device-registry-mongodb` secret:
```yaml
# Before:
spring:
  data:
    mongodb:
      uri: {{ .Values.deviceRegistryExample.hono.registry.mongodb.uri }}

# After (env var injected from envSecret):
spring:
  data:
    mongodb:
      uri: "${HONO_MONGODB_URI}"
```

The corresponding ExternalSecret will put `HONO_MONGODB_URI` in the secret referenced by `envSecret`.

**Step 6: Lint**

```bash
cd /root/projects/packages
helm dependency update charts/hono
helm lint charts/hono
helm template hono charts/hono --set adapters.http.enabled=true | grep -c "kind:"
# Verify resource count is reasonable (should be ~40-60 resources)
```

**Step 7: Commit**

```bash
git add charts/hono/
git commit -m "feat(hono): update to 2.7.0, disable bundled subcharts, add ESO envSecret support"
git push origin k8s-deploy
```

---

### Task 7: Hono Vault secrets + ExternalSecrets + ArgoCD app (k8s-on-lxd)

**Files (k8s-on-lxd):**
- Create: `manifests/hono/externalsecret-hono-auth.yaml`
- Create: `manifests/hono/externalsecret-hono-device-registry.yaml`
- Create: `manifests/hono/externalsecret-hono-command-router.yaml`
- Create: `manifests/hono/externalsecret-hono-adapter-http.yaml`
- Create: `manifests/hono/externalsecret-hono-adapter-mqtt.yaml`
- Create: `manifests/hono/externalsecret-hono-adapter-amqp.yaml`
- Create: `manifests/hono/externalsecret-hono-adapter-coap.yaml`
- Create: `manifests/hono/values-hono.yaml`
- Create: `manifests/hono/kustomization.yaml`
- Create: `apps/hono.yaml`

**Step 1: Create Vault secrets for Hono**

```bash
MONGO_PASS=$(kubectl exec -n vault vault-0 -- vault kv get -field=password secret/mongodb/hono)
MONGO_HOST="mongodb-rs0.mongodb.svc.cluster.local"

kubectl exec -n vault vault-0 -- vault kv put secret/hono/auth \
  authPassword="$(openssl rand -base64 24)"

kubectl exec -n vault vault-0 -- vault kv put secret/hono/device-registry \
  mongodbUri="mongodb://hono:${MONGO_PASS}@${MONGO_HOST}:27017/hono-device-registry?authSource=admin"

kubectl exec -n vault vault-0 -- vault kv put secret/hono/command-router \
  amqpPassword="$(openssl rand -base64 24)"

kubectl exec -n vault vault-0 -- vault kv put secret/hono/adapter-http \
  adapterPassword="$(openssl rand -base64 24)"

kubectl exec -n vault vault-0 -- vault kv put secret/hono/adapter-mqtt \
  adapterPassword="$(openssl rand -base64 24)"

kubectl exec -n vault vault-0 -- vault kv put secret/hono/adapter-amqp \
  adapterPassword="$(openssl rand -base64 24)"

kubectl exec -n vault vault-0 -- vault kv put secret/hono/adapter-coap \
  adapterPassword="$(openssl rand -base64 24)"
```

**Step 2: Create ExternalSecret for each service**

Pattern (repeat for each service, adjusting keys):

`manifests/hono/externalsecret-hono-auth.yaml`:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: hono-auth-secret
  namespace: hono
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: hono-auth-secret
  data:
    - secretKey: HONO_AUTH_PASSWORD
      remoteRef:
        key: hono/auth
        property: authPassword
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
```

`manifests/hono/externalsecret-hono-device-registry.yaml`:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: hono-device-registry-secret
  namespace: hono
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: hono-device-registry-secret
  data:
    - secretKey: HONO_MONGODB_URI
      remoteRef:
        key: hono/device-registry
        property: mongodbUri
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
```

Repeat the same pattern for `hono-command-router-secret`, `hono-adapter-http-secret`, `hono-adapter-mqtt-secret`, `hono-adapter-amqp-secret`, `hono-adapter-coap-secret`.

**Step 3: Create values file**

`manifests/hono/values-hono.yaml`:
```yaml
# Disable all bundled subcharts — use existing cluster services
mongodb:
  createInstance: false
kafka:
  createInstance: false
prometheus:
  createInstance: false
grafana:
  enabled: false

# External Kafka — Redpanda
# Hono expects Kafka bootstrap servers
kafka:
  bootstrapServers: "redpanda-0.redpanda.redpanda.svc.cluster.local:9092,redpanda-1.redpanda.redpanda.svc.cluster.local:9092,redpanda-2.redpanda.redpanda.svc.cluster.local:9092"

# ESO integration per service
authServer:
  useExternalSecret: true
  envSecret: hono-auth-secret

deviceRegistryExample:
  useExternalSecret: true
  envSecret: hono-device-registry-secret
  # Use MongoDB registry backend
  type: mongodb

commandRouter:
  useExternalSecret: true
  envSecret: hono-command-router-secret

adapters:
  http:
    enabled: true
    useExternalSecret: true
    envSecret: hono-adapter-http-secret
  mqtt:
    enabled: true
    useExternalSecret: true
    envSecret: hono-adapter-mqtt-secret
  amqp:
    enabled: true
    useExternalSecret: true
    envSecret: hono-adapter-amqp-secret
  coap:
    enabled: false  # enable when needed
```

**Step 4: Create ArgoCD app**

`apps/hono.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hono
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "8"
spec:
  project: default
  sources:
    - repoURL: https://github.com/fcraviolatti/packages.git
      targetRevision: k8s-deploy
      path: charts/hono
      helm:
        valueFiles:
          - $values/manifests/hono/values-hono.yaml
    - repoURL: git@github.com:fcraviolatti/k8s-on-lxd.git
      targetRevision: main
      ref: values
    - repoURL: git@github.com:fcraviolatti/k8s-on-lxd.git
      targetRevision: main
      path: manifests/hono
  destination:
    server: https://kubernetes.default.svc
    namespace: hono
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

**Step 5: Commit and verify**

```bash
git add apps/hono.yaml manifests/hono/
git commit -m "feat: add Hono ArgoCD app with ESO per-service secrets (wave 8)"
git push

kubectl get pods -n hono
# Expected: auth, device-registry, command-router, adapters Running
kubectl get externalsecret -n hono
# Expected: all 7 secrets Ready
```

---

## Phase 4 — HawkBit Chart Update

### Task 8: Update HawkBit chart to 0.9.0 with SeaweedFS + ESO support (packages repo)

**Files (packages repo):**
- Modify: `charts/hawkbit/Chart.yaml`
- Modify: `charts/hawkbit/values.yaml`
- Modify: `charts/hawkbit/templates/secrets.yaml`
- Modify: `charts/hawkbit/templates/deployment.yaml`

**Step 1: Update Chart.yaml**

```yaml
version: 1.8.0
appVersion: "0.9.0"
```

Keep mysql and rabbitmq as optional subcharts (for standalone use), but default to disabled.

**Step 2: Update image tag in values.yaml**

```yaml
image:
  repository: "hawkbit/hawkbit-update-server"
  tag: "0.9.0"
```

**Step 3: Add ESO flag and SeaweedFS storage config to values.yaml**

Add to `values.yaml`:
```yaml
# ESO integration
useExternalSecret: false   # when true, skip Secret generation for config.secrets
existingSecretName: ""     # name of existing Secret (must contain SPRING_APPLICATION_JSON key)

# Disable local file storage in favor of S3
fileStorage:
  enabled: false

# S3 artifact storage (SeaweedFS S3-compatible)
s3:
  enabled: false
  endpoint: ""
  region: "us-east-1"
  bucket: "hawkbit"
  accessKeyId: ""         # only used when useExternalSecret: false
  secretAccessKey: ""     # only used when useExternalSecret: false
```

Add S3 config to `config.application` section in values.yaml:
```yaml
config:
  application:
    spring:
      cloud:
        aws:
          s3:
            enabled: "{{ .Values.s3.enabled }}"
    hawkbit:
      artifact:
        repository:
          s3:
            bucketName: "{{ .Values.s3.bucket }}"
            region: "{{ .Values.s3.region }}"
            endpoint: "{{ .Values.s3.endpoint }}"
```

**Step 4: Update secrets.yaml template to support ESO**

`charts/hawkbit/templates/secrets.yaml`:
```yaml
{{- if not .Values.useExternalSecret }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ template "hawkbit.fullname" . }}
  labels:
{{ include "hawkbit.labels" . | indent 4 }}
type: Opaque
data:
  SPRING_APPLICATION_JSON: {{ .Values.config.secrets | toJson | b64enc }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ template "hawkbit.fullname" . }}-rabbitmq-pass
  labels:
    app.kubernetes.io/name: {{ include "hawkbit.name" . }}
    helm.sh/chart: {{ include "hawkbit.chart" . }}
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/managed-by: {{ .Release.Service }}
type: Opaque
data:
  rabbitmq-pass: {{ .Values.env.springRabbitmqPassword | b64enc | quote }}
{{- end }}
```

**Step 5: Update deployment.yaml to use existingSecretName when ESO enabled**

In `charts/hawkbit/templates/deployment.yaml`, find the `envFrom` section and add:
```yaml
envFrom:
  {{- if .Values.useExternalSecret }}
  - secretRef:
      name: {{ .Values.existingSecretName }}
  {{- else }}
  - secretRef:
      name: {{ template "hawkbit.fullname" . }}
  {{- end }}
```

**Step 6: Lint**

```bash
helm lint charts/hawkbit
helm template hawkbit charts/hawkbit --set useExternalSecret=true,existingSecretName=hawkbit-secret | grep -E "kind:|name:"
# Verify no Secret resource is generated when useExternalSecret=true
```

**Step 7: Commit**

```bash
git add charts/hawkbit/
git commit -m "feat(hawkbit): update to 0.9.0, add ESO support, SeaweedFS S3 artifact storage"
git push origin k8s-deploy
```

---

### Task 9: HawkBit Vault secrets + ExternalSecret + SeaweedFS bucket + ArgoCD app (k8s-on-lxd)

**Files (k8s-on-lxd):**
- Create: `manifests/hawkbit/externalsecret-hawkbit.yaml`
- Create: `manifests/hawkbit/values-hawkbit.yaml`
- Create: `manifests/hawkbit/kustomization.yaml`
- Create: `apps/hawkbit.yaml`

**Step 1: Create SeaweedFS bucket for HawkBit artifacts**

```bash
# Create hawkbit bucket in SeaweedFS (same pattern as thanos bucket)
kubectl exec -n seaweedfs $(kubectl get pod -n seaweedfs -l app=seaweedfs -o jsonpath='{.items[0].metadata.name}') -- \
  weed shell -master=seaweedfs-master-0.seaweedfs-master.seaweedfs.svc.cluster.local:9333 \
  <<'EOF'
s3.bucket.create -name hawkbit
EOF
```

**Step 2: Get SeaweedFS S3 credentials**

```bash
# SeaweedFS S3 credentials — check existing secret or config
kubectl get secret -n seaweedfs -o name | grep s3
```

**Step 3: Create Vault secrets for HawkBit**

```bash
MARIADB_PASS=$(kubectl exec -n vault vault-0 -- vault kv get -field=password secret/mariadb/hawkbit)
SEAWEEDFS_S3_ENDPOINT="http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333"
# Get SeaweedFS S3 access credentials from existing cluster config
SEAWEEDFS_ACCESS_KEY="<get-from-cluster>"
SEAWEEDFS_SECRET_KEY="<get-from-cluster>"

kubectl exec -n vault vault-0 -- vault kv put secret/hawkbit/db \
  url="jdbc:mariadb://mariadb.mariadb.svc.cluster.local:3306/hawkbit" \
  username="hawkbit" \
  password="${MARIADB_PASS}"

kubectl exec -n vault vault-0 -- vault kv put secret/hawkbit/admin \
  password="{noop}$(openssl rand -base64 16)"

kubectl exec -n vault vault-0 -- vault kv put secret/hawkbit/s3 \
  endpoint="${SEAWEEDFS_S3_ENDPOINT}" \
  region="us-east-1" \
  bucket="hawkbit" \
  accessKeyId="${SEAWEEDFS_ACCESS_KEY}" \
  secretAccessKey="${SEAWEEDFS_SECRET_KEY}"
```

**Step 4: Create ExternalSecret**

The HawkBit secret contains a JSON blob (`SPRING_APPLICATION_JSON`). ESO can build this via `target.template`:

`manifests/hawkbit/externalsecret-hawkbit.yaml`:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: hawkbit-secret
  namespace: hawkbit
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: hawkbit-secret
    template:
      data:
        SPRING_APPLICATION_JSON: |
          {
            "spring": {
              "datasource": {
                "url": "{{ .dbUrl }}",
                "username": "{{ .dbUsername }}",
                "password": "{{ .dbPassword }}"
              },
              "security": {
                "user": {
                  "password": "{{ .adminPassword }}"
                }
              }
            },
            "hawkbit": {
              "artifact": {
                "repository": {
                  "s3": {
                    "bucketName": "{{ .s3Bucket }}",
                    "region": "{{ .s3Region }}",
                    "endpoint": "{{ .s3Endpoint }}",
                    "accessKeyId": "{{ .s3AccessKey }}",
                    "secretAccessKey": "{{ .s3SecretKey }}"
                  }
                }
              }
            }
          }
  data:
    - secretKey: dbUrl
      remoteRef:
        key: hawkbit/db
        property: url
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: dbUsername
      remoteRef:
        key: hawkbit/db
        property: username
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: dbPassword
      remoteRef:
        key: hawkbit/db
        property: password
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: adminPassword
      remoteRef:
        key: hawkbit/admin
        property: password
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: s3Bucket
      remoteRef:
        key: hawkbit/s3
        property: bucket
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: s3Region
      remoteRef:
        key: hawkbit/s3
        property: region
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: s3Endpoint
      remoteRef:
        key: hawkbit/s3
        property: endpoint
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: s3AccessKey
      remoteRef:
        key: hawkbit/s3
        property: accessKeyId
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: s3SecretKey
      remoteRef:
        key: hawkbit/s3
        property: secretAccessKey
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
```

**Step 5: Create values file**

`manifests/hawkbit/values-hawkbit.yaml`:
```yaml
useExternalSecret: true
existingSecretName: hawkbit-secret

fileStorage:
  enabled: false

s3:
  enabled: true
  endpoint: "http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333"
  region: "us-east-1"
  bucket: "hawkbit"

# Disable bundled subcharts
mysql:
  enabled: false
rabbitmq:
  enabled: false

env:
  springDatasourceHost: ""  # overridden via SPRING_APPLICATION_JSON from secret
  springDatasourceDb: ""

ingress:
  enabled: false  # use Traefik Gateway API HTTPRoute
```

**Step 6: Create ArgoCD app**

`apps/hawkbit.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hawkbit
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "8"
spec:
  project: default
  sources:
    - repoURL: https://github.com/fcraviolatti/packages.git
      targetRevision: k8s-deploy
      path: charts/hawkbit
      helm:
        valueFiles:
          - $values/manifests/hawkbit/values-hawkbit.yaml
    - repoURL: git@github.com:fcraviolatti/k8s-on-lxd.git
      targetRevision: main
      ref: values
    - repoURL: git@github.com:fcraviolatti/k8s-on-lxd.git
      targetRevision: main
      path: manifests/hawkbit
  destination:
    server: https://kubernetes.default.svc
    namespace: hawkbit
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

**Step 7: Commit and verify**

```bash
git add apps/hawkbit.yaml manifests/hawkbit/
git commit -m "feat: add HawkBit ArgoCD app with ESO, MariaDB, SeaweedFS S3 (wave 8)"
git push

kubectl get pods -n hawkbit
# Expected: hawkbit pod Running
kubectl logs -n hawkbit deploy/hawkbit | grep -i "started\|error"
```

---

## Phase 5 — UI and Keycloak Integration

### Task 10: Ditto UI — Keycloak client + ArgoCD app (k8s-on-lxd)

**Files (k8s-on-lxd):**
- Create: `manifests/ditto-ui/externalsecret-ditto-ui-oidc.yaml`
- Create: `manifests/ditto-ui/httproute-ditto-ui.yaml`
- Create: `manifests/ditto-ui/values-ditto-ui.yaml`
- Create: `manifests/ditto-ui/kustomization.yaml`
- Create: `apps/ditto-ui.yaml`

**Step 1: Create Keycloak client for Ditto UI**

```bash
# Create OIDC client in Keycloak realm k8s
KEYCLOAK_TOKEN=$(curl -s -X POST \
  "https://keycloak.kube.craviols.eu/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=<admin-pass>" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -s -X POST \
  "https://keycloak.kube.craviols.eu/admin/realms/k8s/clients" \
  -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "ditto-ui",
    "name": "Eclipse Ditto UI",
    "enabled": true,
    "publicClient": true,
    "redirectUris": ["https://ditto.kube.craviols.eu/*"],
    "webOrigins": ["https://ditto.kube.craviols.eu"],
    "standardFlowEnabled": true
  }'
```

Note: Ditto UI is a public client (SPA), no client secret needed.

**Step 2: Create HTTPRoute for Ditto**

Create HTTPRoute for both Ditto gateway API and Ditto UI in `manifests/ditto-ui/`.

**Step 3: Create ArgoCD app for Ditto UI**

`apps/ditto-ui.yaml` — deploys `eclipse-ditto/ditto-ui` image with Keycloak OIDC env vars:
```yaml
# Deployment with env vars:
# DITTO_API_URI: https://ditto.kube.craviols.eu
# OAUTH2_CLIENT_ID: ditto-ui
# OAUTH2_PROVIDER: keycloak
# OAUTH2_OPENID_CONNECT_URL: https://keycloak.kube.craviols.eu/realms/k8s/.well-known/openid-configuration
```

**Step 4: Commit and verify**

```bash
git add apps/ditto-ui.yaml manifests/ditto-ui/
git commit -m "feat: add Ditto UI ArgoCD app with Keycloak OIDC (wave 8)"
git push
```

---

### Task 11: HawkBit oauth2-proxy — Keycloak client + ArgoCD app (k8s-on-lxd)

**Files (k8s-on-lxd):**
- Create: `manifests/hawkbit-proxy/externalsecret-hawkbit-oidc.yaml`
- Create: `manifests/hawkbit-proxy/httproute-hawkbit.yaml`
- Create: `manifests/hawkbit-proxy/values-hawkbit-proxy.yaml`
- Create: `manifests/hawkbit-proxy/kustomization.yaml`
- Create: `apps/hawkbit-proxy.yaml`

**Step 1: Create Keycloak client for HawkBit**

```bash
# Confidential client for oauth2-proxy
curl -s -X POST \
  "https://keycloak.kube.craviols.eu/admin/realms/k8s/clients" \
  -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "clientId": "hawkbit",
    "name": "Eclipse HawkBit",
    "enabled": true,
    "publicClient": false,
    "redirectUris": ["https://hawkbit.kube.craviols.eu/oauth2/callback"],
    "standardFlowEnabled": true
  }'

# Get client UUID and secret
CLIENT_UUID=$(curl -s "https://keycloak.kube.craviols.eu/admin/realms/k8s/clients?clientId=hawkbit" \
  -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

CLIENT_SECRET=$(curl -s -X POST \
  "https://keycloak.kube.craviols.eu/admin/realms/k8s/clients/${CLIENT_UUID}/client-secret" \
  -H "Authorization: Bearer ${KEYCLOAK_TOKEN}" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")

# Store in Vault
kubectl exec -n vault vault-0 -- vault kv put secret/hawkbit/oidc \
  clientId="hawkbit" \
  clientSecret="${CLIENT_SECRET}" \
  cookieSecret="$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)"
```

**Step 2: Create ExternalSecret for oauth2-proxy**

`manifests/hawkbit-proxy/externalsecret-hawkbit-oidc.yaml` — same pattern as n8n/redisinsight oauth2-proxy secrets.

**Step 3: Deploy oauth2-proxy**

`apps/hawkbit-proxy.yaml` — oauth2-proxy deployment with:
```yaml
# oauth2-proxy args (same pattern as n8n):
--provider=oidc
--oidc-issuer-url=https://keycloak.kube.craviols.eu/realms/k8s
--upstream=http://hawkbit.hawkbit.svc.cluster.local:8080
--redirect-url=https://hawkbit.kube.craviols.eu/oauth2/callback
--code-challenge-method=S256
--cookie-secure=true
--email-domain=*
```

**Step 4: Create HTTPRoute routing traffic through oauth2-proxy**

`manifests/hawkbit-proxy/httproute-hawkbit.yaml` — routes `hawkbit.kube.craviols.eu` to oauth2-proxy service, not directly to HawkBit.

**Step 5: Commit and verify**

```bash
git add apps/hawkbit-proxy.yaml manifests/hawkbit-proxy/
git commit -m "feat: add HawkBit oauth2-proxy with Keycloak OIDC (wave 8)"
git push

# Test: curl https://hawkbit.kube.craviols.eu
# Expected: redirect to Keycloak login
# After login: HawkBit management UI visible
```

---

## Verification Checklist

After all tasks complete:

```bash
# All pods running
kubectl get pods -n mongodb
kubectl get pods -n ditto
kubectl get pods -n hono
kubectl get pods -n hawkbit

# All ExternalSecrets Ready
kubectl get externalsecret -A | grep -E "ditto|hono|hawkbit|mongodb"

# All ArgoCD apps Synced+Healthy
kubectl get applications -n argocd | grep -E "mongodb|ditto|hono|hawkbit|percona"

# Connectivity test — Ditto API
curl -u devops:<password> https://ditto.kube.craviols.eu/api/2/things

# HawkBit UI accessible via Keycloak
curl -I https://hawkbit.kube.craviols.eu
# Expected: 302 to Keycloak
```
