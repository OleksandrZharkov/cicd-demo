# Production CI/CD: Полная инструкция

## Архитектура пайплайна

```
git push (main)
    │
    ▼
┌─────────────────────────────────────────────────────────────┐
│  GitHub Actions — 6 Jobs последовательно                    │
│                                                             │
│  1. lint          Hadolint + Black + Flake8                 │
│     │                                                       │
│  2. test          Pytest + Coverage (>80%)                  │
│     │                                                       │
│  3. build         Docker Buildx (local, no push)            │
│     │                                                       │
│  4. security-scan Trivy → GitHub Security tab               │
│     │                                                       │
│  5. push          Docker Hub (SHA tag + latest)             │
│     │                                                       │
│  6. deploy        sed values.yaml → git commit → push       │
└─────────────────────────────────────────────────────────────┘
    │
    ▼ ArgoCD polling (3 мин)
┌─────────────────────────────────────────────────────────────┐
│  Minikube                                                   │
│  ArgoCD → Helm RollingUpdate → cicd-prod pods              │
│        ↘                                                    │
│          OTel Collector → Jaeger UI                         │
└─────────────────────────────────────────────────────────────┘
```

---

## Что нового по сравнению с предыдущим проектом

| Компонент | cicd-demo (базовый) | cicd-prod (продакшн) |
|---|---|---|
| Dockerfile lint | ❌ | ✅ Hadolint |
| Python lint | ❌ | ✅ Black + Flake8 |
| Unit tests | ❌ | ✅ Pytest + Coverage |
| Security scan | ❌ | ✅ Trivy → GitHub Security tab |
| Non-root user | ❌ | ✅ UID 1001 |
| SecurityContext | ❌ | ✅ capabilities drop ALL |
| Separate probes | ❌ | ✅ /health + /ready |
| Metrics histogram | ❌ | ✅ latency histogram |
| RollingUpdate | ❌ | ✅ maxUnavailable=0 |
| pipeline cancel | ❌ | ✅ concurrency |

---

## ЧАСТЬ 1 — Подготовка GitHub

### Шаг 1.1 — Создай новый репозиторий
1. GitHub → New repository → имя: `cicd-prod`
2. Visibility: **Public**
3. Без README

### Шаг 1.2 — Добавь секреты
GitHub → Settings → Secrets and variables → Actions:

```
DOCKERHUB_USERNAME  = твой Docker Hub логин
DOCKERHUB_TOKEN     = токен из Docker Hub (Settings → Security → New Token)
GH_PAT              = Personal Access Token (Settings → Developer → PAT classic → scope: repo)
```

### Шаг 1.3 — Включи GitHub Security tab (для Trivy)
Repo → Settings → Security → **Code security and analysis** → 
Code scanning → **Enable**

---

## ЧАСТЬ 2 — Настройка проекта

```bash
cd ~/cicd-prod

# Замени Docker Hub username
YOUR_DH_USER="твой_dockerhub_логин"
sed -i '' "s|YOUR_DOCKERHUB_USERNAME|$YOUR_DH_USER|g" helm/cicd-prod/values.yaml

# Замени GitHub username
YOUR_GH_USER="твой_github_логин"
sed -i '' "s|YOUR_GITHUB_USERNAME|$YOUR_GH_USER|g" argocd/application.yaml

# Проверь
grep "repository" helm/cicd-prod/values.yaml
grep "repoURL"    argocd/application.yaml
```

### Первый пуш

```bash
cd ~/cicd-prod
git init
git add .
git commit -m "initial: production CI/CD project"
git branch -M main
git remote add origin https://github.com/ТВОЙ_USERNAME/cicd-prod.git
git push -u origin main
```

---

## ЧАСТЬ 3 — Наблюдение за пайплайном

```bash
# GitHub → Actions → "Production CI/CD Pipeline"
# Должны выполниться последовательно:
# lint (~1 мин) → test (~2 мин) → build (~3 мин) → security-scan (~2 мин)
# → push (~1 мин) → deploy (~30 сек)
```

**Где смотреть результаты:**
- Lint: вкладка Actions → job "Lint" → шаги Hadolint, Black, Flake8
- Tests: вкладка Actions → job "Unit Tests" → видишь coverage
- Security: вкладка **Security** → Code scanning alerts → Trivy результаты
- Artifacts: вкладка Actions → Summary → Artifacts (coverage-report, trivy-results)

---

## ЧАСТЬ 4 — Деплой в Minikube

```bash
# Убедись что Minikube и ArgoCD запущены
minikube status
kubectl get pods -n argocd

# Задеплой ArgoCD application
kubectl apply -f ~/cicd-prod/argocd/application.yaml

# Проверь статус
kubectl get application cicd-prod -n argocd
kubectl get pods -l app=cicd-prod
```

---

## ЧАСТЬ 5 — Тест приложения

```bash
# Терминал 1 — проброс порта приложения
kubectl port-forward svc/cicd-prod-svc 8082:80

# Терминал 2 — тесты
curl http://localhost:8082/
curl http://localhost:8082/health
curl http://localhost:8082/ready
curl http://localhost:8082/work

# Генерация трафика для метрик
for i in {1..20}; do
  curl -s http://localhost:8082/ > /dev/null
  curl -s http://localhost:8082/work > /dev/null
done
```

---

## ЧАСТЬ 6 — Просмотр трейсов в Jaeger

```bash
# Терминал 3
kubectl port-forward svc/jaeger-query 16686:16686
# → http://localhost:16686 → Service: cicd-prod → Find Traces
```

---

## ЧАСТЬ 7 — Тест полного цикла обновления

```bash
cd ~/cicd-prod

# Измени версию и сообщение
sed -i '' "s|Production CI/CD Demo|Production CI/CD Demo v2|g" app/app.py
sed -i '' "s|appVersion: \"1.0.0\"|appVersion: \"2.0.0\"|" helm/cicd-prod/Chart.yaml

# Обнови тест под новое сообщение
# (в test_app.py строка: assert "message" in data  — не нужно менять)

git add .
git commit -m "feat: update to v2"
git push
# Наблюдай пайплайн → ~10 мин → новая версия в Minikube
```

---

## Rollback (важно для собеседования!)

```bash
# Способ 1 — Helm rollback (быстрее всего)
helm history cicd-prod
helm rollback cicd-prod 1

# Способ 2 — kubectl
kubectl rollout undo deployment/cicd-prod
kubectl rollout status deployment/cicd-prod

# Способ 3 — GitOps (правильный для продакшна)
git revert HEAD
git push
# ArgoCD автоматически задеплоит предыдущую версию
```

---

## Вопросы на собеседовании — Production CI/CD

**Q: Почему pipeline упадёт если coverage < 80%?**
A: В pytest используем флаг `--cov-fail-under=80`. Это заставляет разработчиков
писать тесты. Без этого coverage постепенно деградирует.

**Q: Зачем Hadolint?**
A: Статический анализ Dockerfile. Ловит: использование `latest` тегов,
отсутствие `--no-cache-dir` у pip, запуск от root, проблемы с кешированием слоёв.

**Q: Почему Trivy с `exit-code: 0` а не `1`?**
A: В этом конфиге мы не блокируем pipeline — результаты видны в GitHub Security tab.
В строгом продакшне ставят `exit-code: 1` и `ignore-unfixed: true` чтобы блокировать
только те CVE, для которых уже есть патч.

**Q: Зачем отдельные /health и /ready?**
A: `/health` — liveness probe. Если упал — Kubernetes перезапускает pod.
`/ready` — readiness probe. Если не готов — Kubernetes не шлёт трафик в этот pod.
Это позволяет делать graceful startup без даунтайма.

**Q: Что такое `maxUnavailable: 0` в RollingUpdate?**
A: Гарантирует, что во время обновления всегда доступно N реплик (нет даунтайма).
`maxSurge: 1` позволяет временно иметь N+1 под во время апдейта.

**Q: Зачем `concurrency: cancel-in-progress`?**
A: Если разработчик пушит несколько коммитов быстро — отменяем устаревшие запуски.
Экономит GitHub Actions minutes и ресурсы.

**Q: Что такое non-root контейнер и зачем?**
A: Контейнер запускается от непривилегированного пользователя (UID 1001).
Если атакующий получит shell внутри контейнера — у него не будет root прав.
`capabilities: drop: [ALL]` убирает все Linux capabilities.
