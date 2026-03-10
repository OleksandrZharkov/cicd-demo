import os
import time
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

# ── OTel Resource (метаданные сервиса) ────────────────────────
# Resource.create принимает строковые ключи — официальный способ из документации
resource = Resource.create({
    "service.name":            os.getenv("OTEL_SERVICE_NAME", "cicd-demo"),
    "service.version":         os.getenv("APP_VERSION", "1.0.0"),
    "deployment.environment":  os.getenv("ENVIRONMENT", "development"),
})

# ── gRPC endpoint — БЕЗ http://, только host:port ─────────────
# Источник: https://opentelemetry.io/docs/languages/python/exporters/
# Для gRPC (порт 4317) — не включать путь /v1/traces
# Для HTTP (порт 4318) — нужен путь /v1/traces
otlp_grpc_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector:4317")

# ── Tracing setup ─────────────────────────────────────────────
tracer_provider = TracerProvider(resource=resource)
span_exporter = OTLPSpanExporter(
    endpoint=otlp_grpc_endpoint,
    insecure=True,   # без TLS, для внутреннего кластерного трафика
)
tracer_provider.add_span_processor(BatchSpanProcessor(span_exporter))
trace.set_tracer_provider(tracer_provider)

# ── Metrics setup ─────────────────────────────────────────────
metric_exporter = OTLPMetricExporter(
    endpoint=otlp_grpc_endpoint,
    insecure=True,
)
metric_reader = PeriodicExportingMetricReader(
    metric_exporter,
    export_interval_millis=5000,
)
meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
metrics.set_meter_provider(meter_provider)

# ── Получение tracer и meter ──────────────────────────────────
tracer = trace.get_tracer("cicd-demo.tracer")
meter  = metrics.get_meter("cicd-demo.meter")

# ── Кастомный счётчик запросов ────────────────────────────────
request_counter = meter.create_counter(
    name="http_requests_total",
    description="Total number of HTTP requests",
    unit="1",
)

# ── Flask app — создаём ДО instrument_app ─────────────────────
app = Flask(__name__)

# ── Инструментируем Flask — ПОСЛЕ создания app и настройки providers ──
# Источник: https://opentelemetry-python-contrib.readthedocs.io/en/latest/instrumentation/flask/flask.html
FlaskInstrumentor().instrument_app(
    app,
    excluded_urls="health",   # не трейсить /health — это просто liveness probe
)

VERSION = os.getenv("APP_VERSION", "1.0.0")


@app.route("/")
def home():
    request_counter.add(1, {"route": "/", "method": "GET"})

    with tracer.start_as_current_span("home-handler") as span:
        span.set_attribute("app.version", VERSION)
        span.set_attribute("custom.label", "hello-span")
        return jsonify({
            "message": "Hello from CI/CD Demo with OpenTelemetry!",
            "version": VERSION,
            "status": "ok",
            "tracing": "enabled",
        })


@app.route("/health")
def health():
    # excluded_urls="health" → этот маршрут не создаёт spans
    return jsonify({"status": "healthy"}), 200


@app.route("/work")
def work():
    """Вложенные spans — хорошо видно в Jaeger UI."""
    request_counter.add(1, {"route": "/work", "method": "GET"})

    with tracer.start_as_current_span("work-handler") as parent_span:
        parent_span.set_attribute("work.type", "simulation")

        with tracer.start_as_current_span("db-query-simulation") as child_span:
            child_span.set_attribute("db.system", "postgresql")
            child_span.set_attribute("db.statement", "SELECT * FROM items")
            time.sleep(0.05)   # симуляция запроса к БД

        with tracer.start_as_current_span("cache-lookup") as cache_span:
            cache_span.set_attribute("cache.hit", True)

        return jsonify({"result": "work done", "spans": "check Jaeger!"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
