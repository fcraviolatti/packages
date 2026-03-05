# Chart Modernization Design

**Date**: 2026-03-05
**Branch**: `k8s-deploy`
**Scope**: Ditto, Hono, HawkBit Helm charts — version upgrade, ESO support, external dependencies, Keycloak OIDC

---

## Context

The `packages` repo contains local Helm charts for Eclipse Ditto, Hono, and HawkBit. These charts are outdated (Ditto is marked deprecated), have no ESO support, and bundle their own dependencies (MongoDB, MySQL, Kafka) instead of using the production-grade operators already deployed in the cluster.

Goal: modernize the charts so they can be deployed via ArgoCD on the existing cluster, using existing infrastructure and Vault-managed secrets via External Secrets Operator.

---

## Version Upgrades

| Chart | Current appVersion | Target appVersion |
|-------|--------------------|-------------------|
| Ditto | 3.2.1 | 3.8.12 |
| Hono | 2.6.0 | 2.7.0 |
| HawkBit | 0.5.0-mysql | 0.9.0 |

---

## Architecture

### Approach: Wrapper Minimum (Approach A)

Each chart becomes a thin wrapper that:
- Points to the upstream OCI/Helm chart as a dependency (for Ditto) or updates images in-place (Hono, HawkBit)
- Disables all bundled subcharts (MongoDB, MySQL, Kafka, RabbitMQ)
- Adds `useExternalSecret` flag to skip native Secret generation
- Adds `existingSecretName` value to reference ESO-managed secrets

This maximizes upgradability: bumping a version = changing one line in `Chart.yaml` or `values.yaml`.

### Repository Split

- **`packages` repo** (`k8s-deploy` branch): Helm chart sources (wrappers)
- **`k8s-on-lxd` repo**: ArgoCD Application manifests + `manifests/<app>/` with values and ExternalSecrets

---

## New Infrastructure

### MongoDB (Percona Operator)

**Why Percona Operator**: production-grade HA (ReplicaSet 3 nodes), integrated backup via Percona Backup for MongoDB (PBM), monitoring integration, fully open source. Consistent with the HA-first pattern used for MariaDB (Galera 3 nodes) and Redpanda (3 brokers).

**New ArgoCD apps** in `k8s-on-lxd`:

| Wave | App | Namespace | Description |
|------|-----|-----------|-------------|
| 4 | `percona-mongodb-operator` | `mongodb` | Percona Operator CRDs + controller |
| 5 | `mongodb` | `mongodb` | PerconaServerMongoDB CR — 3-node ReplicaSet |

**Database layout** (one ReplicaSet, separate databases):
- `ditto-things`, `ditto-connectivity`, `ditto-policies`, `ditto-search` — Ditto
- `hono-device-registry` — Hono device registry

---

## Existing Infrastructure Reused

| Service | Used by | Already deployed |
|---------|---------|-----------------|
| MariaDB (mariadb-operator) | HawkBit | ✅ DB `hawkbit`, user `hawkbit` ready |
| Redpanda | Hono (Kafka) | ✅ 3-broker cluster |
| SeaweedFS | HawkBit artifact storage | ✅ S3-compatible endpoint |
| Vault + ESO | All secrets | ✅ ClusterSecretStore `vault-backend` |
| Keycloak (realm `k8s`) | OIDC for UIs | ✅ |
| cert-manager + Traefik | TLS + routing | ✅ |

---

## Chart Design Details

### Ditto (`charts/ditto/`)

Transform from deprecated local chart to OCI wrapper:

- `Chart.yaml`: dependency `oci://registry-1.docker.io/eclipse/ditto` version `3.8.12`, remove MongoDB subchart
- `values.yaml`: `mongodb.enabled: false`, all connection strings reference external secrets
- ESO secrets (in `k8s-on-lxd/manifests/ditto/`):
  - `ditto-gateway-secret` — devops password, status password (Vault: `ditto/gateway`)
  - `ditto-mongodb-secret` — URIs for things/connectivity/policies/search DBs (Vault: `ditto/mongodb`)
- ESO flag: `gateway.useExternalSecret: true`, `dbconfig.useExternalSecret: true`

**Ditto UI**: separate ArgoCD app deploying `eclipse-ditto/ditto-ui` with native OIDC Keycloak config (Ditto UI supports OIDC natively).

### Hono (`charts/hono/`)

In-place update of local chart:

- All `eclipsehono/*` images updated to `2.7.0`
- `Chart.yaml` version bump to `2.7.0`
- Subcharts disabled: `mongodb.createInstance: false`, `kafka.createInstance: false`, `prometheus.createInstance: false`, `grafana.enabled: false`
- External connections configured via values: MongoDB URI, Kafka bootstrap servers (Redpanda)
- ESO flag `useExternalSecret: true` per service, `existingSecretName` references ESO-created secret

**Per-service ExternalSecrets** (in `k8s-on-lxd/manifests/hono/`):
- `hono-auth-secret` (Vault: `hono/auth`)
- `hono-device-registry-secret` (Vault: `hono/device-registry`)
- `hono-command-router-secret` (Vault: `hono/command-router`)
- `hono-adapter-http-secret` (Vault: `hono/adapter-http`)
- `hono-adapter-mqtt-secret` (Vault: `hono/adapter-mqtt`)
- `hono-adapter-amqp-secret` (Vault: `hono/adapter-amqp`)
- `hono-adapter-coap-secret` (Vault: `hono/adapter-coap`)

Hono has no dedicated management UI — API only, no OIDC integration needed in the chart.

### HawkBit (`charts/hawkbit/`)

In-place update with storage and DB backend changes:

- Image updated to `hawkbit/hawkbit-update-server:0.9.0`
- `Chart.yaml` version bump, appVersion `0.9.0`
- `mysql.enabled: false`, `rabbitmq.enabled: false`
- `fileStorage.enabled: false` (replaced by S3)
- Added Spring config for external MariaDB: `spring.datasource.url/username/password`
- Added Spring config for SeaweedFS S3 artifact storage:
  ```
  hawkbit.artifact.repository.s3.bucketName
  hawkbit.artifact.repository.s3.region
  hawkbit.artifact.repository.s3.endpoint
  hawkbit.artifact.repository.s3.accessKeyId
  hawkbit.artifact.repository.s3.secretAccessKey
  ```
- ESO flag: `useExternalSecret: true`, single `hawkbit-secret` (Vault paths: `hawkbit/db`, `hawkbit/admin`, `hawkbit/s3`)

**UI / Keycloak**: oauth2-proxy in front of the HawkBit management UI — same pattern as n8n and RedisInsight. Separate ExternalSecret for oauth2-proxy OIDC client secret (Vault: `hawkbit/oidc`).

---

## ArgoCD Application Map (k8s-on-lxd)

```
Wave 4: percona-mongodb-operator   (namespace: mongodb)
Wave 5: mongodb                    (namespace: mongodb)  ← waits for operator CRDs
Wave 8: ditto                      (namespace: ditto)    ← waits for mongodb
Wave 8: hono                       (namespace: hono)     ← waits for mongodb + redpanda
Wave 8: hawkbit                    (namespace: hawkbit)  ← waits for mariadb + seaweedfs
Wave 8: ditto-ui                   (namespace: ditto)    ← waits for ditto + keycloak
Wave 8: hawkbit-proxy              (namespace: hawkbit)  ← oauth2-proxy for hawkbit UI
```

---

## ESO Secret Pattern (uniform across all apps)

```yaml
# In chart values.yaml
someService:
  useExternalSecret: false       # default: generate secret from values
  existingSecretName: ""         # when useExternalSecret: true, reference this secret

# In chart template
{{- if not .Values.someService.useExternalSecret }}
apiVersion: v1
kind: Secret
...
{{- end }}
```

ExternalSecrets in `k8s-on-lxd/manifests/<app>/` always have `argocd.argoproj.io/sync-wave: "-1"` to ensure secrets exist before the chart deploys.

All ExternalSecret remoteRef entries include ESO default fields explicitly to prevent OutOfSync drift:
```yaml
remoteRef:
  conversionStrategy: Default
  decodingStrategy: None
  metadataPolicy: None
```

---

## Vault Secret Layout

```
secret/
  ditto/
    gateway       → devopsPassword, statusPassword
    mongodb       → thingsUri, connectivityUri, policiesUri, searchUri
  hono/
    auth          → authPassword (and other service credentials)
    device-registry → mongodbUri, credentials
    command-router  → credentials
    adapter-http    → credentials
    adapter-mqtt    → credentials
    adapter-amqp    → credentials
    adapter-coap    → credentials
  hawkbit/
    db            → username, password, url
    admin         → password
    s3            → accessKeyId, secretAccessKey, endpoint, bucket
    oidc          → clientId, clientSecret, cookieSecret
  mongodb/
    root          → rootPassword
    ditto         → password
    hono          → password
```

---

## Keycloak Clients Required

| Client ID | Used by | Type |
|-----------|---------|------|
| `ditto-ui` | Ditto UI native OIDC | OIDC public/confidential |
| `hawkbit` | oauth2-proxy for HawkBit | OIDC confidential |
