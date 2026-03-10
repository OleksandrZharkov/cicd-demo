# ИНСТРУКЦИИ: CI/CD с GitHub Actions + ArgoCD + Minikube + Helm

## Архитектура проекта

```
┌─────────────┐    git push     ┌──────────────────┐
│  Developer  │ ─────────────▶  │   GitHub Actions  │
│  (local)    │                 │                  │
└─────────────┘                 │  1. Build image  │
                                │  2. Push to Hub  │
                                │  3. Update tag   │
                                └────────┬─────────┘
                                         │ commit values.yaml
                                         ▼
                                ┌──────────────────┐
                                │   GitHub Repo    │
                                │  helm/values.yaml│
                                └────────┬─────────┘
                                         │ watches repo
                                         ▼
┌─────────────────────────────────────────────────────┐
│  Minikube Cluster                                   │
│                                                     │
│  ┌──────────┐   sync   ┌──────────────────────┐    │
│  │  ArgoCD  │ ───────▶ │  cicd-demo namespace  │   │
│  │          │          │  (Helm release)        │   │
│  └──────────┘          │  Pod1  Pod2            │   │
│                        └──────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

**Полный CI/CD цикл:**
`git push` → GitHub Actions builds Docker image → pushes to Docker Hub →
updates `values.yaml` tag in repo → ArgoCD detects change →
Helm deploys new version to Minikube → приложение обновлено ✅

---

## ЧАСТЬ 1 — Подготовка (один раз)

### Шаг 1.1 — GitHub: создай репозиторий

1. Зайди на https://github.com → **New repository**
2. Имя: `cicd-demo`
3. Visibility: **Public**
4. **Не** добавляй README (мы пушим свой)
5. Нажми **Create repository**

### Шаг 1.2 — Docker Hub: создай Access Token

1. Зайди на https://hub.docker.com → Account Settings → Security
2. **New Access Token** → имя: `github-actions` → permission: **Read/Write**
3. **Скопируй токен** — он показывается только один раз!

### Шаг 1.3 — GitHub: добавь секреты

Зайди в репозиторий → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**

Добавь три секрета:
```
DOCKERHUB_USERNAME  = твой_логин_на_dockerhub
DOCKERHUB_TOKEN     = токен_из_шага_1.2
GH_PAT              = (создай ниже)
```

**Создание GH_PAT (Personal Access Token):**
GitHub → Settings (личный аккаунт) → Developer settings →
Personal access tokens → Tokens (classic) → Generate new token →
Scopes: ✅ **repo** (все) → Generate → скопируй токен → сохрани как `GH_PAT`

### Шаг 1.4 — Отредактируй проект под себя

```bash
cd ~/cicd-demo

# Замени YOUR_DOCKERHUB_USERNAME в values.yaml
YOUR_DH_USER="твой_dockerhub_логин"
sed -i "s|YOUR_DOCKERHUB_USERNAME|$YOUR_DH_USER|g" helm/cicd-demo/values.yaml

# Замени YOUR_GITHUB_USERNAME в application.yaml
YOUR_GH_USER="твой_github_логин"
sed -i "s|YOUR_GITHUB_USERNAME|$YOUR_GH_USER|g" argocd/application.yaml

# Проверь:
grep "repository" helm/cicd-demo/values.yaml
grep "repoURL" argocd/application.yaml
```

### Шаг 1.5 — Первый пуш в GitHub

```bash
cd ~/cicd-demo

git init
git add .
git commit -m "initial: CI/CD demo project"
git branch -M main
git remote add origin https://github.com/ТВОЙ_GH_USERNAME/cicd-demo.git
git push -u origin main
```

---

## ЧАСТЬ 2 — Проверка GitHub Actions (CI)

### Шаг 2.1 — Наблюдай за пайплайном

```bash
# Зайди на GitHub → вкладка Actions → видишь workflow "CI/CD Pipeline"
# Первый запуск: Build & Push (~2-3 мин) + Update Helm tag (~30 сек)
```

### Шаг 2.2 — Проверь Docker Hub

```bash
# Зайди на https://hub.docker.com → твой репозиторий cicd-demo
# Должны появиться теги: latest + SHORT_SHA (например a1b2c3d)
```

### Шаг 2.3 — Проверь коммит с обновлённым тегом

```bash
git pull
git log --oneline -3
# Должен быть коммит: "ci: update image tag to a1b2c3d [skip ci]"

cat helm/cicd-demo/values.yaml | grep tag
# tag: "a1b2c3d"
```

---

## ЧАСТЬ 3 — Запуск Minikube

```bash
# Запусти Minikube (если не запущен)
minikube start --driver=docker

# Проверь статус
minikube status
kubectl get nodes

# Убедись что ArgoCD установлен
kubectl get pods -n argocd
```

---

## ЧАСТЬ 4 — Настройка ArgoCD

### Шаг 4.1 — Получи пароль ArgoCD

```bash
# Получи начальный пароль
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo ""   # перевод строки
```

### Шаг 4.2 — Войди в ArgoCD UI

```bash
# Проброс порта (оставь этот терминал открытым!)
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Открой в браузере: https://localhost:8080
- Username: `admin`
- Password: из шага 4.1

### Шаг 4.3 — Создай ArgoCD Application

**Способ 1 — через kubectl (рекомендуется):**
```bash
kubectl apply -f ~/cicd-demo/argocd/application.yaml
```

**Способ 2 — через UI:**
1. ArgoCD UI → **+ NEW APP**
2. Application Name: `cicd-demo`
3. Project: `default`
4. Repository URL: `https://github.com/ТВОЙ_USERNAME/cicd-demo`
5. Revision: `HEAD`
6. Path: `helm/cicd-demo`
7. Cluster: `https://kubernetes.default.svc`
8. Namespace: `default`
9. **CREATE**

### Шаг 4.4 — Синхронизируй приложение

```bash
# Через kubectl (установи argocd CLI если нужно):
# Или просто нажми SYNC в UI ArgoCD

# Проверь статус
kubectl get pods -n default
kubectl get svc -n default
```

---

## ЧАСТЬ 5 — Проверь работающее приложение

```bash
# Получи URL приложения в Minikube
minikube service cicd-demo-svc --url

# Или используй port-forward
kubectl port-forward svc/cicd-demo-svc 8081:80

# Тест в новом терминале:
curl http://localhost:8081/
curl http://localhost:8081/health
```

**Ожидаемый ответ:**
```json
{
  "message": "Hello from CI/CD Demo!",
  "version": "1.0.0",
  "status": "ok"
}
```

---

## ЧАСТЬ 6 — Тест полного CI/CD цикла

```bash
cd ~/cicd-demo

# Сделай изменение в коде
sed -i 's/Hello from CI\/CD Demo!/Hello from CI\/CD Demo v2!/g' app/app.py

# Также обнови версию в Chart.yaml
sed -i 's/appVersion: "1.0.0"/appVersion: "2.0.0"/' helm/cicd-demo/Chart.yaml

# Запушь изменение
git add .
git commit -m "feat: update greeting message to v2"
git push
```

**Что произойдёт автоматически:**
1. GitHub Actions запустит пайплайн (~3 мин)
2. Новый Docker image запушится на Docker Hub
3. Автоматически обновится `values.yaml` с новым тегом
4. ArgoCD обнаружит изменение в репозитории (~3 мин polling)
5. ArgoCD задеплоит новую версию через Helm

```bash
# Наблюдай за обновлением подов в реальном времени:
kubectl get pods -w

# Проверь новую версию:
curl http://localhost:8081/
```

---

## ЧАСТЬ 7 — Полезные команды для собеседования

```bash
# === ArgoCD ===
kubectl get applications -n argocd                        # список приложений
kubectl describe application cicd-demo -n argocd          # детали приложения
kubectl get events -n default --sort-by='.lastTimestamp'  # события кластера

# === Helm ===
helm list                                  # список релизов
helm history cicd-demo                     # история деплоев
helm rollback cicd-demo 1                  # откат к предыдущей версии
helm get values cicd-demo                  # текущие values

# === Kubectl ===
kubectl rollout status deployment/cicd-demo    # статус деплоя
kubectl rollout history deployment/cicd-demo   # история деплоев
kubectl rollout undo deployment/cicd-demo      # rollback

# === Minikube ===
minikube dashboard                         # веб-интерфейс кластера
minikube image list                        # список образов
```

---

## Вопросы на собеседовании и ответы

**Q: Что такое GitOps?**
A: Подход, где Git является единственным источником истины (source of truth).
Любое изменение инфраструктуры делается через git commit.
ArgoCD следит за репозиторием и автоматически синхронизирует состояние кластера.

**Q: Чем отличается CI от CD?**
A: CI (Continuous Integration) — автоматическая сборка и тестирование при каждом коммите.
CD (Continuous Delivery/Deployment) — автоматическая доставка протестированного кода в среду.

**Q: Зачем нужен Helm?**
A: Helm — менеджер пакетов для Kubernetes. Позволяет шаблонизировать манифесты,
управлять версиями релизов, делать rollback одной командой.

**Q: Как ArgoCD узнаёт об изменениях?**
A: ArgoCD по умолчанию polling репозиторий каждые 3 минуты.
Можно настроить webhook для мгновенного срабатывания.

**Q: Что такое selfHeal в ArgoCD?**
A: Если кто-то вручную изменит ресурс в Kubernetes (kubectl edit),
ArgoCD автоматически вернёт его к состоянию из Git.

**Q: Как сделать rollback?**
A: Три способа: `helm rollback`, `kubectl rollout undo`,
или revert коммита в Git (ArgoCD задеплоит старую версию автоматически).
