#!/usr/bin/env bash
# Bootstrap script — run once after cloning the repo.
# Fetches Helm chart dependencies so ArgoCD/Kustomize can render them.
#
# Usage: ./scripts/bootstrap.sh

set -euo pipefail

echo "==> Fetching ingress-nginx Helm dependency..."
cd charts/ingress-nginx
helm dependency update
cd ../..

echo "==> Fetching Traefik Helm dependency..."
cd charts/traefik
helm dependency update
cd ../..

echo ""
echo "Done. Both chart dependency lock files created."
echo "You can now test rendering locally:"
echo ""
echo "  # Test DEV overlay"
echo "  kubectl kustomize kustomize/overlays/dev"
echo ""
echo "  # Test Prod Traefik overlay"
echo "  kubectl kustomize kustomize/overlays/prod"
echo ""
echo "  # Or with standalone kustomize CLI:"
echo "  kustomize build kustomize/overlays/dev"
echo "  kustomize build kustomize/overlays/prod"
