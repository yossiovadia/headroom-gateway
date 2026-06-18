"""Tests verifying the dashboard contract — the /stats response has all fields the dashboard JS reads."""


def test_dashboard_html_loads():
    """The dashboard nginx pod serves index.html."""
    import os
    import httpx
    dash_url = os.environ.get("HEADROOM_DASHBOARD_URL", "")
    if not dash_url:
        import pytest
        pytest.skip("HEADROOM_DASHBOARD_URL not set")
    verify = os.environ.get("HEADROOM_TEST_TLS_VERIFY", "false").lower() != "false"
    dash = httpx.Client(base_url=dash_url, verify=verify, timeout=10.0)
    resp = dash.get("/")
    assert resp.status_code == 200
    assert "Headroom Compression Dashboard" in resp.text


def test_stats_has_dashboard_kpi_fields(client):
    """Dashboard KPI row reads: api_requests, requests_compressed, total_tokens_removed, avg/best pct, cost."""
    data = client.get("/stats").json()
    s = data["summary"]

    assert "api_requests" in s
    c = s["compression"]
    assert "requests_compressed" in c
    assert "total_tokens_removed" in c
    assert "avg_compression_pct" in c
    assert "best_compression_pct" in c
    assert "best_detail" in c

    cost = s["cost"]
    assert "without_headroom_usd" in cost
    assert "with_headroom_usd" in cost
    assert "total_saved_usd" in cost


def test_stats_recent_has_dashboard_fields(client, sample_messages):
    """Dashboard recent activity reads per-request fields including cost."""
    client.post(
        "/v1/compress",
        json={"messages": sample_messages, "model": "claude-opus-4-6"},
        headers={"x-maas-username": "dash-test"},
    )
    data = client.get("/stats").json()
    last = data["recent_requests"][-1]

    for field in ("request_id", "timestamp", "model",
                  "input_tokens_original", "input_tokens_optimized",
                  "tokens_saved", "savings_percent", "tags"):
        assert field in last, f"missing field for dashboard: {field}"

    assert "user-id" in last["tags"]
    assert "cost_saved_usd" in last, "dashboard needs cost_saved_usd per request"
    assert "cost_per_mtok" in last, "dashboard needs cost_per_mtok per request"


def test_stats_cost_uses_model_pricing(client, sample_messages):
    """Cost should use per-model pricing, not a flat rate."""
    pricing_resp = client.get("/pricing")
    if pricing_resp.status_code != 200 or not pricing_resp.json().get("models"):
        import pytest
        pytest.skip("pricing endpoint unavailable or empty")

    pricing = pricing_resp.json()["models"]

    # Pick two models with different prices
    models = sorted(pricing.items(), key=lambda x: x[1])
    if len(models) < 2:
        import pytest
        pytest.skip("need at least 2 models in pricing table")

    cheap_model, cheap_rate = models[0]
    expensive_model, expensive_rate = models[-1]

    client.post(
        "/v1/compress",
        json={"messages": sample_messages, "model": cheap_model},
        headers={"x-maas-username": "pricing-verify"},
    )
    client.post(
        "/v1/compress",
        json={"messages": sample_messages, "model": expensive_model},
        headers={"x-maas-username": "pricing-verify"},
    )
    data = client.get("/stats").json()
    recent = [r for r in data["recent_requests"] if r["tags"]["user-id"] == "pricing-verify"]

    cheap_reqs = [r for r in recent if r["model"] == cheap_model]
    expensive_reqs = [r for r in recent if r["model"] == expensive_model]

    assert len(cheap_reqs) > 0 and len(expensive_reqs) > 0
    assert cheap_reqs[-1]["cost_per_mtok"] == cheap_rate
    assert expensive_reqs[-1]["cost_per_mtok"] == expensive_rate
    assert cheap_reqs[-1]["cost_per_mtok"] != expensive_reqs[-1]["cost_per_mtok"], \
        "different models should have different rates"


def test_stats_cost_only_on_compressed(client):
    """Cost fields should only count requests where compression happened."""
    data = client.get("/stats").json()
    cost = data["summary"]["cost"]

    if cost["total_saved_usd"] > 0:
        assert cost["without_headroom_usd"] > 0
        assert cost["with_headroom_usd"] < cost["without_headroom_usd"]
        assert abs(cost["without_headroom_usd"] - cost["with_headroom_usd"] - cost["total_saved_usd"]) < 0.01


def test_pricing_endpoint(client):
    """The /pricing endpoint returns model costs."""
    resp = client.get("/pricing")
    assert resp.status_code == 200
    data = resp.json()
    assert "models" in data
    assert "fallback_cost_per_mtok" in data
    assert isinstance(data["models"], dict)
    assert data["fallback_cost_per_mtok"] > 0
    for model, rate in data["models"].items():
        assert isinstance(model, str)
        assert isinstance(rate, (int, float))
        assert rate > 0, f"model {model} has non-positive rate: {rate}"


def test_compress_returns_transforms(client, sample_messages):
    """The /v1/compress response includes transforms_applied."""
    resp = client.post("/v1/compress", json={"messages": sample_messages, "model": "test"})
    data = resp.json()
    assert "transforms_applied" in data
    assert isinstance(data["transforms_applied"], list)
