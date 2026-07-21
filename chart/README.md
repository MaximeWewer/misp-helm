# Misp Helm

Helm chart for [MISP](https://github.com/MISP/MISP).

## Architecture

| Component | Type | Role |
|-----------|------|------|
| `core` | Deployment | misp-core: web (nginx + php-fpm) **+ workers + cron** (supervisor) in a single pod. Ports 80/443. PVC `data` (subPaths Config/files/gnupg/logs). `strategy: Recreate` (RWO single-writer) |
| `modules` | Deployment | misp-modules (enrichment/import/export, :6666). Service named `misp-modules` (the default the core image expects) |
| `mail` | Deployment | SMTP relay (egos-tech/smtp). Optional |
| `guard` | Deployment | misp-guard, sync filtering proxy (:8888). Optional — requires a real `config.json` |

**Bundled dependencies:**

- **MariaDB** via the **[mariadb-operator](https://github.com/mariadb-operator/mariadb-operator)** operator — `MariaDB` CR (`k8s.mariadb.com/v1alpha1`), root + MISP user from the chart secret, InnoDB tuning (`myCnf`).
- **Redis** via the **[CloudPirates redis](https://github.com/CloudPirates-io/helm-charts/tree/main/charts/redis)** chart (OCI dependency), **auth enabled** (MISP supports `REDIS_PASSWORD`). The sub-chart generates the password in `<release>-redis` (key `redis-password`), read by misp-core.

## Prerequisites

- A Kubernetes cluster, Helm **3+**.
- **mariadb-operator + its CRDs** installed cluster-wide (this chart ships only the `MariaDB` CR):
  ```sh
  helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator
  helm install mariadb-operator mariadb-operator/mariadb-operator -n mariadb-operator --create-namespace
  ```
- **Redis** is pulled as a bundled dependency — run `helm dependency build .` before installing.

## Install

```sh
helm dependency build .
# config.baseUrl is REQUIRED
helm install misp . -n cti --create-namespace \
  --set config.baseUrl=https://misp.example.com
```

Secrets are generated automatically (`mysql-root-password`, `mysql-password`, `admin-password`, `admin-key`, `gpg-passphrase`, `encryption-key`, `salt`) when `config.existingSecret` is not provided. Admin password:

```sh
kubectl get secret -n cti misp-secret -o jsonpath='{.data.admin-password}' | base64 -d
```

Per-key resolution when `config.existingSecret` is empty: inline `config.secrets.*` > existing in-cluster Secret (`lookup`) > generated random.

**ArgoCD without a secret manager:** set the values inline under `config.secrets` (`mysqlRootPassword`, `mysqlPassword`, `adminPassword`, `adminKey`, `gpgPassphrase`, `encryptionKey`, `salt`). Argo's `lookup` is unreliable during diff/sync, so an unset key re-rolls to a new random each sync and breaks the DB and admin login; inline values are deterministic and stable.

## Security

- Hardened `containerSecurityContext`: `allowPrivilegeEscalation:false`, `drop:[ALL]` + the minimal caps the nginx/php-fpm/cron stack requires (`CHOWN/SETUID/SETGID/DAC_OVERRIDE/AUDIT_WRITE`), `seccompProfile:RuntimeDefault`.
- `automountServiceAccountToken:false`.
- **`podSecurityContext.runAsNonRoot:false`** by default (misp-core runs nginx+php-fpm as root via supervisor) — harden after verifying the uids.
- NetworkPolicy: core ingress restricted (`networkPolicy.coreAllowedFrom`), intra-app traffic limited. **Egress** DNS + intra-namespace; MISP **external feeds** need outbound egress via `networkPolicy.extraEgress`.
- Secrets never in cleartext in the values: use `config.existingSecret` (ESO/Vault) in production.

## Configuration

MISP reads ~150 env variables (see [template.env](https://github.com/MISP/misp-docker/blob/master/template.env)). The chart wires the essentials (DB, Redis, admin, crypto, SMTP); the rest goes through:

- **`config.extraEnv`**: additional structured env (OIDC_*, LDAPAUTH_*, AAD_*, PROXY_*, S3_*, SYNCSERVERS_*, PHP_*, NGINX_*).
- **`config.extraEnvFrom`**: the same from a Secret/ConfigMap (OIDC/LDAP/S3 creds…).

## Metrics (Prometheus)

Upstream MISP ships **no** Prometheus endpoint: neither misp-core, misp-modules, misp-guard nor the SMTP relay expose `/metrics`. What is actually scrapeable is wired here:

| App | Exporter | Owner | Port |
|-----|----------|-------|------|
| `misp-core` | [php-fpm_exporter](https://github.com/hipages/php-fpm_exporter) sidecar (php-fpm pool stats) | this chart | 9253 |
| `mariadb` | `mysqld-exporter` | mariadb-operator (`MariaDB.spec.metrics`) | 9104 |
| `redis` | `redis_exporter` | CloudPirates sub-chart | 9121 |

```sh
helm upgrade --install misp . -n cti \
  --set config.baseUrl=https://misp.example.com \
  --set metrics.enabled=true \
  --set metrics.serviceMonitor.enabled=true \
  --set 'metrics.serviceMonitor.labels.release=kube-prometheus-stack' \
  --set redis.metrics.enabled=true \
  --set redis.metrics.serviceMonitor.enabled=true
```

- `metrics.enabled` drives only the exporters this chart owns (core sidecar + `MariaDB.spec.metrics`). **Redis is a sub-chart**: Helm cannot template sub-chart values, so `redis.metrics.*` must be set explicitly.
- misp-core: the image only wires `pm.status_path` when `FASTCGI_STATUS_LISTEN` is non-empty. The chart sets it (`metrics.core.statusPort`, default 8999) so php-fpm opens `unix:/run/php/php-fpm-status.sock`, shared with the sidecar through an `emptyDir`; the sidecar talks **FastCGI directly**, no nginx hop. The exporter runs as `www-data` (uid 33) to match the socket ownership.
- The exporter is published on a **separate** `<release>-core-metrics` ClusterIP Service, so it is never exposed by `core.service.type: LoadBalancer/NodePort`.
- The MariaDB ServiceMonitor is created by the **operator**, not by this chart. `metrics.serviceMonitor.prometheusRelease` (falling back to `metrics.serviceMonitor.labels.release`) is passed to the CR so it carries the right label.
- With `networkPolicy.enabled`, an ingress rule opens the core metrics port — `metrics.allowedFrom` restricts the peers (empty = any namespace, metrics port only).
- Application-level MISP metrics (event/feed/user counts) only exist out of tree as an API poller writing node_exporter textfiles ([Truesec/misp-metricsexporter](https://github.com/Truesec/misp-metricsexporter)) — not an HTTP endpoint, so it is not wired here.

## Main values

| Key | Default | Description |
|-----|---------|-------------|
| `config.baseUrl` | `""` | **REQUIRED** — public MISP URL |
| `config.existingSecret` | `""` | Creds secret (otherwise generated) |
| `config.secrets.*` | `""` | Inline creds (no secret manager / ArgoCD-safe); per key: inline > lookup > random |
| `config.adminEmail` / `config.adminOrg` | `admin@admin.test` / `ORGNAME` | Initial admin |
| `core.image.tag` | `v2.5.43` | misp-core version |
| `modules.enabled` / `modules.serviceName` | `true` / `misp-modules` | Modules (service name the image expects) |
| `mail.enabled` | `true` | SMTP relay (otherwise external SMTP via extraEnv) |
| `guard.enabled` / `guard.config` | `true` / skeleton | Sync filtering proxy (config.json to provide) |
| `mariadb.enabled` | `true` | MariaDB CR (operator required) |
| `redis.enabled` | `true` | CloudPirates sub-chart (auth on) |
| `externalRedis.host` | `""` | External Redis (otherwise the sub-chart) |
| `persistence.size` | `10Gi` | core PVC (Config/files/gnupg/logs) |
| `ingress.enabled` | `false` | core Ingress (TLS at the ingress → `DISABLE_SSL_REDIRECT=true` via extraEnv) |
| `networkPolicy.enabled` | `true` | NetworkPolicy |
| `metrics.enabled` | `false` | Prometheus exporters owned by the chart (core sidecar + MariaDB CR) |
| `metrics.serviceMonitor.enabled` | `false` | ServiceMonitor (prometheus-operator CRDs required) |
| `redis.metrics.enabled` | `false` | redis_exporter (sub-chart switch, not gated on `metrics.enabled`) |

## Notes

- `core` = web + workers + cron (supervisor) in 1 pod; RWO + `Recreate`.
- Slow first boot (DB migrations + GPG) → tolerant `startupProbe` (`/users/heartbeat`).
- **`config.enableBackgroundUpdates: true`** (default) is required: the image's base schema lags the app, recent tables (e.g. `bookmarks`) are created by the updates at boot. Without it, authenticated endpoints return 500 (`MissingTableException`) until a manual `cake Admin runUpdates`. **Validated live on minikube** (`/servers/getVersion` → 200 after the updates are applied).
- `misp-modules`: keep the service named `misp-modules` (the core image default) unless you override the `Plugin.*_services_url` settings.
- `misp-guard`: provide a real `guard.config` (ruleset), otherwise filtering is non-functional (isolated from core).

## Requirements

| Repository | Name | Version |
|------------|------|---------|
| oci://registry-1.docker.io/cloudpirates | redis | 0.32.* |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| config.adminEmail | string | `"admin@admin.test"` |  |
| config.adminOrg | string | `"ORGNAME"` |  |
| config.baseUrl | string | `""` |  |
| config.enableBackgroundUpdates | bool | `true` |  |
| config.existingSecret | string | `""` |  |
| config.extraEnv | list | `[]` |  |
| config.extraEnvFrom | list | `[]` |  |
| config.initImage | string | `"busybox:1.36"` |  |
| config.secrets.adminKey | string | `""` |  |
| config.secrets.adminPassword | string | `""` |  |
| config.secrets.encryptionKey | string | `""` |  |
| config.secrets.gpgPassphrase | string | `""` |  |
| config.secrets.mysqlPassword | string | `""` |  |
| config.secrets.mysqlRootPassword | string | `""` |  |
| config.secrets.salt | string | `""` |  |
| config.timezone | string | `"UTC"` |  |
| containerSecurityContext.allowPrivilegeEscalation | bool | `false` |  |
| containerSecurityContext.capabilities.add[0] | string | `"CHOWN"` |  |
| containerSecurityContext.capabilities.add[1] | string | `"SETUID"` |  |
| containerSecurityContext.capabilities.add[2] | string | `"SETGID"` |  |
| containerSecurityContext.capabilities.add[3] | string | `"DAC_OVERRIDE"` |  |
| containerSecurityContext.capabilities.add[4] | string | `"AUDIT_WRITE"` |  |
| containerSecurityContext.capabilities.add[5] | string | `"NET_BIND_SERVICE"` |  |
| containerSecurityContext.capabilities.add[6] | string | `"FOWNER"` |  |
| containerSecurityContext.capabilities.drop[0] | string | `"ALL"` |  |
| containerSecurityContext.privileged | bool | `false` |  |
| core.affinity | object | `{}` |  |
| core.image.digest | string | `""` |  |
| core.image.repository | string | `"ghcr.io/misp/misp-docker/misp-core"` |  |
| core.image.tag | string | `"v2.5.43"` |  |
| core.nodeSelector | object | `{}` |  |
| core.replicas | int | `1` |  |
| core.resources.limits.cpu | string | `"2"` |  |
| core.resources.limits.memory | string | `"4Gi"` |  |
| core.resources.requests.cpu | string | `"500m"` |  |
| core.resources.requests.memory | string | `"1Gi"` |  |
| core.service.httpPort | int | `80` |  |
| core.service.httpsPort | int | `443` |  |
| core.service.type | string | `"ClusterIP"` |  |
| core.tolerations | list | `[]` |  |
| externalRedis.existingSecret | string | `""` |  |
| externalRedis.existingSecretPasswordKey | string | `"redis-password"` |  |
| externalRedis.host | string | `""` |  |
| externalRedis.port | int | `6379` |  |
| fullnameOverride | string | `""` |  |
| guard.args | string | `""` |  |
| guard.config | string | `"{\n  \"allowlist\": { \"domains\": [], \"urls\": [] },\n  \"compartments_rules\": { \"can_reach\": {} },\n  \"instances\": {}\n}\n"` |  |
| guard.enabled | bool | `true` |  |
| guard.image.digest | string | `""` |  |
| guard.image.repository | string | `"ghcr.io/misp/misp-docker/misp-guard"` |  |
| guard.image.tag | string | `"v1.2"` |  |
| guard.nodeSelector | object | `{}` |  |
| guard.port | int | `8888` |  |
| guard.resources | object | `{}` |  |
| image.pullPolicy | string | `"Always"` |  |
| image.registry | string | `""` |  |
| imagePullSecrets | list | `[]` |  |
| ingress.annotations | object | `{}` |  |
| ingress.className | string | `""` |  |
| ingress.enabled | bool | `false` |  |
| ingress.host | string | `"misp.example.com"` |  |
| ingress.tls | list | `[]` |  |
| mail.enabled | bool | `true` |  |
| mail.extraEnv | list | `[]` |  |
| mail.image.digest | string | `""` |  |
| mail.image.repository | string | `"ghcr.io/egos-tech/smtp"` |  |
| mail.image.tag | string | `"1.1.3"` |  |
| mail.nodeSelector | object | `{}` |  |
| mail.resources | object | `{}` |  |
| mariadb.database | string | `"misp"` |  |
| mariadb.enabled | bool | `true` |  |
| mariadb.image | string | `"mariadb:10.11"` |  |
| mariadb.myCnf | string | `"[mariadb]\nbind-address=*\ndefault_storage_engine=InnoDB\ninnodb_buffer_pool_size=2048M\ninnodb_change_buffering=none\ninnodb_io_capacity=1000\ninnodb_io_capacity_max=2000\ninnodb_log_file_size=600M\ninnodb_read_io_threads=16\ninnodb_write_io_threads=4\nmax_allowed_packet=256M\n"` |  |
| mariadb.resources.limits.memory | string | `"2Gi"` |  |
| mariadb.resources.requests.cpu | string | `"300m"` |  |
| mariadb.resources.requests.memory | string | `"512Mi"` |  |
| mariadb.storage.size | string | `"10Gi"` |  |
| mariadb.storage.storageClassName | string | `""` |  |
| mariadb.username | string | `"misp"` |  |
| metrics.allowedFrom | list | `[]` |  |
| metrics.core.enabled | bool | `true` |  |
| metrics.core.image.digest | string | `""` |  |
| metrics.core.image.repository | string | `"hipages/php-fpm_exporter"` |  |
| metrics.core.image.tag | string | `"2.2.0"` |  |
| metrics.core.port | int | `9253` |  |
| metrics.core.resources | object | `{}` |  |
| metrics.core.securityContext.allowPrivilegeEscalation | bool | `false` |  |
| metrics.core.securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| metrics.core.securityContext.privileged | bool | `false` |  |
| metrics.core.securityContext.runAsGroup | int | `33` |  |
| metrics.core.securityContext.runAsNonRoot | bool | `true` |  |
| metrics.core.securityContext.runAsUser | int | `33` |  |
| metrics.core.statusPort | int | `8999` |  |
| metrics.enabled | bool | `false` |  |
| metrics.mariadb.enabled | bool | `true` |  |
| metrics.mariadb.image | string | `""` |  |
| metrics.mariadb.port | int | `9104` |  |
| metrics.mariadb.resources | object | `{}` |  |
| metrics.serviceMonitor.annotations | object | `{}` |  |
| metrics.serviceMonitor.enabled | bool | `false` |  |
| metrics.serviceMonitor.honorLabels | bool | `false` |  |
| metrics.serviceMonitor.interval | string | `"30s"` |  |
| metrics.serviceMonitor.labels | object | `{}` |  |
| metrics.serviceMonitor.metricRelabelings | list | `[]` |  |
| metrics.serviceMonitor.namespace | string | `""` |  |
| metrics.serviceMonitor.prometheusRelease | string | `""` |  |
| metrics.serviceMonitor.relabelings | list | `[]` |  |
| metrics.serviceMonitor.scrapeTimeout | string | `""` |  |
| modules.enabled | bool | `true` |  |
| modules.image.digest | string | `""` |  |
| modules.image.repository | string | `"ghcr.io/misp/misp-docker/misp-modules"` |  |
| modules.image.tag | string | `"v3.0.8"` |  |
| modules.nodeSelector | object | `{}` |  |
| modules.port | int | `6666` |  |
| modules.replicas | int | `1` |  |
| modules.resources | object | `{}` |  |
| modules.serviceName | string | `"misp-modules"` |  |
| nameOverride | string | `""` |  |
| networkPolicy.coreAllowedFrom | list | `[]` |  |
| networkPolicy.enabled | bool | `true` |  |
| networkPolicy.extraEgress | list | `[]` |  |
| persistence.accessModes[0] | string | `"ReadWriteOnce"` |  |
| persistence.enabled | bool | `true` |  |
| persistence.existingClaim | string | `""` |  |
| persistence.size | string | `"10Gi"` |  |
| persistence.storageClass | string | `""` |  |
| podDisruptionBudget.enabled | bool | `false` |  |
| podDisruptionBudget.maxUnavailable | string | `""` |  |
| podDisruptionBudget.minAvailable | string | `""` |  |
| podSecurityContext.runAsNonRoot | bool | `false` |  |
| podSecurityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| redis.auth.enabled | bool | `true` |  |
| redis.enabled | bool | `true` |  |
| redis.metrics.enabled | bool | `false` |  |
| redis.metrics.serviceMonitor.enabled | bool | `false` |  |
| redis.metrics.serviceMonitor.interval | string | `"30s"` |  |
| redis.metrics.serviceMonitor.selector | object | `{}` |  |
| redis.persistence.enabled | bool | `true` |  |
| redis.persistence.size | string | `"2Gi"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.automountServiceAccountToken | bool | `false` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
