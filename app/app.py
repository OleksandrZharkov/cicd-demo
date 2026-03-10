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
