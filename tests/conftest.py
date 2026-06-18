import os
import json

import pytest
import httpx


def pytest_addoption(parser):
    parser.addoption("--run-slow", action="store_true", default=False, help="run slow tests")

HEADROOM_URL = os.environ.get("HEADROOM_TEST_URL", "")
if not HEADROOM_URL:
    pytest.exit("HEADROOM_TEST_URL env var required — set to the headroom service URL", returncode=1)


@pytest.fixture(scope="session")
def headroom_url():
    return HEADROOM_URL


@pytest.fixture(scope="session")
def client():
    verify = os.environ.get("HEADROOM_TEST_TLS_VERIFY", "false").lower() != "false"
    return httpx.Client(base_url=HEADROOM_URL, verify=verify, timeout=30.0)


@pytest.fixture
def sample_messages():
    """Realistic coding session with tool outputs — enough turns for compression."""
    return [
        {"role": "user", "content": "list all pods"},
        {"role": "assistant", "content": None, "tool_calls": [
            {"id": "call_1", "type": "function",
             "function": {"name": "kubectl_get", "arguments": "{}"}}
        ]},
        {"role": "tool", "tool_call_id": "call_1", "content": json.dumps([
            {"name": f"pod-{i}", "namespace": f"ns-{i%5}", "status": "Running",
             "ip": f"10.0.{i}.1", "node": f"worker-{i%3}", "restarts": i % 4,
             "age": f"{i}d", "cpu": f"{i*5}m", "memory": f"{64+i*8}Mi",
             "labels": {"app": f"app-{i%5}", "version": f"v{i%3}.{i%10}"}}
            for i in range(30)
        ])},
        {"role": "user", "content": "which are failing?"},
        {"role": "assistant", "content": "All pods are running."},
        {"role": "user", "content": "check services too"},
        {"role": "assistant", "content": None, "tool_calls": [
            {"id": "call_2", "type": "function",
             "function": {"name": "kubectl_get_svc", "arguments": "{}"}}
        ]},
        {"role": "tool", "tool_call_id": "call_2", "content": json.dumps([
            {"name": f"svc-{i}", "namespace": f"ns-{i%3}", "type": "ClusterIP",
             "clusterIP": f"10.96.{i}.1", "ports": f"{8080+i}/TCP",
             "selector": {"app": f"app-{i%3}"}, "age": f"{i*2}d"}
            for i in range(15)
        ])},
        {"role": "user", "content": "summarize"},
    ]


@pytest.fixture
def small_messages():
    """Too small to compress — below min_tokens threshold."""
    return [
        {"role": "user", "content": "hello"},
        {"role": "assistant", "content": "hi there"},
    ]


@pytest.fixture
def log_messages():
    """Build log content — triggers Kompress ML (text compression), not SmartCrusher."""
    log_lines = []
    for i in range(50):
        ts = f"2026-06-17T08:{i//60:02d}:{i%60:02d}Z"
        if i < 15:
            log_lines.append(f"{ts} [INFO] Installing package-{i}=={i}.0.{i}")
        elif i < 35:
            test_num = i - 15
            log_lines.append(f"{ts} [TEST] test_api_{['health','auth','users','orders','payments','search','cache','metrics','rate','notify'][test_num%10]}_{['list','create','update','delete'][test_num%4]} ... PASSED ({0.02+test_num*0.03:.2f}s)")
        elif i < 45:
            step = i - 35
            log_lines.append(f"{ts} [BUILD] STEP {step+1}/10: {['FROM python:3.12-slim','COPY requirements.txt .','RUN pip install -r requirements.txt','COPY src/ /app/src/','COPY config/ /app/config/','COPY migrations/ /app/migrations/','RUN python -m pytest','WORKDIR /app','EXPOSE 8080','CMD uvicorn main:app'][step]}")
        else:
            log_lines.append(f"{ts} [INFO] Build pipeline step {i} completed successfully")

    return [
        {"role": "user", "content": "show build logs"},
        {"role": "assistant", "content": None, "tool_calls": [
            {"id": "call_log", "type": "function",
             "function": {"name": "get_build_logs", "arguments": "{}"}}
        ]},
        {"role": "tool", "tool_call_id": "call_log", "content": "\n".join(log_lines)},
        {"role": "user", "content": "any failures?"},
        {"role": "assistant", "content": "All tests passed."},
        {"role": "user", "content": "deploy it"},
        {"role": "assistant", "content": "deploying"},
        {"role": "user", "content": "status?"},
    ]


@pytest.fixture
def code_messages():
    """Source code content — tests compression of code/text tool outputs."""
    code = '''import os
import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from fastapi import FastAPI, Request, Response, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import httpx

logger = logging.getLogger(__name__)

app = FastAPI(title="API Gateway", version="2.4.1")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

class UserCreate(BaseModel):
    username: str = Field(..., min_length=3, max_length=50)
    email: str = Field(..., pattern=r"^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\\.[a-zA-Z0-9-.]+$")
    full_name: Optional[str] = None
    role: str = Field(default="user", pattern=r"^(admin|user|viewer)$")

class UserResponse(BaseModel):
    id: int
    username: str
    email: str
    full_name: Optional[str]
    role: str
    created_at: datetime
    last_login: Optional[datetime]

class OrderCreate(BaseModel):
    product_id: int
    quantity: int = Field(..., ge=1, le=1000)
    shipping_address: str
    payment_method: str = Field(..., pattern=r"^(credit_card|bank_transfer|paypal)$")

class OrderResponse(BaseModel):
    id: int
    product_id: int
    quantity: int
    total_price: float
    status: str
    created_at: datetime

_db_pool = None
_redis_client = None

async def get_db():
    global _db_pool
    if _db_pool is None:
        import asyncpg
        _db_pool = await asyncpg.create_pool(os.environ["DATABASE_URL"], min_size=5, max_size=20)
    return _db_pool

async def get_redis():
    global _redis_client
    if _redis_client is None:
        import redis.asyncio as redis
        _redis_client = redis.from_url(os.environ.get("REDIS_URL", "redis://localhost:6379"))
    return _redis_client

@app.get("/api/v1/users", response_model=list[UserResponse])
async def list_users(skip: int = 0, limit: int = 50):
    db = await get_db()
    rows = await db.fetch("SELECT * FROM users ORDER BY created_at DESC OFFSET $1 LIMIT $2", skip, limit)
    return [UserResponse(**dict(r)) for r in rows]

@app.post("/api/v1/users", response_model=UserResponse, status_code=201)
async def create_user(user: UserCreate):
    db = await get_db()
    try:
        row = await db.fetchrow(
            "INSERT INTO users (username, email, full_name, role) VALUES ($1, $2, $3, $4) RETURNING *",
            user.username, user.email, user.full_name, user.role
        )
        return UserResponse(**dict(row))
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.get("/api/v1/orders", response_model=list[OrderResponse])
async def list_orders(user_id: Optional[int] = None, status: Optional[str] = None):
    db = await get_db()
    query = "SELECT * FROM orders WHERE 1=1"
    params = []
    if user_id:
        params.append(user_id)
        query += f" AND user_id = ${len(params)}"
    if status:
        params.append(status)
        query += f" AND status = ${len(params)}"
    query += " ORDER BY created_at DESC LIMIT 100"
    rows = await db.fetch(query, *params)
    return [OrderResponse(**dict(r)) for r in rows]

@app.post("/api/v1/orders", response_model=OrderResponse, status_code=201)
async def create_order(order: OrderCreate, request: Request):
    db = await get_db()
    redis = await get_redis()
    product = await db.fetchrow("SELECT * FROM products WHERE id = $1", order.product_id)
    if not product:
        raise HTTPException(status_code=404, detail="Product not found")
    total = product["price"] * order.quantity
    row = await db.fetchrow(
        "INSERT INTO orders (product_id, quantity, total_price, shipping_address, payment_method, status) VALUES ($1, $2, $3, $4, $5, $6) RETURNING *",
        order.product_id, order.quantity, total, order.shipping_address, order.payment_method, "pending"
    )
    await redis.publish("orders:new", json.dumps({"order_id": row["id"], "total": total}))
    return OrderResponse(**dict(row))

@app.get("/health")
async def health():
    return {"status": "ok", "version": "2.4.1", "timestamp": datetime.now(timezone.utc).isoformat()}
'''
    return [
        {"role": "user", "content": "show me the main api file"},
        {"role": "assistant", "content": None, "tool_calls": [
            {"id": "call_code", "type": "function",
             "function": {"name": "read_file", "arguments": '{"path": "src/main.py"}'}}
        ]},
        {"role": "tool", "tool_call_id": "call_code", "content": code},
        {"role": "user", "content": "looks good, any issues?"},
        {"role": "assistant", "content": "The code looks clean."},
        {"role": "user", "content": "add rate limiting"},
        {"role": "assistant", "content": "I will add rate limiting."},
        {"role": "user", "content": "show the diff"},
    ]
