"""Tests for SQLite stats persistence.

These tests verify data survives across service restarts.
They require the service to be running on OpenShift with a PVC mounted at /data.

Run with: HEADROOM_TEST_URL=https://... pytest tests/test_persistence.py -v

NOTE: These tests restart the headroom-service pod, which takes ~30-60s.
They are marked slow and skipped by default. Run with --run-slow to include them.
"""

import subprocess
import time

import pytest


def _oc(cmd: str, timeout: int = 120) -> str:
    result = subprocess.run(
        ["oc"] + cmd.split(),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return result.stdout + result.stderr


def _wait_for_ready(client, max_wait: int = 120):
    deadline = time.time() + max_wait
    while time.time() < deadline:
        try:
            resp = client.get("/readyz", timeout=5.0)
            if resp.status_code == 200:
                return
        except Exception:
            pass
        time.sleep(3)
    raise TimeoutError("headroom-service did not become ready after pod restart")


slow = pytest.mark.skipif(
    "not config.getoption('--run-slow', default=False)",
    reason="slow test: restarts pod. Use --run-slow to run.",
)


@slow
def test_stats_survive_pod_restart(client, sample_messages):
    client.post(
        "/v1/compress",
        json={"messages": sample_messages, "model": "persist-test"},
        headers={"x-maas-username": "persist-user"},
    )

    before = client.get("/stats").json()["summary"]
    before_requests = before["api_requests"]
    before_saved = before["compression"]["total_tokens_removed"]
    assert before_requests > 0

    _oc("delete pod -l app=headroom-service -n openshift-ingress --wait=true")
    _oc("rollout status deployment/headroom-service -n openshift-ingress --timeout=120s")
    _wait_for_ready(client)

    after = client.get("/stats").json()["summary"]
    assert after["api_requests"] == before_requests, \
        f"request count changed: {before_requests} → {after['api_requests']}"
    assert after["compression"]["total_tokens_removed"] == before_saved, \
        f"tokens saved changed: {before_saved} → {after['compression']['total_tokens_removed']}"


@slow
def test_recent_requests_rebuilt_from_db(client, sample_messages):
    client.post(
        "/v1/compress",
        json={"messages": sample_messages, "model": "rebuild-test"},
        headers={"x-maas-username": "rebuild-user"},
    )

    before_count = len(client.get("/stats").json()["recent_requests"])
    assert before_count > 0

    _oc("delete pod -l app=headroom-service -n openshift-ingress --wait=true")
    _oc("rollout status deployment/headroom-service -n openshift-ingress --timeout=120s")
    _wait_for_ready(client)

    after = client.get("/stats").json()
    assert len(after["recent_requests"]) == before_count, \
        "recent_requests should be rebuilt from DB on startup"

    users = {r["tags"]["user-id"] for r in after["recent_requests"]}
    assert "rebuild-user" in users
