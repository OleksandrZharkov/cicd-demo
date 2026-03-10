# CI/CD Demo Project

**Stack:** GitHub Actions → Docker Hub → ArgoCD → Minikube + Helm

## Flow

```
git push → GitHub Actions → Docker Hub
                 ↓ (updates values.yaml tag)
           ArgoCD detects change → deploys to Minikube via Helm
```

## Quick Start

See INSTRUCTIONS.md for step-by-step setup guide.
