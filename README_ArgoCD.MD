# EKS Cluster Bootstrap Architecture
### Harness GitOps (ArgoCD Agent per Cluster) | Multi-Region | Prod / UAT / SIT

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        HARNESS PLATFORM                             │
│                                                                     │
│  ┌─────────────────┐   ┌──────────────────┐   ┌─────────────────┐  │
│  │ Harness Pipeline│   │  Harness GitOps  │   │ Harness GitOps  │  │
│  │ (Bootstrap only)│   │  Applications    │   │ ApplicationSets │  │
│  │                 │   │  (per addon)     │   │ (multi-cluster) │  │
│  └────────┬────────┘   └────────┬─────────┘   └────────┬────────┘  │
│           │                     │                       │           │
└───────────┼─────────────────────┼───────────────────────┼───────────┘
            │                     │ sync via agent         │
            ▼                     ▼                       ▼
   ┌─────────────────────────────────────────────────────────────┐
   │                      GIT REPOSITORY                         │
   │  eks-bootstrap/                                             │
   │  ├── charts/           (helm chart templates)               │
   │  ├── environments/     (per-cluster values files)           │
   │  └── gitops/           (ArgoCD Application manifests)       │
   └─────────────────────────────────────────────────────────────┘
            │
            │  GitOps Agent continuously reconciles
            ▼
   ┌─────────────────────┐   ┌─────────────────────┐
   │  eks-prod-us-east-1 │   │  eks-uat-us-east-1  │  ... (all clusters)
   │  ┌───────────────┐  │   │  ┌───────────────┐  │
   │  │ Harness GitOps│  │   │  │ Harness GitOps│  │
   │  │ Agent (ArgoCD)│  │   │  │ Agent (ArgoCD)│  │
   │  └───────────────┘  │   │  └───────────────┘  │
   │  ESO                │   │  ESO                │
   │  ALB Controller     │   │  ALB Controller     │
   │  nginx-ingress      │   │  nginx-ingress      │
   │  TGB                │   │  TGB                │
   └─────────────────────┘   └─────────────────────┘
```

---

## Two-Phase Bootstrap Model

The key insight: ArgoCD can't manage itself before it exists, and ESO
can't manage secrets before it's running. Harness pipeline handles the
chicken-and-egg phase, then hands off to GitOps for everything else.

```
┌────────────────────────────────────────────────────────────┐
│  PHASE 1 — Harness Pipeline  (runs once per new cluster)   │
│                                                            │
│  Step 1: Install Harness GitOps Agent (ArgoCD)             │
│          via helm — bootstraps the GitOps engine itself    │
│                                                            │
│  Step 2: Deploy ESO                                        │
│          Must exist before ArgoCD can pull secrets         │
│                                                            │
│  Step 3: Create ClusterSecretStore                         │
│          Points ArgoCD to AWS Secrets Manager              │
│                                                            │
│  Step 4: Register cluster in Harness GitOps                │
│          (API call — makes cluster visible in Harness UI)  │
│                                                            │
│  Step 5: Apply App of Apps manifest                        │
│          Hands off all remaining addons to GitOps          │
│                                                            │
└────────────────────────────────────────────────────────────┘
                          │
                          ▼  hands off permanently
┌────────────────────────────────────────────────────────────┐
│  PHASE 2 — Harness GitOps / ArgoCD  (continuous, forever)  │
│                                                            │
│  App of Apps auto-syncs:                                   │
│    → namespaces                                            │
│    → aws-load-balancer-controller                          │
│    → nginx-ingress                                         │
│    → target-group-binding                                  │
│    → any future addons (just add to git)                   │
│                                                            │
│  Sync waves enforce dependency order                       │
│  Self-heal corrects any drift automatically                │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

---

## Repository Structure

```
eks-bootstrap/
│
├── charts/                               # Helm chart templates (never env-specific)
│   ├── namespaces/
│   │   ├── Chart.yaml
│   │   ├── templates/
│   │   │   └── namespace.yaml
│   │   └── values.yaml
│   │
│   ├── external-secrets-operator/        # Deployed by Harness Pipeline (Phase 1)
│   │   ├── Chart.yaml
│   │   ├── templates/
│   │   │   ├── helmrelease.yaml
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
│   └── target-group-binding/
│       ├── Chart.yaml
│       ├── templates/
│       │   └── targetgroupbinding.yaml
│       └── values.yaml
│
├── environments/
│   ├── us-east-1/
│   │   ├── prod/
│   │   │   ├── cluster.yaml             # Cluster metadata: name, region, accountId, ARNs
│   │   │   ├── namespaces.yaml
│   │   │   ├── eso.yaml
│   │   │   ├── alb-controller.yaml
│   │   │   ├── nginx-ingress.yaml
│   │   │   └── target-group-binding.yaml
│   │   ├── uat/
│   │   │   └── ... (same files, different values)
│   │   └── sit/
│   │       └── ...
│   ├── eu-west-1/
│   │   └── ... (mirrors us-east-1 layout)
│   └── eu-west-2/
│       └── ...
│
├── gitops/
│   │
│   ├── agent/
│   │   └── harness-gitops-agent-values.yaml   # Helm values for agent install
│   │
│   ├── app-of-apps/                            # One App of Apps per cluster
│   │   ├── eks-prod-us-east-1.yaml
│   │   ├── eks-uat-us-east-1.yaml
│   │   ├── eks-sit-us-east-1.yaml
│   │   ├── eks-prod-eu-west-1.yaml
│   │   └── ...
│   │
│   └── applicationsets/                        # Alternative: one AppSet per addon
│       ├── namespaces-appset.yaml
│       ├── alb-controller-appset.yaml
│       ├── nginx-ingress-appset.yaml
│       └── tgb-appset.yaml
│
├── harness/
│   └── pipelines/
│       └── bootstrap-cluster.yaml              # Phase 1 pipeline definition
│
└── scripts/
    ├── onboard-new-cluster.sh                  # Scaffolds environments/<region>/<env>/
    └── validate-values.sh                      # helm lint all charts before PR merge
```

---

## Key File Examples

### `environments/us-east-1/prod/cluster.yaml`
```yaml
# Cluster identity — referenced by all other values files and ArgoCD labels
cluster:
  name: eks-prod-us-east-1
  environment: prod
  region: us-east-1
  accountId: "111122223333"
  vpcId: vpc-0abc123def456

irsa:
  esoRoleArn: arn:aws:iam::111122223333:role/eso-prod-us-east-1
  albControllerRoleArn: arn:aws:iam::111122223333:role/alb-controller-prod-us-east-1
```

---

### `gitops/app-of-apps/eks-prod-us-east-1.yaml`
The App of Apps is the single manifest that ArgoCD uses to bootstrap
all other addons. It is applied by the Harness pipeline in Phase 1 Step 5.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bootstrap-eks-prod-us-east-1
  namespace: argocd
  labels:
    harness.io/envRef: prod
    harness.io/serviceRef: eks-bootstrap
  annotations:
    argocd.argoproj.io/sync-wave: "0"         # Must sync before child apps
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/eks-bootstrap.git
    targetRevision: main
    path: gitops/apps/eks-prod-us-east-1      # Child Application manifests live here
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

---

### `gitops/apps/eks-prod-us-east-1/` (child apps rendered by App of Apps)

#### `namespaces.yaml`
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: namespaces-prod-us-east-1
  namespace: argocd
  labels:
    harness.io/envRef: prod
    harness.io/serviceRef: namespaces
  annotations:
    argocd.argoproj.io/sync-wave: "1"        # Wave 1 — always first
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/eks-bootstrap.git
    targetRevision: main
    path: charts/namespaces
    helm:
      valueFiles:
        - ../../../environments/us-east-1/prod/namespaces.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

#### `alb-controller.yaml`
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: alb-controller-prod-us-east-1
  namespace: argocd
  labels:
    harness.io/envRef: prod
    harness.io/serviceRef: alb-controller
  annotations:
    argocd.argoproj.io/sync-wave: "2"        # Wave 2 — after namespaces
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/eks-bootstrap.git
    targetRevision: main
    path: charts/aws-load-balancer-controller
    helm:
      valueFiles:
        - ../../../environments/us-east-1/prod/alb-controller.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

#### `nginx-ingress.yaml`
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nginx-ingress-prod-us-east-1
  namespace: argocd
  labels:
    harness.io/envRef: prod
    harness.io/serviceRef: nginx-ingress
  annotations:
    argocd.argoproj.io/sync-wave: "3"        # Wave 3 — after ALB controller
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/eks-bootstrap.git
    targetRevision: main
    path: charts/nginx-ingress
    helm:
      valueFiles:
        - ../../../environments/us-east-1/prod/nginx-ingress.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: nginx-ingress
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

#### `target-group-binding.yaml`
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tgb-prod-us-east-1
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "4"        # Wave 4 — after nginx is up
  labels:
    harness.io/envRef: prod
    harness.io/serviceRef: target-group-binding
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/eks-bootstrap.git
    targetRevision: main
    path: charts/target-group-binding
    helm:
      valueFiles:
        - ../../../environments/us-east-1/prod/target-group-binding.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: nginx-ingress
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

### Sync Waves — Dependency Enforcement

ArgoCD sync waves replace the sequential Harness pipeline stages for Phase 2.
Each wave must be healthy before the next starts.

```
Wave 0  →  App of Apps itself (bootstrap-eks-<cluster>)
Wave 1  →  namespaces          (no deps)
Wave 2  →  aws-load-balancer-controller
Wave 3  →  nginx-ingress        (needs ALB controller running)
Wave 4  →  target-group-binding (needs nginx service + LB hostname)
Wave 5+ →  any future addons
```

---

### Alternative: ApplicationSets (if you want one manifest for all clusters)

Instead of one App of Apps per cluster, use a single ApplicationSet
per addon that fans out across all clusters via labels:

```yaml
# gitops/applicationsets/nginx-ingress-appset.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: nginx-ingress
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            bootstrap: "true"             # Label set on cluster registration
        values:
          region: "{{metadata.labels.region}}"
          environment: "{{metadata.labels.environment}}"
  template:
    metadata:
      name: "nginx-ingress-{{values.environment}}-{{values.region}}"
      annotations:
        argocd.argoproj.io/sync-wave: "3"
      labels:
        harness.io/envRef: "{{values.environment}}"
        harness.io/serviceRef: nginx-ingress
    spec:
      project: default
      source:
        repoURL: https://github.com/your-org/eks-bootstrap.git
        targetRevision: main
        path: charts/nginx-ingress
        helm:
          valueFiles:
            - values.yaml
            - "../../../environments/{{values.region}}/{{values.environment}}/nginx-ingress.yaml"
      destination:
        server: "{{server}}"
        namespace: nginx-ingress
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

**When to use ApplicationSets vs App of Apps:**

| Scenario | Use |
|---|---|
| You want full control per cluster, explicit manifests | App of Apps (one file per cluster) |
| You want zero-touch onboarding — register cluster, get addons free | ApplicationSets |
| Mix: some addons global, some cluster-specific | Both together |

Recommended: start with **App of Apps** (simpler to debug), migrate hot addons to **ApplicationSets** once stable.

---

## Harness Pipeline — Phase 1 Only

This pipeline runs **once** when a new cluster is created. It is not
the delivery mechanism for addons — ArgoCD owns that permanently.

```
┌──────────────────────────────────────────────────────────────────┐
│  Pipeline: EKS Cluster Bootstrap (Phase 1)                       │
│  Inputs: REGION | ENVIRONMENT | CLUSTER_NAME | ACCOUNT_ID        │
│                                                                  │
│  Stage 1: Validate                                               │
│    └─ helm lint all charts in charts/                            │
│    └─ Validate environments/<REGION>/<ENV>/ values exist         │
│                                                                  │
│  Stage 2: Install Harness GitOps Agent                           │
│    └─ helm repo add gitops-agent harness.github.io/gitops-helm   │
│    └─ helm upgrade --install argocd gitops-agent/gitops-helm     │
│       --namespace argocd --create-namespace                      │
│       -f gitops/agent/harness-gitops-agent-values.yaml           │
│       --set agent.accountId=<HARNESS_ACCOUNT_ID>                 │
│       --set agent.identifier=<CLUSTER_NAME>                      │
│    └─ Wait: agent pod Running + connected in Harness UI          │
│                                                                  │
│  Stage 3: Deploy ESO (must precede GitOps — secrets dependency)  │
│    └─ helm upgrade --install eso charts/external-secrets-operator│
│       --namespace external-secrets --create-namespace            │
│       -f environments/<REGION>/<ENV>/eso.yaml                    │
│    └─ Wait: ESO webhook pods Ready                               │
│                                                                  │
│  Stage 4: Register Cluster in Harness GitOps                     │
│    └─ Harness API call: create GitOps Cluster entity             │
│       (links cluster to the installed agent)                     │
│    └─ Tag cluster: region=<REGION> environment=<ENV>             │
│                       bootstrap=true                             │
│                                                                  │
│  Stage 5: Apply App of Apps                                      │
│    └─ kubectl apply -f                                           │
│         gitops/app-of-apps/<CLUSTER_NAME>.yaml                   │
│    └─ ArgoCD takes over — all remaining addons deploy via waves  │
│                                                                  │
│  [PROD ONLY] Manual approval gate between Stage 2 and Stage 3   │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

After Stage 5, the Harness **pipeline is done forever** for this cluster.
All future addon changes go through Git → ArgoCD auto-sync.

---

## Environment Values Examples

### `environments/us-east-1/prod/nginx-ingress.yaml`
```yaml
global:
  environment: prod
  region: us-east-1
  clusterName: eks-prod-us-east-1

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
  clusterName: eks-sit-us-east-1

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

## Adding a New Addon (ongoing, zero pipeline involvement)

```bash
# 1. Create the chart
mkdir -p charts/my-new-addon/templates
# ... write Chart.yaml, templates/, values.yaml

# 2. Create per-env values files
cp environments/us-east-1/prod/nginx-ingress.yaml \
   environments/us-east-1/prod/my-new-addon.yaml
# Edit for the new addon's values

# 3. Add child Application manifest for each cluster
# gitops/apps/eks-prod-us-east-1/my-new-addon.yaml
# Set sync-wave appropriately

# 4. Commit + push → ArgoCD detects the new Application → deploys automatically
# No Harness pipeline run needed
```

---

## Adding a New Cluster / Region (Runbook)

```bash
# 1. Scaffold values directory from nearest region
./scripts/onboard-new-cluster.sh \
  --region ap-southeast-1 \
  --env prod \
  --cluster eks-prod-ap-southeast-1 \
  --account-id 111122223333 \
  --copy-from us-east-1/prod

# 2. Update IRSA ARNs in each values file
# (TFE outputs these after EKS cluster creation)

# 3. Create App of Apps manifest
cp gitops/app-of-apps/eks-prod-us-east-1.yaml \
   gitops/app-of-apps/eks-prod-ap-southeast-1.yaml
# Update: name, path, valueFiles paths

# 4. Create child app manifests directory
cp -r gitops/apps/eks-prod-us-east-1 \
      gitops/apps/eks-prod-ap-southeast-1
# Update: Application names, valueFiles paths

# 5. Commit + push

# 6. Run Harness Bootstrap Pipeline once:
#    REGION=ap-southeast-1  ENVIRONMENT=prod
#    CLUSTER_NAME=eks-prod-ap-southeast-1
#    → Installs agent, ESO, registers cluster, applies App of Apps
#    → ArgoCD self-manages everything from there
```

---

## Harness GitOps Agent Installation Values

```yaml
# gitops/agent/harness-gitops-agent-values.yaml
agent:
  accountId: ""           # Injected by Harness pipeline at runtime
  identifier: ""          # Injected: cluster name e.g. eks-prod-us-east-1
  token: ""               # Injected from Harness secret store

argo-cd:
  crds:
    install: true
    keep: true            # CRITICAL: never delete CRDs on uninstall
  server:
    autoscale:
      enabled: false
  controller:
    resources:
      requests:
        cpu: 250m
        memory: 512Mi
  repoServer:
    resources:
      requests:
        cpu: 250m
        memory: 256Mi
```

---

## Harness Labels on ArgoCD Applications (Required)

For Harness to track apps in its UI and map them to Services/Environments,
every Application must carry these labels:

```yaml
labels:
  harness.io/envRef: prod          # matches Harness Environment identifier
  harness.io/serviceRef: nginx-ingress   # matches Harness Service identifier
```

These allow Harness to show deployment history, drift status, and rollback
options in its GitOps dashboard, even though ArgoCD is doing the actual syncing.

---

## Secrets Flow with ESO

```
AWS Secrets Manager
  └── /eks/prod/us-east-1/nginx/tls-cert
  └── /eks/prod/us-east-1/alb/internal-cert

        ↓  pulled by ESO (deployed in Phase 1)

ClusterSecretStore (aws-secrets-manager)

        ↓  referenced by ExternalSecret objects in charts

Kubernetes Secrets (nginx-ingress namespace)
  └── nginx-tls-cert
```

ArgoCD syncs the ExternalSecret objects. ESO reconciles the Kubernetes
Secrets from AWS. No secrets ever live in Git.

---

## Decision Summary

| Decision | Choice | Reason |
|---|---|---|
| GitOps control plane | Harness GitOps Agent (ArgoCD) per cluster | Cluster self-manages; no central ArgoCD blast radius |
| Phase 1 tooling | Harness Pipeline (helm + kubectl) | Handles chicken-and-egg: agent + ESO before GitOps |
| Phase 2 tooling | ArgoCD App of Apps + sync waves | Git is truth; self-healing; no manual helm runs |
| Dependency order | ArgoCD sync waves (annotations) | Declarative, no pipeline stage sequencing needed |
| Multi-cluster scaling | One App of Apps per cluster | Explicit, debuggable; migrate to ApplicationSets later |
| Values strategy | One file per addon per cluster | Surgical PRs, no merge conflicts |
| Secrets | ESO + AWS Secrets Manager | Nothing sensitive in Git |
| IRSA ARNs | In values files, set by TFE output | TFE creates roles, values files consume them |
| Prod approval | Harness pipeline manual gate (Phase 1 only) | UAT/SIT fully automated; Prod requires human |
| New addon delivery | Git commit only | No pipeline involvement after Phase 1 |
