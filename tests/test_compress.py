"""Tests for the /v1/compress endpoint."""

import json


def test_compress_returns_required_fields(client, sample_messages):
    resp = client.post("/v1/compress", json={"messages": sample_messages, "model": "test-model"})
    assert resp.status_code == 200
    data = resp.json()
    for field in ("messages", "tokens_before", "tokens_after", "tokens_saved", "compression_ratio"):
        assert field in data, f"missing field: {field}"


def test_compress_reduces_tokens(client, sample_messages):
    resp = client.post("/v1/compress", json={"messages": sample_messages, "model": "test-model"})
    data = resp.json()
    assert data["tokens_before"] > 0
    assert data["tokens_saved"] > 0, "expected savings on 30-item JSON array tool output"
    assert data["tokens_after"] < data["tokens_before"]


def test_compress_ratio_is_valid(client, sample_messages):
    resp = client.post("/v1/compress", json={"messages": sample_messages, "model": "test-model"})
    data = resp.json()
    ratio = data["compression_ratio"]
    assert 0.0 <= ratio <= 1.0, f"ratio out of range: {ratio}"


def test_compress_empty_messages(client):
    resp = client.post("/v1/compress", json={"messages": [], "model": "test"})
    assert resp.status_code == 200
    data = resp.json()
    assert data["tokens_before"] == 0
    assert data["tokens_saved"] == 0
    assert data["messages"] == []


def test_compress_small_messages_passthrough(client, small_messages):
    resp = client.post("/v1/compress", json={"messages": small_messages, "model": "test"})
    assert resp.status_code == 200
    data = resp.json()
    assert data["tokens_saved"] == 0, "small messages should not be compressed"
    assert len(data["messages"]) == len(small_messages)


def test_compress_preserves_message_count(client, sample_messages):
    resp = client.post("/v1/compress", json={"messages": sample_messages, "model": "test"})
    data = resp.json()
    assert len(data["messages"]) == len(sample_messages), "message count must not change"


def test_compress_preserves_user_messages(client, sample_messages):
    resp = client.post("/v1/compress", json={"messages": sample_messages, "model": "test"})
    data = resp.json()
    for orig, comp in zip(sample_messages, data["messages"]):
        if orig.get("role") == "user":
            assert comp["content"] == orig["content"], "user messages must not be modified"


def test_compress_tracks_user_from_header(client, sample_messages):
    resp = client.post(
        "/v1/compress",
        json={"messages": sample_messages, "model": "test"},
        headers={"x-maas-username": "test-user-header"},
    )
    assert resp.status_code == 200

    stats = client.get("/stats").json()
    users = [r["tags"]["user-id"] for r in stats["recent_requests"]]
    assert "test-user-header" in users


def test_compress_anonymous_without_header(client, small_messages):
    resp = client.post("/v1/compress", json={"messages": small_messages, "model": "test"})
    assert resp.status_code == 200

    stats = client.get("/stats").json()
    last = stats["recent_requests"][-1]
    assert last["tags"]["user-id"] == "anonymous"


def test_compress_model_propagated(client, small_messages):
    resp = client.post("/v1/compress", json={"messages": small_messages, "model": "claude-opus-4-8"})
    assert resp.status_code == 200

    stats = client.get("/stats").json()
    last = stats["recent_requests"][-1]
    assert last["model"] == "claude-opus-4-8"


def test_compress_default_model(client, small_messages):
    resp = client.post("/v1/compress", json={"messages": small_messages})
    assert resp.status_code == 200

    stats = client.get("/stats").json()
    last = stats["recent_requests"][-1]
    assert last["model"] == "default"


def test_compress_log_content(client, log_messages):
    """Build logs should compress significantly — triggers text/log compression."""
    resp = client.post("/v1/compress", json={"messages": log_messages, "model": "claude-opus-4-6"})
    assert resp.status_code == 200
    data = resp.json()
    assert data["tokens_before"] > 500, "log fixture should be above min_tokens threshold"
    assert data["tokens_saved"] > 0, "log content should compress"
    savings_pct = data["tokens_saved"] / data["tokens_before"] * 100
    assert savings_pct > 30, f"expected >30% savings on logs, got {savings_pct:.1f}%"


def test_compress_code_content(client, code_messages):
    """Source code should compress — triggers code/text compression."""
    resp = client.post("/v1/compress", json={"messages": code_messages, "model": "claude-sonnet-4-20250514"})
    assert resp.status_code == 200
    data = resp.json()
    assert data["tokens_before"] > 500, "code fixture should be above min_tokens threshold"
    assert data["tokens_saved"] > 0, "code content should compress"


def test_compress_log_preserves_errors(client):
    """Error lines in logs should be preserved after compression."""
    messages = [
        {"role": "user", "content": "check logs"},
        {"role": "assistant", "content": None, "tool_calls": [
            {"id": "call_err", "type": "function",
             "function": {"name": "get_logs", "arguments": "{}"}}
        ]},
        {"role": "tool", "tool_call_id": "call_err", "content": "\n".join([
            f"2026-06-17T10:{i:02d}:00Z [INFO] Processing request {i}" for i in range(40)
        ] + [
            "2026-06-17T10:40:00Z [ERROR] Connection refused to database at 10.0.2.1:5432",
            "2026-06-17T10:40:01Z [FATAL] Service shutting down due to unrecoverable error",
        ])},
        {"role": "user", "content": "what happened?"},
        {"role": "assistant", "content": "checking"},
        {"role": "user", "content": "fix it"},
        {"role": "assistant", "content": "fixing"},
        {"role": "user", "content": "done?"},
    ]
    resp = client.post("/v1/compress", json={"messages": messages, "model": "test"})
    data = resp.json()
    tool_msg = next(m for m in data["messages"] if m.get("role") == "tool")
    content = tool_msg["content"]
    assert "ERROR" in content or "FATAL" in content or "Connection refused" in content, \
        "error lines should survive compression"
