# EKS Cluster Bootstrap Architecture
### Multi-Region | Multi-Env (Prod/UAT/SIT) | Harness + Helm | TFE

---

## Overview & Design Philosophy

The goal is a **single helm-chart-per-addon** approach where:
- Charts are **templated once**, values files drive environment differences
- Harness orchestrates deploys — no human runs `helm install` manually
- All cluster addons are deployed in a **fixed dependency order**
- New regions/clusters are onboarded by creating a new values file, not new code

---

## Repository Structure

```
eks-bootstrap/
│
├── README.md
│
├── charts/                          # One chart per addon (or wrapper chart)
│   ├── namespaces/                  # Creates empty namespaces
│   │   ├── Chart.yaml
│   │   ├── templates/
│   │   │   └── namespace.yaml
│   │   └── values.yaml              # Base (empty list)
│   │
│   ├── external-secrets-operator/   # ESO chart wrapper
│   │   ├── Chart.yaml
│   │   ├── templates/
│   │   │   ├── helmrelease.yaml     # Wraps upstream ESO chart
│   │   │   └── clusterSecretStore.yaml
│   │   └── values.yaml
│   │
│   ├── aws-load-balancer-controller/
│   │   ├── Chart.yaml
│   │   ├── templates/
│   │   │   └── helmrelease.yaml
│   │   └── values.yaml
│   │
│   ├── nginx-ingress/
│   │   ├── Chart.yaml
│   │   ├── templates/
│   │   │   └── helmrelease.yaml
│   │   └── values.yaml
│   │
│   ├── target-group-binding/
│   │   ├── Chart.yaml
│   │   ├── templates/
│   │   │   └── targetgroupbinding.yaml
│   │   └── values.yaml
│   │
│   └── _common/                     # Shared helpers / NOTES.txt
│       └── _helpers.tpl
│
├── environments/
│   ├── us-east-1/
│   │   ├── prod/
│   │   │   ├── cluster.yaml         # Cluster metadata (name, account, IRSA ARNs)
│   │   │   ├── namespaces.yaml
│   │   │   ├── eso.yaml
│   │   │   ├── alb-controller.yaml
│   │   │   ├── nginx-ingress.yaml
│   │   │   └── target-group-binding.yaml
│   │   ├── uat/
│   │   │   └── ... (same files)
│   │   └── sit/
│   │       └── ... (same files)
│   │
│   ├── eu-west-1/
│   │   └── ... (mirrors us-east-1 structure)
│   │
│   └── eu-west-2/
│       └── ...
│
├── harness/
│   ├── pipelines/
│   │   └── bootstrap-cluster.yaml   # Harness pipeline YAML (exportable)
│   ├── services/                    # One Harness Service per addon
│   │   ├── eso-service.yaml
│   │   ├── alb-controller-service.yaml
│   │   ├── nginx-ingress-service.yaml
│   │   └── ...
│   └── environments/
│       ├── prod.yaml
│       ├── uat.yaml
│       └── sit.yaml
│
└── scripts/
    ├── validate-values.sh           # Pre-deploy lint check
    └── bootstrap-new-cluster.sh    # Scaffold a new env values dir
```

---

## Deployment Order (Critical — Respect Dependencies)

```
Stage 1:  namespaces            ← No deps. Must be first.
Stage 2:  external-secrets-operator (ESO)
Stage 3:  aws-load-balancer-controller
Stage 4:  nginx-ingress         ← Depends on LB controller
Stage 5:  target-group-binding  ← Depends on nginx-ingress being up
Stage 6+: any additional addons
```

Harness enforces this via sequential stages with health checks between each.

---

## Key File Examples

### `charts/namespaces/templates/namespace.yaml`
```yaml
{{- range .Values.namespaces }}
---
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .name }}
  labels:
    managed-by: harness
    environment: {{ $.Values.global.environment }}
    region: {{ $.Values.global.region }}
  {{- with .annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
```

### `environments/us-east-1/prod/namespaces.yaml`
```yaml
global:
  environment: prod
  region: us-east-1
  clusterName: eks-prod-us-east-1

namespaces:
  - name: nginx-ingress
  - name: observability
  - name: external-secrets
  - name: app-team-a
  - name: app-team-b
```

### `environments/us-east-1/sit/namespaces.yaml`
```yaml
global:
  environment: sit
  region: us-east-1
  clusterName: eks-sit-us-east-1

namespaces:
  - name: nginx-ingress
  - name: observability
  - name: external-secrets
```

---

### `charts/external-secrets-operator/values.yaml` (base)
```yaml
global:
  environment: ""
  region: ""
  clusterName: ""

eso:
  replicaCount: 1
  image:
    tag: "0.9.13"
  installCRDs: true
  webhook:
    create: true

clusterSecretStore:
  enabled: true
  provider:
    aws:
      service: SecretsManager
      region: ""           # overridden per-env
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets
```

### `environments/us-east-1/prod/eso.yaml`
```yaml
global:
  environment: prod
  region: us-east-1
  clusterName: eks-prod-us-east-1

eso:
  replicaCount: 3          # HA in prod
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/eso-prod-us-east-1

clusterSecretStore:
  provider:
    aws:
      region: us-east-1
```

### `environments/us-east-1/sit/eso.yaml`
```yaml
global:
  environment: sit
  region: us-east-1
  clusterName: eks-sit-us-east-1

eso:
  replicaCount: 1          # Single replica fine for SIT
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::111122223333:role/eso-sit-us-east-1

clusterSecretStore:
  provider:
    aws:
      region: us-east-1
```

---

### `environments/us-east-1/prod/nginx-ingress.yaml`
```yaml
global:
  environment: prod
  region: us-east-1

nginx:
  controller:
    replicaCount: 3
    resources:
      requests:
        cpu: 200m
        memory: 256Mi
      limits:
        cpu: 1000m
        memory: 512Mi
    service:
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: "external"
        service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
        service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    autoscaling:
      enabled: true
      minReplicas: 3
      maxReplicas: 10
```

### `environments/us-east-1/sit/nginx-ingress.yaml`
```yaml
global:
  environment: sit
  region: us-east-1

nginx:
  controller:
    replicaCount: 1
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
    service:
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: "external"
        service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
        service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
    autoscaling:
      enabled: false
```

---

## Harness Pipeline Design

### Pipeline Variables (set at runtime or from trigger)
```
REGION        = us-east-1         # e.g. us-east-1 | eu-west-1 | eu-west-2
ENVIRONMENT   = prod              # prod | uat | sit
CLUSTER_NAME  = eks-prod-us-east-1
```

### Pipeline Stages (sequential with approvals)

```
┌─────────────────────────────────────────────────────────┐
│  Harness Pipeline: EKS Cluster Bootstrap                │
│                                                         │
│  [Input] REGION + ENVIRONMENT + CLUSTER_NAME            │
│                                                         │
│  Stage 1: Validate                                      │
│    └─ Run validate-values.sh (helm lint each chart)     │
│                                                         │
│  Stage 2: Deploy Namespaces                             │
│    └─ helm upgrade --install namespaces                 │
│       -f environments/<REGION>/<ENV>/namespaces.yaml    │
│                                                         │
│  Stage 3: Deploy ESO                                    │
│    └─ helm upgrade --install eso                        │
│       -f environments/<REGION>/<ENV>/eso.yaml           │
│    └─ Health check: ESO pods Running                    │
│                                                         │
│  Stage 4: Deploy ALB Controller                         │
│    └─ helm upgrade --install alb-controller             │
│       -f environments/<REGION>/<ENV>/alb-controller.yaml│
│    └─ Health check: controller Running                  │
│                                                         │
│  Stage 5: Deploy Nginx Ingress                          │
│    └─ helm upgrade --install nginx-ingress              │
│       -f environments/<REGION>/<ENV>/nginx-ingress.yaml │
│    └─ Health check: LB hostname assigned                │
│                                                         │
│  Stage 6: Deploy Target Group Binding                   │
│    └─ helm upgrade --install tgb                        │
│       -f environments/<REGION>/<ENV>/tgb.yaml           │
│                                                         │
│  [PROD ONLY] Manual Approval Gate before Stage 4+      │
│                                                         │
│  Stage 7+: Additional addons (extensible)               │
└─────────────────────────────────────────────────────────┘
```

### Harness Service Definition (per addon)
Each Harness Service points to:
- **Chart source**: Git repo → `charts/<addon-name>/`
- **Values override**: Git repo → `environments/<+pipeline.variables.REGION>/<+pipeline.variables.ENVIRONMENT>/<addon>.yaml`
- **Release name**: `<addon>-<+pipeline.variables.ENVIRONMENT>`
- **Namespace**: addon-specific (e.g. `external-secrets`, `nginx-ingress`)

This means adding a new region is just:
1. `mkdir environments/ap-southeast-1/prod`
2. Copy and edit values files from another region
3. Run the Harness pipeline with the new region/env variables

---

## IRSA (IAM Roles for Service Accounts) Strategy

Each cluster+env gets its own scoped IAM roles. These ARNs live in the values files — **never hardcoded** in charts.

```
Role naming convention:
  <addon>-<env>-<region>
  e.g.  eso-prod-us-east-1
        alb-controller-uat-eu-west-1
```

TFE (Terraform Enterprise) creates these roles as part of cluster provisioning and outputs them. Harness reads the output or they are placed in values files at cluster creation time.

---

## Secrets Strategy with ESO

Once ESO is deployed (Stage 3), subsequent stages can read secrets from AWS Secrets Manager:

```yaml
# Pattern for any secret needed by bootstrap addons
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: nginx-tls-cert
  namespace: nginx-ingress
spec:
  secretStoreRef:
    name: aws-secrets-manager   # ClusterSecretStore deployed in Stage 3
    kind: ClusterSecretStore
  target:
    name: nginx-tls-cert
  data:
    - secretKey: tls.crt
      remoteRef:
        key: /eks/<env>/<region>/nginx/tls-cert
```

Secret path convention: `/eks/<env>/<region>/<addon>/<secret-name>`

---

## Adding a New Region (Runbook)

```bash
# 1. Scaffold the directory
./scripts/bootstrap-new-cluster.sh --region ap-southeast-1 --env prod \
  --cluster eks-prod-ap-southeast-1 \
  --account-id 111122223333 \
  --copy-from us-east-1/prod

# 2. Review and update IRSA ARNs in each values file
# (TFE outputs these after cluster creation)

# 3. Commit and push

# 4. Trigger Harness pipeline:
#    REGION=ap-southeast-1  ENVIRONMENT=prod
```

---

## Adding a New Addon

1. Create `charts/my-new-addon/` with `Chart.yaml`, `templates/`, `values.yaml`
2. Create per-env values files under each `environments/<region>/<env>/my-addon.yaml`
3. Add a new Stage to the Harness pipeline referencing the new service
4. Specify dependency (which stage must complete first)

---

## Reference Repositories (Inspiration)

| Repo | What to borrow |
|---|---|
| [squareops/terraform-aws-eks-bootstrap](https://github.com/squareops/terraform-aws-eks-bootstrap) | Full addon catalogue with feature flags |
| [rallyware/terraform-aws-eks-cluster-bootstrap](https://github.com/rallyware/terraform-aws-eks-cluster-bootstrap) | Modular helm release pattern |
| [lablabs/terraform-aws-eks-ingress-nginx](https://github.com/lablabs/terraform-aws-eks-ingress-nginx) | Production nginx-ingress module |
| [Harness Helm Docs](https://developer.harness.io/docs/continuous-delivery/deploy-srv-diff-platforms/helm/helm-cd-quickstart/) | Native Helm in Harness pipeline |

---

## Quick Decision Summary

| Decision | Choice | Reason |
|---|---|---|
| Chart storage | Same Git repo as values | Single source of truth, simpler Harness config |
| Values strategy | One file per addon per env | Surgical overrides, no merge surprises |
| Harness service type | Native Helm | Supports hooks, rollback, health checks |
| Secrets | ESO + AWS Secrets Manager | No secrets in Git, rotatable |
| Namespace creation | Helm chart (not kubectl) | Tracked in Harness release history |
| IRSA ARNs | In values files | Set by TFE output at cluster creation |
| Approval gates | PROD only, between stage 3 and 4 | UAT/SIT can run fully automated |
