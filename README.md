# MISP Helm Chart

Helm chart for [MISP](https://github.com/MISP/MISP) on Kubernetes.

## Features

- misp-core (web + workers + cron), misp-modules, optional SMTP relay and misp-guard
- MariaDB via the [mariadb-operator](https://github.com/mariadb-operator/mariadb-operator) (`MariaDB` CR)
- Redis via the [CloudPirates](https://github.com/CloudPirates-io/helm-charts) chart (auth enabled)
- NetworkPolicies, PodDisruptionBudget, hardened securityContext, generate-once secrets
- `extraEnv` / `extraEnvFrom` for the ~150 MISP env variables (OIDC/LDAP/S3/sync…)
- Automated weekly version updates tracking upstream MISP releases

## Prerequisites

- A Kubernetes cluster, Helm **3+**.
- **mariadb-operator + its CRDs** installed cluster-wide (this chart ships only the `MariaDB` CR):
  ```sh
  helm repo add mariadb-operator https://helm.mariadb.com/mariadb-operator
  helm install mariadb-operator mariadb-operator/mariadb-operator -n mariadb-operator --create-namespace
  ```

## Installation

### Helm (OCI)

```bash
helm install misp oci://ghcr.io/maximewewer/charts/misp \
  --namespace cti --create-namespace \
  --set config.baseUrl=https://misp.example.com
```

### From source

```bash
git clone https://github.com/MaximeWewer/misp-helm.git
cd misp-helm
helm dependency build chart/
helm install misp chart/ \
  --namespace cti --create-namespace \
  --set config.baseUrl=https://misp.example.com
```

### Argo CD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: misp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ghcr.io/maximewewer/charts
    chart: misp
    targetRevision: "<chart-version>"   # pin a published version
    helm:
      values: |
        config:
          baseUrl: https://misp.example.com
  destination:
    server: https://kubernetes.default.svc
    namespace: cti
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

Secrets are generated automatically when `config.existingSecret` is not provided. Admin password:

```bash
kubectl get secret -n cti misp-secret -o jsonpath='{.data.admin-password}' | base64 -d
```

Per-key resolution when `config.existingSecret` is empty: inline `config.secrets.*` > existing in-cluster Secret (`lookup`) > generated random. With **ArgoCD and no secret manager**, set the values inline under `config.secrets` — Argo's `lookup` is unreliable during diff/sync, so an unset key re-rolls to a new random each sync and breaks the DB and admin login.

## Configuration

See the full list of configurable values in [`chart/README.md`](chart/README.md).

## License

This chart is distributed under the [Apache License 2.0](LICENSE). MISP itself is licensed by the MISP Project.
