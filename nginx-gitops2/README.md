# nginx-gitops — dual ingress with Kustomize

Single GitHub repo managing two different ingress controllers across four EKS clusters using Kustomize overlays and Harness GitOps (ArgoCD).

## Ingress controller split

| Cluster | Controller | Why |
|---|---|---|
| DEV | ingress-nginx (community) | Fast iteration, no licence, open-source |
| SIT | ingress-nginx (community) | Matches DEV behaviour for integration testing |
| UAT | ingress-nginx (community) | Prod-like resources, ServiceMonitor enabled |
| Prod | Traefik | Enterprise features free: dashboard, CRD routing, active health checks, middleware |

## Repo layout

```
nginx-gitops/
├── charts/
│   ├── ingress-nginx/          # Helm wrapper for community chart (DEV/SIT/UAT)
│   └── traefik/                # Helm wrapper for Traefik chart (Prod)
│
├── kustomize/
│   ├── base/
│   │   ├── ingress-nginx/      # Shared base manifests for all nginx environments
│   │   │   ├── kustomization.yaml
│   │   │   ├── namespace.yaml
│   │   │   └── helmrelease.yaml  (ConfigMap carrying base Helm values)
│   │   └── traefik/            # Shared base manifests for Traefik (Prod)
│   │       ├── kustomization.yaml
│   │       ├── namespace.yaml
│   │       ├── ingressclass.yaml
│   │       └── helmrelease.yaml
│   │
│   └── overlays/               # Per-environment patches
│       ├── dev/                # patches ingress-nginx base, minimal resources
│       ├── sit/                # patches ingress-nginx base, internal NLB
│       ├── uat/                # patches ingress-nginx base, prod-like + monitoring
│       └── prod/               # patches traefik base, HPA + PDB + dashboard
│           ├── kustomization.yaml
│           ├── patch-helm-values.yaml
│           ├── traefik-values.yaml
│           ├── hpa.yaml
│           ├── pdb.yaml
│           └── dashboard-ingress.yaml
│
├── harness/
│   ├── environments/           # dev, sit, uat, prod
│   ├── clusters/               # eks_dev, eks_sit, eks_uat, eks_prod
│   └── gitops-apps/            # One ArgoCD Application per environment
│
└── scripts/
    └── bootstrap.sh            # Fetch Helm dependencies after cloning
```

## How Kustomize + Helm + ArgoCD work together

```
GitHub repo
    │
    ├── kustomize/overlays/dev/kustomization.yaml
    │       │ references base/ingress-nginx
    │       │ applies patch-helm-values.yaml
    │       └── ingress-nginx-values.yaml (actual Helm values)
    │
    ▼
ArgoCD (via Harness GitOps agent in DEV cluster)
    │  detects kustomization.yaml → runs kustomize build
    │  renders: Namespace + ConfigMap (values) + any other resources
    │
    ▼
Helm chart rendered with overlay values
    │
    ▼
DEV EKS cluster ← ingress-nginx deployed
```

ArgoCD supports both Kustomize and Helm natively. When it finds a `kustomization.yaml` at the `path`, it runs `kustomize build` and applies the output. The Helm values ConfigMap pattern passes per-env values without needing a separate `values.yaml` file tree.

## Prerequisites

- kubectl access to all 4 clusters
- Helm 3 installed
- Harness account (free tier works fine for students)
- kustomize CLI (optional — for local testing): `brew install kustomize`

## Quick start

### 1. Clone and fetch chart dependencies

```bash
git clone https://github.com/your-org/nginx-gitops
cd nginx-gitops
./scripts/bootstrap.sh
```

### 2. Test overlays locally (no cluster needed)

```bash
# See what DEV will deploy
kubectl kustomize kustomize/overlays/dev

# See what Prod Traefik will deploy
kubectl kustomize kustomize/overlays/prod
```

### 3. Set up Harness GitOps

Follow `harness/README.md` for the step-by-step setup.

Key identifiers to update in all YAML files:

| Placeholder | Replace with |
|---|---|
| `https://github.com/your-org/nginx-gitops` | your actual repo URL |
| `default` (orgIdentifier) | your Harness org identifier |
| `nginx_gitops` (projectIdentifier) | your Harness project identifier |
| `your-<env>-eks-context` | your kubeconfig context names |

### 4. Apply Harness entities in order

```bash
# 1. Environments
harness apply -f harness/environments/dev.yaml
harness apply -f harness/environments/sit.yaml
harness apply -f harness/environments/uat.yaml
harness apply -f harness/environments/prod.yaml

# 2. Clusters (after agents are HEALTHY)
harness apply -f harness/clusters/cluster-dev.yaml
harness apply -f harness/clusters/cluster-sit.yaml
harness apply -f harness/clusters/cluster-uat.yaml
harness apply -f harness/clusters/cluster-prod.yaml

# 3. GitOps Applications
harness apply -f harness/gitops-apps/app-dev.yaml
harness apply -f harness/gitops-apps/app-sit.yaml
harness apply -f harness/gitops-apps/app-uat.yaml
harness apply -f harness/gitops-apps/app-prod.yaml
```

## Kustomize — how overlays work

Kustomize uses a **base + overlay** pattern:

- The **base** defines resources that are the same for all environments (Namespace, shared labels, base ConfigMap values).
- An **overlay** declares which base it extends, then **patches** only what differs for that environment. Everything not patched is inherited unchanged from the base.

Example: SIT needs 2 replicas but everything else the same as base → only `replicaCount: "2"` is in the SIT patch. Base supplies the rest.

The overlay `kustomization.yaml` is the entry point ArgoCD reads. It declares:
```yaml
bases:
  - ../../base/ingress-nginx    # what to extend
patches:
  - path: patch-helm-values.yaml  # what to change
resources:
  - ingress-nginx-values.yaml     # env-specific Helm values for ArgoCD
```

## Promoting a change

1. Edit `kustomize/overlays/sit/patch-helm-values.yaml` → PR → merge → auto-syncs SIT
2. Validate SIT
3. Edit `kustomize/overlays/uat/patch-helm-values.yaml` → PR → merge → auto-syncs UAT
4. Sign off UAT
5. Edit `kustomize/overlays/prod/patch-helm-values.yaml` → PR → merge → **manual sync** in Harness (Prod has selfHeal: false)

## Traefik vs ingress-nginx at a glance

| Feature | ingress-nginx | Traefik |
|---|---|---|
| Licence | Free (community) | Free (open-source) |
| Config model | Annotations on Ingress | CRDs (IngressRoute, Middleware) |
| Dashboard | No | Yes — built in |
| Active health checks | NGINX Plus only | Free, built in |
| Middleware (rate limit, auth) | NGINX Plus only | Free, built in |
| Let's Encrypt / ACME | Manual setup | Built in |
| TCP/UDP routing | Limited | Built in |
