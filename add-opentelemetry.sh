#!/bin/bash

# ==============================================================
#  OpenTelemetry Extension for cicd-demo
#  Stack: Flask + OTel SDK → OTel Collector → Jaeger UI
# ==============================================================

set -e

PROJECT_DIR="$HOME/cicd-demo"

echo "========================================================"
echo "  Adding OpenTelemetry to cicd-demo"
echo "========================================================"

cd "$PROJECT_DIR"

# ── 1. Обновлённое Flask приложение с ручной OTel инструментацией ──
cat > app/app.py << 'PYEOF'
import os
from flask import Flask, jsonify

# ── OpenTelemetry imports ──────────────────────────────────────
from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor

# ── Настройка OTel ресурса (метаданные сервиса) ───────────────
resource = Resource.create({
    "service.name": os.getenv("OTEL_SERVICE_NAME", "cicd-demo"),
    "service.version": os.getenv("APP_VERSION", "1.0.0"),
    "deployment.environment": os.getenv("ENVIRONMENT", "development"),
})

# ── Настройка Tracing ─────────────────────────────────────────
otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")

tracer_provider = TracerProvider(resource=resource)
span_exporter = OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True)
tracer_provider.add_span_processor(BatchSpanProcessor(span_exporter))
trace.set_tracer_provider(tracer_provider)

# ── Настройка Metrics ─────────────────────────────────────────
metric_exporter = OTLPMetricExporter(endpoint=otlp_endpoint, insecure=True)
metric_reader = PeriodicExportingMetricReader(metric_exporter, export_interval_millis=5000)
meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
metrics.set_meter_provider(meter_provider)

# ── Получение tracer и meter ───────────────────────────────────
tracer = trace.get_tracer("cicd-demo.tracer")
meter  = metrics.get_meter("cicd-demo.meter")

# ── Кастомные метрики ─────────────────────────────────────────
request_counter = meter.create_counter(
    name="http_requests_total",
    description="Total number of HTTP requests",
    unit="1",
)

# ── Flask приложение ──────────────────────────────────────────
app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)   # автоматическая трассировка всех маршрутов

VERSION = os.getenv("APP_VERSION", "1.0.0")

@app.route("/")
def home():
    # Инкремент счётчика запросов
    request_counter.add(1, {"route": "/", "method": "GET"})

    # Создание кастомного спана внутри автоматического
    with tracer.start_as_current_span("home-handler") as span:
        span.set_attribute("app.version", VERSION)
        span.set_attribute("custom.label", "hello-span")
        return jsonify({
            "message": "Hello from CI/CD Demo with OpenTelemetry!",
            "version": VERSION,
            "status": "ok",
            "tracing": "enabled"
        })

@app.route("/health")
def health():
    return jsonify({"status": "healthy"}), 200

@app.route("/work")
def work():
    """Эмулирует работу с вложенными спанами — хорошо видно в Jaeger."""
    request_counter.add(1, {"route": "/work", "method": "GET"})

    with tracer.start_as_current_span("work-handler") as parent_span:
        parent_span.set_attribute("work.type", "simulation")

        with tracer.start_as_current_span("db-query-simulation") as child_span:
            child_span.set_attribute("db.system", "postgresql")
            child_span.set_attribute("db.statement", "SELECT * FROM items")
            import time; time.sleep(0.05)   # симуляция запроса к БД

        with tracer.start_as_current_span("cache-lookup") as cache_span:
            cache_span.set_attribute("cache.hit", True)

        return jsonify({"result": "work done", "spans": "check Jaeger!"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
PYEOF

# ── 2. Обновлённый requirements.txt ──────────────────────────
cat > app/requirements.txt << 'EOF'
flask==3.0.3
gunicorn==22.0.0

# OpenTelemetry core
opentelemetry-api==1.25.0
opentelemetry-sdk==1.25.0

# Flask auto-instrumentation
opentelemetry-instrumentation-flask==0.46b0

# OTLP gRPC exporters (отправка в OTel Collector)
opentelemetry-exporter-otlp-proto-grpc==1.25.0
EOF

# ── 3. Обновлённый Dockerfile ─────────────────────────────────
cat > app/Dockerfile << 'EOF'
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /install /usr/local
COPY app.py .

ENV APP_VERSION="1.0.0"
ENV OTEL_SERVICE_NAME="cicd-demo"
ENV OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector:4317"
ENV ENVIRONMENT="production"

EXPOSE 5000
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]
EOF

# ── 4. OTel Collector Helm values ─────────────────────────────
mkdir -p helm/otel-collector

cat > helm/otel-collector/values.yaml << 'EOF'
# Режим deployment — один под (подходит для dev/minikube)
mode: deployment

image:
  repository: otel/opentelemetry-collector-contrib
  tag: "0.104.0"

replicaCount: 1

# Отключаем лишние receivers — используем только OTLP
ports:
  jaeger-compact:
    enabled: false
  jaeger-thrift:
    enabled: false
  jaeger-grpc:
    enabled: false
  zipkin:
    enabled: false
  otlp:
    enabled: true
    containerPort: 4317
    servicePort: 4317
    protocol: TCP
  otlp-http:
    enabled: true
    containerPort: 4318
    servicePort: 4318
    protocol: TCP

config:
  receivers:
    jaeger: null
    prometheus: null
    zipkin: null
    otlp:
      protocols:
        grpc:
          endpoint: "0.0.0.0:4317"
        http:
          endpoint: "0.0.0.0:4318"

  processors:
    batch:
      timeout: 1s
      send_batch_size: 1024
    memory_limiter:
      check_interval: 5s
      limit_percentage: 80
      spike_limit_percentage: 25

  exporters:
    # Печатает traces в логи коллектора (отладка)
    debug:
      verbosity: normal
    # Отправляет трейсы в Jaeger
    otlp/jaeger:
      endpoint: "jaeger:4317"
      tls:
        insecure: true

  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp/jaeger, debug]
      metrics:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [debug]
      logs: null

resources:
  limits:
    cpu: 200m
    memory: 256Mi
  requests:
    cpu: 100m
    memory: 128Mi
EOF

# ── 5. Jaeger Helm values (all-in-one, in-memory) ─────────────
mkdir -p helm/jaeger

cat > helm/jaeger/values.yaml << 'EOF'
# Jaeger all-in-one: collector + query + UI в одном поде
# Хранение в памяти — идеально для dev/minikube
provisionDataStore:
  cassandra: false
  elasticsearch: false
  kafka: false

allInOne:
  enabled: true
  image:
    repository: jaegertracing/all-in-one
    tag: "1.58"
  resources:
    limits:
      cpu: 300m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 256Mi
  # Принимает OTLP трейсы напрямую
  extraEnv:
    - name: COLLECTOR_OTLP_ENABLED
      value: "true"

storage:
  type: memory

agent:
  enabled: false

collector:
  enabled: false

query:
  enabled: false

ingress:
  enabled: false
EOF

# ── 6. Обновлённые Helm values приложения ─────────────────────
cat > helm/cicd-demo/values.yaml << 'EOF'
replicaCount: 2

image:
  repository: YOUR_DOCKERHUB_USERNAME/cicd-demo
  pullPolicy: IfNotPresent
  tag: "latest"

service:
  type: NodePort
  port: 80
  targetPort: 5000
  nodePort: 30080

# OTel переменные окружения для приложения
env:
  - name: APP_VERSION
    value: "2.0.0"
  - name: OTEL_SERVICE_NAME
    value: "cicd-demo"
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector:4317"
  - name: ENVIRONMENT
    value: "production"

resources:
  limits:
    cpu: 200m
    memory: 256Mi
  requests:
    cpu: 100m
    memory: 128Mi

livenessProbe:
  httpGet:
    path: /health
    port: 5000
  initialDelaySeconds: 15
  periodSeconds: 15

readinessProbe:
  httpGet:
    path: /health
    port: 5000
  initialDelaySeconds: 10
  periodSeconds: 10
EOF

# ── 7. Обновлённый deployment.yaml (добавлены env vars) ───────
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
            {{- toYaml .Values.env | nindent 12 }}
          livenessProbe:
            {{- toYaml .Values.livenessProbe | nindent 12 }}
          readinessProbe:
            {{- toYaml .Values.readinessProbe | nindent 12 }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
EOF

# ── 8. ArgoCD Applications для OTel Collector и Jaeger ────────
cat > argocd/application-otel-collector.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: otel-collector
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://open-telemetry.github.io/opentelemetry-helm-charts
    chart: opentelemetry-collector
    targetRevision: "0.104.0"
    helm:
      valueFiles: []
      values: |
        mode: deployment
        image:
          repository: otel/opentelemetry-collector-contrib
          tag: "0.104.0"
        ports:
          jaeger-compact:
            enabled: false
          jaeger-thrift:
            enabled: false
          jaeger-grpc:
            enabled: false
          zipkin:
            enabled: false
        config:
          receivers:
            jaeger: null
            prometheus: null
            zipkin: null
            otlp:
              protocols:
                grpc:
                  endpoint: "0.0.0.0:4317"
                http:
                  endpoint: "0.0.0.0:4318"
          processors:
            batch:
              timeout: 1s
            memory_limiter:
              check_interval: 5s
              limit_percentage: 80
              spike_limit_percentage: 25
          exporters:
            debug:
              verbosity: normal
            otlp/jaeger:
              endpoint: "jaeger:4317"
              tls:
                insecure: true
          service:
            pipelines:
              traces:
                receivers: [otlp]
                processors: [memory_limiter, batch]
                exporters: [otlp/jaeger, debug]
              metrics:
                receivers: [otlp]
                processors: [memory_limiter, batch]
                exporters: [debug]
              logs: null
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

cat > argocd/application-jaeger.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: jaeger
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://jaegertracing.github.io/helm-charts
    chart: jaeger
    targetRevision: "3.3.1"
    helm:
      values: |
        provisionDataStore:
          cassandra: false
          elasticsearch: false
          kafka: false
        allInOne:
          enabled: true
          image:
            repository: jaegertracing/all-in-one
            tag: "1.58"
          extraEnv:
            - name: COLLECTOR_OTLP_ENABLED
              value: "true"
          resources:
            limits:
              cpu: 300m
              memory: 512Mi
            requests:
              cpu: 100m
              memory: 256Mi
        storage:
          type: memory
        agent:
          enabled: false
        collector:
          enabled: false
        query:
          enabled: false
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

echo ""
echo "✅ OpenTelemetry extension created!"
echo ""
echo "Files updated/created:"
find "$PROJECT_DIR" -type f | grep -v __pycache__ | sort
