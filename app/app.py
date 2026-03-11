import logging
import os
import time

from flask import Flask, jsonify, request
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("cicd-prod")

resource = Resource.create(
    {
        "service.name": os.getenv("OTEL_SERVICE_NAME", "cicd-prod"),
        "service.version": os.getenv("APP_VERSION", "1.0.0"),
        "deployment.environment": os.getenv("ENVIRONMENT", "production"),
    }
)

otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector:4317")

tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True))
)
trace.set_tracer_provider(tracer_provider)

meter_provider = MeterProvider(
    resource=resource,
    metric_readers=[
        PeriodicExportingMetricReader(
            OTLPMetricExporter(endpoint=otlp_endpoint, insecure=True),
            export_interval_millis=5000,
        )
    ],
)
metrics.set_meter_provider(meter_provider)

tracer = trace.get_tracer("cicd-prod.tracer")
meter = metrics.get_meter("cicd-prod.meter")

request_counter = meter.create_counter(
    name="http_requests_total",
    description="Total HTTP requests",
    unit="1",
)
request_latency = meter.create_histogram(
    name="http_request_duration_ms",
    description="HTTP request latency in ms",
    unit="ms",
)

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app, excluded_urls="health,ready")

VERSION = os.getenv("APP_VERSION", "1.0.0")
ENVIRONMENT = os.getenv("ENVIRONMENT", "production")


@app.before_request
def start_timer():
    request.start_time = time.time()


@app.after_request
def record_metrics(response):
    duration_ms = (time.time() - request.start_time) * 1000
    request_counter.add(
        1,
        {
            "route": request.path,
            "method": request.method,
            "status": str(response.status_code),
        },
    )
    request_latency.record(duration_ms, {"route": request.path})
    return response


@app.route("/")
def home():
    with tracer.start_as_current_span("home-handler") as span:
        span.set_attribute("app.version", VERSION)
        logger.info("home endpoint called")
        return jsonify(
            {
                "message": "Production CI/CD Demo",
                "version": VERSION,
                "environment": ENVIRONMENT,
                "status": "ok",
            }
        )


@app.route("/health")
def health():
    """Liveness probe — не трейсится."""
    return jsonify({"status": "healthy"}), 200


@app.route("/ready")
def ready():
    """Readiness probe — не трейсится."""
    return jsonify({"status": "ready"}), 200


@app.route("/work")
def work():
    """Симуляция бизнес-логики с вложенными spans."""
    with tracer.start_as_current_span("work-handler") as span:
        span.set_attribute("work.type", "simulation")

        with tracer.start_as_current_span("db-query") as db_span:
            db_span.set_attribute("db.system", "postgresql")
            db_span.set_attribute("db.statement", "SELECT * FROM orders")
            time.sleep(0.05)

        with tracer.start_as_current_span("cache-lookup") as cache_span:
            cache_span.set_attribute("cache.hit", True)

        logger.info("work endpoint completed")
        return jsonify({"result": "ok", "spans": "visible in Jaeger"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)