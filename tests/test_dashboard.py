"""Tests verifying the dashboard contract — the /stats response has all fields the dashboard JS reads."""


def test_dashboard_html_loads(client):
    """The dashboard nginx pod serves index.html."""
    import httpx
    dash = httpx.Client(
        base_url="https://headroom-dashboard-openshift-ingress.apps.ocp.d4fcj.sandbox659.opentlc.com",
        verify=False, timeout=10.0,
    )
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
    # Send as Haiku ($0.80/MTok)
    client.post(
        "/v1/compress",
        json={"messages": sample_messages, "model": "claude-haiku-4-5-20251001"},
        headers={"x-maas-username": "pricing-verify"},
    )
    data = client.get("/stats").json()
    haiku_reqs = [r for r in data["recent_requests"]
                  if r["model"] == "claude-haiku-4-5-20251001" and r["tags"]["user-id"] == "pricing-verify"]
    assert len(haiku_reqs) > 0

    last = haiku_reqs[-1]
    assert last["cost_per_mtok"] == 0.8, f"Haiku should be $0.80/MTok, got ${last['cost_per_mtok']}"

    # Send as Opus ($15/MTok)
    client.post(
        "/v1/compress",
        json={"messages": sample_messages, "model": "claude-opus-4-6"},
        headers={"x-maas-username": "pricing-verify"},
    )
    data = client.get("/stats").json()
    opus_reqs = [r for r in data["recent_requests"]
                 if r["model"] == "claude-opus-4-6" and r["tags"]["user-id"] == "pricing-verify"]
    assert len(opus_reqs) > 0

    last = opus_reqs[-1]
    assert last["cost_per_mtok"] == 15.0, f"Opus should be $15/MTok, got ${last['cost_per_mtok']}"


def test_stats_cost_only_on_compressed(client):
    """Cost fields should only count requests where compression happened."""
    data = client.get("/stats").json()
    cost = data["summary"]["cost"]

    if cost["total_saved_usd"] > 0:
        assert cost["without_headroom_usd"] > 0
        assert cost["with_headroom_usd"] < cost["without_headroom_usd"]
        assert abs(cost["without_headroom_usd"] - cost["with_headroom_usd"] - cost["total_saved_usd"]) < 0.01


def test_pricing_endpoint(client):
    """The /pricing endpoint returns model costs from Postgres."""
    resp = client.get("/pricing")
    assert resp.status_code == 200
    data = resp.json()
    assert "models" in data
    assert "fallback_cost_per_mtok" in data
    models = data["models"]
    assert "claude-opus-4-6" in models
    assert models["claude-opus-4-6"] == 15.0
    assert "claude-haiku-4-5-20251001" in models
    assert models["claude-haiku-4-5-20251001"] == 0.8


def test_compress_returns_transforms(client, sample_messages):
    """The /v1/compress response includes transforms_applied."""
    resp = client.post("/v1/compress", json={"messages": sample_messages, "model": "test"})
    data = resp.json()
    assert "transforms_applied" in data
    assert isinstance(data["transforms_applied"], list)
