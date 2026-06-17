"""Tests for /stats and /stats-history endpoints."""


def test_stats_returns_required_structure(client):
    resp = client.get("/stats")
    assert resp.status_code == 200
    data = resp.json()

    assert "summary" in data
    assert "recent_requests" in data

    summary = data["summary"]
    assert "api_requests" in summary
    assert "compression" in summary
    assert "cost" in summary


def test_stats_compression_fields(client):
    data = client.get("/stats").json()
    comp = data["summary"]["compression"]
    for field in ("requests_compressed", "avg_compression_pct", "total_tokens_removed",
                  "best_compression_pct", "best_detail"):
        assert field in comp, f"missing compression field: {field}"


def test_stats_cost_fields(client):
    data = client.get("/stats").json()
    cost = data["summary"]["cost"]
    for field in ("without_headroom_usd", "with_headroom_usd", "total_saved_usd"):
        assert field in cost, f"missing cost field: {field}"


def test_stats_after_compression(client, sample_messages):
    before = client.get("/stats").json()["summary"]["api_requests"]
    client.post("/v1/compress", json={"messages": sample_messages, "model": "stats-test"})
    after = client.get("/stats").json()["summary"]

    assert after["api_requests"] == before + 1
    assert after["compression"]["total_tokens_removed"] > 0


def test_stats_cost_math(client):
    data = client.get("/stats").json()
    cost = data["summary"]["cost"]
    without = cost["without_headroom_usd"]
    with_hr = cost["with_headroom_usd"]
    saved = cost["total_saved_usd"]

    if without > 0:
        assert abs((without - with_hr) - saved) < 0.001, "cost math: without - with != saved"


def test_stats_recent_requests_format(client, sample_messages):
    client.post(
        "/v1/compress",
        json={"messages": sample_messages, "model": "recent-test"},
        headers={"x-maas-username": "recent-user"},
    )
    data = client.get("/stats").json()
    recent = data["recent_requests"]
    assert len(recent) > 0

    last = recent[-1]
    for field in ("request_id", "timestamp", "model", "input_tokens_original",
                  "input_tokens_optimized", "tokens_saved", "savings_percent", "tags"):
        assert field in last, f"missing recent_requests field: {field}"
    assert "user-id" in last["tags"]


def test_stats_per_user_tracking(client, sample_messages):
    client.post(
        "/v1/compress",
        json={"messages": sample_messages, "model": "test"},
        headers={"x-maas-username": "alice"},
    )
    client.post(
        "/v1/compress",
        json={"messages": sample_messages, "model": "test"},
        headers={"x-maas-username": "bob"},
    )
    data = client.get("/stats").json()
    users = {r["tags"]["user-id"] for r in data["recent_requests"]}
    assert "alice" in users
    assert "bob" in users


def test_stats_history_returns_structure(client):
    resp = client.get("/stats-history")
    assert resp.status_code == 200
    data = resp.json()

    assert "lifetime" in data
    assert "history" in data

    lt = data["lifetime"]
    for field in ("requests", "tokens_saved", "compression_savings_usd"):
        assert field in lt, f"missing lifetime field: {field}"


def test_stats_history_only_compressed(client):
    data = client.get("/stats-history").json()
    for entry in data["history"]:
        assert entry["total_tokens_saved"] > 0, "history should only include compressed requests"
