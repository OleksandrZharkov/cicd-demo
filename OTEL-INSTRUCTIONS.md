# OpenTelemetry в Minikube: Пошаговые инструкции

## Архитектура стека

```
┌─────────────────────────────────────────────────────────────┐
│  Minikube Cluster                                           │
│                                                             │
│  ┌──────────────┐   OTLP/gRPC    ┌──────────────────────┐  │
│  │  cicd-demo   │ :4317 ──────▶  │   OTel Collector     │  │
│  │  Flask App   │                │  (deployment mode)   │  │
│  │  + OTel SDK  │                └──────────┬───────────┘  │
│  └──────────────┘                           │ OTLP/gRPC    │
│                                             ▼              │
│                                   ┌──────────────────────┐ │
│                                   │  Jaeger All-in-One   │ │
│                                   │  :16686 (UI)         │ │
│                                   │  :4317 (OTLP)        │ │
│                                   └──────────────────────┘ │
│                                                             │
│  ┌──────────────┐                                          │
│  │    ArgoCD    │ ← следит за GitHub репо                 │
│  └──────────────┘                                          │
└─────────────────────────────────────────────────────────────┘
```

**3 сигнала OpenTelemetry:**
- **Traces** — путь запроса через сервисы (видно в Jaeger)
- **Metrics** — счётчики, гистограммы (http_requests_total)
- **Logs** — структурированные логи (в этом примере через debug exporter)

---

## ШАГ 1 — Обнови GitHub репозиторий

```bash
cd ~/cicd-demo

# Замени YOUR_DOCKERHUB_USERNAME на свой логин
sed -i "s|YOUR_DOCKERHUB_USERNAME|ТВОй_DOCKERHUB_ЛОГИН|g" helm/cicd-demo/values.yaml

# Запушь все изменения
git add .
git commit -m "feat: add OpenTelemetry instrumentation with Jaeger"
git push
```

GitHub Actions автоматически:
1. Соберёт новый Docker image с OTel SDK
2. Запушит на Docker Hub
3. Обновит тег в `values.yaml`
4. ArgoCD задеплоит новую версию

---

## ШАГ 2 — Добавь Helm репозитории

```bash
# OTel Collector официальный chart
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts

# Jaeger официальный chart
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts

# Обнови индекс репозиториев
helm repo update

# Проверь что репо добавлены:
helm repo list
# NAME              URL
# open-telemetry    https://open-telemetry.github.io/opentelemetry-helm-charts
# jaegertracing     https://jaegertracing.github.io/helm-charts
```

---

## ШАГ 3 — Задеплой Jaeger

```bash
# Вариант A: через ArgoCD (GitOps — рекомендуется)
kubectl apply -f ~/cicd-demo/argocd/application-jaeger.yaml

# Вариант B: напрямую через Helm (быстрее для тестирования)
helm install jaeger jaegertracing/jaeger \
  --namespace default \
  --version 3.3.1 \
  --set provisionDataStore.cassandra=false \
  --set allInOne.enabled=true \
  --set allInOne.extraEnv[0].name=COLLECTOR_OTLP_ENABLED \
  --set allInOne.extraEnv[0].value="true" \
  --set storage.type=memory \
  --set agent.enabled=false \
  --set collector.enabled=false \
  --set query.enabled=false

# Проверь что Jaeger запустился:
kubectl get pods -l app.kubernetes.io/name=jaeger
# NAME                      READY   STATUS    RESTARTS
# jaeger-xxxxxxxxx-xxxxx    1/1     Running   0
```

---

## ШАГ 4 — Задеплой OTel Collector

```bash
# Вариант A: через ArgoCD
kubectl apply -f ~/cicd-demo/argocd/application-otel-collector.yaml

# Вариант B: напрямую через Helm
helm install otel-collector open-telemetry/opentelemetry-collector \
  --namespace default \
  --version 0.104.0 \
  --set image.repository="otel/opentelemetry-collector-contrib" \
  --set image.tag="0.104.0" \
  -f ~/cicd-demo/helm/otel-collector/values.yaml

# Проверь статус:
kubectl get pods -l app.kubernetes.io/name=opentelemetry-collector
# NAME                                READY   STATUS    RESTARTS
# otel-collector-xxxxxxxxx-xxxxx      1/1     Running   0

# Посмотри логи коллектора (должен видеть Traces/Metrics):
kubectl logs -l app.kubernetes.io/name=opentelemetry-collector --tail=50
```

---

## ШАГ 5 — Проверь что всё работает

```bash
# Все поды должны быть Running:
kubectl get pods
# NAME                              READY   STATUS    RESTARTS
# cicd-demo-xxxxxxxxx-xxxxx         1/1     Running   0
# cicd-demo-xxxxxxxxx-yyyyy         1/1     Running   0
# jaeger-xxxxxxxxx-xxxxx            1/1     Running   0
# otel-collector-xxxxxxxxx-xxxxx    1/1     Running   0

# Все сервисы:
kubectl get svc
# NAME                              TYPE        CLUSTER-IP      PORT(S)
# cicd-demo-svc                     NodePort    10.x.x.x        80:30080/TCP
# jaeger                            ClusterIP   10.x.x.x        ...
# otel-collector                    ClusterIP   10.x.x.x        4317/TCP,4318/TCP
```

---

## ШАГ 6 — Генерируй трейсы

**Терминал 1 — проброс порта приложения:**
```bash
kubectl port-forward svc/cicd-demo-svc 8081:80
```

**Терминал 2 — генерируй запросы:**
```bash
# Простой запрос (создаёт 1 span)
curl http://localhost:8081/

# Запрос с вложенными спанами (создаёт 3 вложенных span'а — хорошо видно в Jaeger)
curl http://localhost:8081/work

# Сделай 10 запросов для красивых метрик
for i in {1..10}; do
  curl -s http://localhost:8081/ > /dev/null
  curl -s http://localhost:8081/work > /dev/null
  echo "Request $i done"
done
```

---

## ШАГ 7 — Открой Jaeger UI

**Терминал 3 — проброс порта Jaeger:**
```bash
kubectl port-forward svc/jaeger 16686:16686
```

Открой в браузере: **http://localhost:16686**

**В UI Jaeger:**
1. В dropdown "Service" выбери `cicd-demo`
2. Нажми **Find Traces**
3. Кликни на любой trace → увидишь вложенные spans

**Что ты увидишь:**
```
cicd-demo  GET /work  45ms
  ├─ work-handler              40ms
  │   ├─ db-query-simulation   50ms  (db.system=postgresql)
  │   └─ cache-lookup           1ms  (cache.hit=true)
  └─ [автоматический Flask span]
```

---

## ШАГ 8 — Просмотр метрик через OTel Collector

```bash
# Посмотри метрики в логах коллектора
kubectl logs -l app.kubernetes.io/name=opentelemetry-collector -f

# Ищи строки вида:
# Metric #0
# Descriptor:
#   -> Name: http_requests_total
#   -> Description: Total number of HTTP requests
#   -> DataType: Sum
# NumberDataPoints #0
#   -> route: /
#   -> Value: 10
```

---

## Rollback через Helm (важно для собеседования)

```bash
# Посмотри историю деплоев
helm history cicd-demo

# Откатись к предыдущей версии
helm rollback cicd-demo 1

# Или через kubectl:
kubectl rollout undo deployment/cicd-demo
kubectl rollout status deployment/cicd-demo
```

---

## Полная очистка (если нужно начать заново)

```bash
# Удали через Helm
helm uninstall otel-collector
helm uninstall jaeger
helm uninstall cicd-demo   # если ставил через Helm напрямую

# Или через ArgoCD
kubectl delete -f ~/cicd-demo/argocd/application-otel-collector.yaml
kubectl delete -f ~/cicd-demo/argocd/application-jaeger.yaml
kubectl delete -f ~/cicd-demo/argocd/application.yaml
```

---

## Вопросы на собеседовании — OpenTelemetry

**Q: Что такое OpenTelemetry?**
A: Vendor-agnostic open-source фреймворк для сбора телеметрии (traces, metrics, logs).
Состоит из API, SDK и Collector. Управляется CNCF. Заменяет Jaeger-client, OpenCensus, OpenTracing.

**Q: Чем OTel Collector лучше direct export в Jaeger?**
A: Collector — это буфер и маршрутизатор. Он может:
- Принимать данные от тысяч сервисов одновременно
- Применять processors (батчинг, фильтрация, семплинг)
- Отправлять в несколько backends одновременно (Jaeger + Prometheus + Datadog)
- Менять backend без перезапуска приложений

**Q: Что такое Span и Trace?**
A: Span — единица работы (например, HTTP запрос или DB query).
Trace — дерево связанных Span'ов, показывающее полный путь запроса через систему.
Связь между спанами — через trace_id и parent_span_id в заголовках.

**Q: Какие режимы деплоя OTel Collector?**
A: DaemonSet — один pod на каждом node (для сбора логов с дисков, node метрик).
Deployment — централизованный gateway (для трейсов, cluster метрик).
В production обычно используют оба одновременно.

**Q: Что такое OTLP?**
A: OpenTelemetry Protocol — стандартный протокол для передачи телеметрии.
Поддерживает gRPC (порт 4317) и HTTP (порт 4318).
Все современные observability платформы поддерживают OTLP.
