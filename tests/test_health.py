"""Tests for health, readiness, and metrics endpoints."""


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


def test_readyz(client):
    resp = client.get("/readyz")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ready"
    assert "db" in data
    assert "uptime_seconds" in data
    assert data["uptime_seconds"] >= 0


def test_metrics_format(client):
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert "text/plain" in resp.headers["content-type"]

    body = resp.text
    assert "headroom_requests_total" in body
    assert "headroom_compressed_total" in body
    assert "headroom_tokens_saved_total" in body
    assert "headroom_tokens_before_total" in body
    assert "headroom_tokens_after_total" in body
    assert "headroom_errors_total" in body
    assert "headroom_uptime_seconds" in body


def test_metrics_counters_increment(client, sample_messages):
    before = {}
    for line in client.get("/metrics").text.strip().split("\n"):
        if line and not line.startswith("#"):
            parts = line.split()
            if len(parts) == 2:
                before[parts[0]] = int(float(parts[1]))

    client.post("/v1/compress", json={"messages": sample_messages, "model": "metrics-test"})

    after = {}
    for line in client.get("/metrics").text.strip().split("\n"):
        if line and not line.startswith("#"):
            parts = line.split()
            if len(parts) == 2:
                after[parts[0]] = int(float(parts[1]))

    assert after["headroom_requests_total"] == before.get("headroom_requests_total", 0) + 1
    assert after["headroom_tokens_before_total"] > before.get("headroom_tokens_before_total", 0)


def test_metrics_type_annotations(client):
    body = client.get("/metrics").text
    assert "# TYPE headroom_requests_total counter" in body
    assert "# TYPE headroom_uptime_seconds gauge" in body
