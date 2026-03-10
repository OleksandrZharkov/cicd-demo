# ── Build stage ───────────────────────────────────────────────
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .

# ВАЖНО: python:3.12-slim не включает setuptools.
# Устанавливаем setuptools<80 ПЕРВЫМ — иначе pip может подтянуть >= 80
# где pkg_resources удалён, а opentelemetry-instrumentation его требует.
# Источник: https://github.com/pypa/setuptools/issues/4483
RUN pip install --no-cache-dir "setuptools<80" && \
    pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Runtime stage ─────────────────────────────────────────────
FROM python:3.12-slim
WORKDIR /app

# Копируем установленные пакеты из builder
COPY --from=builder /install /usr/local

COPY app.py .

# ENV переменные — можно переопределить в Helm values.yaml
ENV APP_VERSION="1.0.0"
ENV OTEL_SERVICE_NAME="cicd-demo"
# ВАЖНО: для gRPC — только host:port, без http:// и без пути
ENV OTEL_EXPORTER_OTLP_ENDPOINT="otel-collector:4317"
ENV ENVIRONMENT="production"

EXPOSE 5000

# gunicorn: 2 worker'а достаточно для Minikube
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]
