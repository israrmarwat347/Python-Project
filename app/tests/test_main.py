"""Basic pytest tests for the Notes app."""
import os
os.environ.setdefault("DB_HOST", "127.0.0.1")      # init_db swallows errors on failure

from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)

def test_health_ok():
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}

def test_metrics_exposes_prometheus():
    r = client.get("/metrics")
    assert r.status_code == 200
    body = r.text
    assert "notes_app_requests_total" in body
    assert "notes_app_request_duration_seconds" in body

def test_notes_requires_auth():
    r = client.get("/notes")
    assert r.status_code == 401
