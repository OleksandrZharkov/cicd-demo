#!/bin/bash

# ==============================================================
#  CI/CD Demo Project Setup Script
#  Stack: GitHub Actions → Docker Hub → ArgoCD → Minikube + Helm
# ==============================================================

set -e  # Exit on any error

PROJECT_NAME="cicd-demo"
BASE_DIR="$HOME/$PROJECT_NAME"

echo "========================================"
echo " Creating CI/CD Demo Project Structure"
echo "========================================"

# ── 1. Root directory ─────────────────────────────────────────
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# ── 2. Application source code ────────────────────────────────
mkdir -p app

cat > app/app.py << 'EOF'
from flask import Flask, jsonify
import os

app = Flask(__name__)

VERSION = os.getenv("APP_VERSION", "1.0.0")

@app.route("/")
def home():
    return jsonify({
        "message": "Hello from CI/CD Demo!",
        "version": VERSION,
        "status": "ok"
    })

@app.route("/health")
def health():
    return jsonify({"status": "healthy"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
EOF

cat > app/requirements.txt << 'EOF'
flask==3.0.3
gunicorn==22.0.0
EOF

cat > app/Dockerfile << 'EOF'
# ── Build stage ──────────────────────────────────────────────
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Runtime stage ─────────────────────────────────────────────
FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /install /usr/local
COPY app.py .

ENV APP_VERSION="1.0.0"
EXPOSE 5000

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app:app"]
EOF

# ── 3. Helm chart ─────────────────────────────────────────────
mkdir -p helm/cicd-demo/templates

cat > helm/cicd-demo/Chart.yaml << 'EOF'
apiVersion: v2
name: cicd-demo
description: Simple CI/CD demo application
type: application
version: 0.1.0
appVersion: "1.0.0"
EOF

cat > helm/cicd-demo/values.yaml << 'EOF'
replicaCount: 2

image:
  repository: YOUR_DOCKERHUB_USERNAME/cicd-demo   # ← Replace with your Docker Hub username
  pullPolicy: IfNotPresent
  tag: "latest"

service:
  type: NodePort
  port: 80
  targetPort: 5000
  nodePort: 30080

resources:
  limits:
    cpu: 200m
    memory: 128Mi
  requests:
    cpu: 100m
    memory: 64Mi

livenessProbe:
  httpGet:
    path: /health
    port: 5000
  initialDelaySeconds: 10
  periodSeconds: 15

readinessProbe:
  httpGet:
    path: /health
    port: 5000
  initialDelaySeconds: 5
  periodSeconds: 10
EOF

cat > helm/cicd-demo/templates/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Chart.Name }}
  labels:
    app: {{ .Chart.Name }}
    version: {{ .Chart.AppVersion }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Chart.Name }}
  template:
    metadata:
      labels:
        app: {{ .Chart.Name }}
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.service.targetPort }}
          env:
            - name: APP_VERSION
              value: {{ .Chart.AppVersion | quote }}
          livenessProbe:
            {{- toYaml .Values.livenessProbe | nindent 12 }}
          readinessProbe:
            {{- toYaml .Values.readinessProbe | nindent 12 }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
EOF

cat > helm/cicd-demo/templates/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Chart.Name }}-svc
  labels:
    app: {{ .Chart.Name }}
spec:
  type: {{ .Values.service.type }}
  selector:
    app: {{ .Chart.Name }}
  ports:
    - protocol: TCP
      port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
      nodePort: {{ .Values.service.nodePort }}
EOF

# ── 4. ArgoCD Application manifest ────────────────────────────
mkdir -p argocd

cat > argocd/application.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cicd-demo
  namespace: argocd
spec:
  project: default

  source:
    repoURL: https://github.com/YOUR_GITHUB_USERNAME/cicd-demo   # ← Replace!
    targetRevision: HEAD
    path: helm/cicd-demo

  destination:
    server: https://kubernetes.default.svc
    namespace: default

  syncPolicy:
    automated:
      prune: true       # Delete removed resources automatically
      selfHeal: true    # Revert manual changes automatically
    syncOptions:
      - CreateNamespace=true
EOF

# ── 5. GitHub Actions workflow ────────────────────────────────
mkdir -p .github/workflows

cat > .github/workflows/ci-cd.yaml << 'EOF'
name: CI/CD Pipeline

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  IMAGE_NAME: ${{ secrets.DOCKERHUB_USERNAME }}/cicd-demo

jobs:
  # ── Job 1: Build & Push Docker image ────────────────────────
  build-and-push:
    name: Build & Push to Docker Hub
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set image tag (short SHA)
        run: echo "IMAGE_TAG=${GITHUB_SHA::7}" >> $GITHUB_ENV

      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          context: ./app
          push: ${{ github.ref == 'refs/heads/main' }}
          tags: |
            ${{ env.IMAGE_NAME }}:${{ env.IMAGE_TAG }}
            ${{ env.IMAGE_NAME }}:latest

  # ── Job 2: Update Helm values (triggers ArgoCD sync) ─────────
  update-helm-tag:
    name: Update Helm image tag
    runs-on: ubuntu-latest
    needs: build-and-push
    if: github.ref == 'refs/heads/main'

    steps:
      - name: Checkout code
        uses: actions/checkout@v4
        with:
          token: ${{ secrets.GH_PAT }}   # Personal Access Token with repo write

      - name: Set image tag
        run: echo "IMAGE_TAG=${GITHUB_SHA::7}" >> $GITHUB_ENV

      - name: Update image tag in values.yaml
        run: |
          sed -i "s|tag: .*|tag: \"${{ env.IMAGE_TAG }}\"|" helm/cicd-demo/values.yaml

      - name: Commit and push updated values.yaml
        run: |
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add helm/cicd-demo/values.yaml
          git commit -m "ci: update image tag to ${{ env.IMAGE_TAG }} [skip ci]"
          git push
EOF

# ── 6. .gitignore ─────────────────────────────────────────────
cat > .gitignore << 'EOF'
__pycache__/
*.pyc
.env
*.log
EOF

# ── 7. README ─────────────────────────────────────────────────
cat > README.md << 'EOF'
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
EOF

echo ""
echo "✅ Project structure created at: $BASE_DIR"
echo ""
tree "$BASE_DIR" 2>/dev/null || find "$BASE_DIR" -print | sed 's|[^/]*/|  |g'
