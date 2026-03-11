# hadolint ignore=DL3006
FROM python:3.12-slim AS builder

WORKDIR /app

COPY app/requirements.txt .

# setuptools<80 устанавливаем первым — pkg_resources нужен opentelemetry-instrumentation
# hadolint ignore=DL3013
RUN pip install --no-cache-dir "setuptools<80" && \
    pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Runtime stage ─────────────────────────────────────────────
FROM python:3.12-slim

RUN groupadd --gid 1001 appgroup && \
    useradd  --uid 1001 --gid appgroup --no-create-home appuser

WORKDIR /app

COPY --from=builder /install /usr/local

# context в workflow передаётся как корень репозитория (context: .)
# поэтому путь к файлу — app/app.py
COPY app/app.py .

USER appuser

ENV APP_VERSION="1.0.0" \
    OTEL_SERVICE_NAME="cicd-prod" \
    OTEL_EXPORTER_OTLP_ENDPOINT="otel-collector:4317" \
    ENVIRONMENT="production" \
    PYTHONDONTWRITEBYTECODE="1" \
    PYTHONUNBUFFERED="1"

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')"

CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", \
     "--timeout", "30", "--keep-alive", "5", \
     "--access-logfile", "-", "--error-logfile", "-", \
     "app:app"]
