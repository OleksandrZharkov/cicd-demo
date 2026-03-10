"""
Unit tests for cicd-prod Flask application.
Запуск: pytest app/tests/ -v --cov=app --cov-report=term-missing
"""
import os
import pytest

# Отключаем OTel экспортёры в тестах — нет реального коллектора
os.environ["OTEL_SDK_DISABLED"] = "true"
os.environ["APP_VERSION"]       = "test-1.0.0"
os.environ["ENVIRONMENT"]       = "test"

# Импортируем приложение ПОСЛЕ установки env vars
from app.app import app as flask_app   # noqa: E402


@pytest.fixture
def client():
    flask_app.config["TESTING"] = True
    with flask_app.test_client() as c:
        yield c


class TestHomeEndpoint:
    def test_returns_200(self, client):
        resp = client.get("/")
        assert resp.status_code == 200

    def test_json_structure(self, client):
        data = client.get("/").get_json()
        assert "message" in data
        assert "version" in data
        assert "status" in data
        assert data["status"] == "ok"

    def test_version_from_env(self, client):
        data = client.get("/").get_json()
        assert data["version"] == "test-1.0.0"

    def test_environment_from_env(self, client):
        data = client.get("/").get_json()
        assert data["environment"] == "test"


class TestHealthEndpoints:
    def test_health_returns_200(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200

    def test_health_status_healthy(self, client):
        data = client.get("/health").get_json()
        assert data["status"] == "healthy"

    def test_ready_returns_200(self, client):
        resp = client.get("/ready")
        assert resp.status_code == 200

    def test_ready_status_ready(self, client):
        data = client.get("/ready").get_json()
        assert data["status"] == "ready"


class TestWorkEndpoint:
    def test_returns_200(self, client):
        resp = client.get("/work")
        assert resp.status_code == 200

    def test_json_has_result(self, client):
        data = client.get("/work").get_json()
        assert "result" in data
        assert data["result"] == "ok"


class TestNotFound:
    def test_unknown_route_returns_404(self, client):
        resp = client.get("/nonexistent")
        assert resp.status_code == 404
