import os
import time
import sqlite3
import threading
import logging
from collections import OrderedDict, deque
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

import uvicorn
from fastapi import FastAPI, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from headroom import compress
from headroom.cache.compression_cache import CompressionCache

DB_PATH = os.environ.get("HEADROOM_STATS_DB", "/data/headroom-stats.db")
PRICING_DSN = os.environ.get("HEADROOM_PRICING_DSN", "")
FALLBACK_COST_PER_MTOK = float(os.environ.get("HEADROOM_COST_PER_MTOK", "15.0"))
PRICING_REFRESH_SECONDS = 300

logger = logging.getLogger("headroom-service")

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Model pricing (from metering Postgres)
# ---------------------------------------------------------------------------

_pricing: dict[str, float] = {}
_pricing_aliases: dict[str, float] = {}
_pricing_last_refresh: float = 0


def _refresh_pricing() -> None:
    global _pricing, _pricing_aliases, _pricing_last_refresh
    if time.time() - _pricing_last_refresh < PRICING_REFRESH_SECONDS:
        return
    if not PRICING_DSN:
        _pricing_last_refresh = time.time()
        return
    try:
        import psycopg2
        conn = psycopg2.connect(PRICING_DSN, connect_timeout=5)
        cur = conn.cursor()
        cur.execute("SELECT model, input_cost_per_mtok FROM model_pricing")
        _pricing = {row[0]: float(row[1]) for row in cur.fetchall()}
        cur.close()
        conn.close()
        _pricing_aliases = {}
        _pricing_last_refresh = time.time()
        logger.info("refreshed model pricing: %d models", len(_pricing))
    except Exception as e:
        logger.warning("failed to refresh pricing: %s", type(e).__name__)
        if not _pricing:
            _pricing_last_refresh = 0


def _cost_per_mtok(model: str) -> float:
    _refresh_pricing()
    if model in _pricing:
        return _pricing[model]
    if model in _pricing_aliases:
        return _pricing_aliases[model]
    for key, val in _pricing.items():
        if key in model or model in key:
            _pricing_aliases[model] = val
            return val
    _pricing_aliases[model] = FALLBACK_COST_PER_MTOK
    return FALLBACK_COST_PER_MTOK


# ---------------------------------------------------------------------------
# SQLite persistence
# ---------------------------------------------------------------------------

def _init_db(path: str) -> None:
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS requests (
            id TEXT PRIMARY KEY,
            timestamp TEXT NOT NULL,
            model TEXT NOT NULL,
            user_id TEXT NOT NULL,
            tokens_before INTEGER NOT NULL,
            tokens_after INTEGER NOT NULL,
            tokens_saved INTEGER NOT NULL,
            savings_pct REAL NOT NULL,
            cost_saved_usd REAL NOT NULL DEFAULT 0,
            cost_per_mtok REAL NOT NULL DEFAULT 0,
            transforms TEXT NOT NULL DEFAULT ''
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_ts ON requests(timestamp)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_user ON requests(user_id)")
    conn.execute("PRAGMA journal_mode=WAL")
    # migrate: add cost columns if missing (existing DBs)
    cols = {r[1] for r in conn.execute("PRAGMA table_info(requests)").fetchall()}
    if "cost_saved_usd" not in cols:
        conn.execute("ALTER TABLE requests ADD COLUMN cost_saved_usd REAL NOT NULL DEFAULT 0")
    if "cost_per_mtok" not in cols:
        conn.execute("ALTER TABLE requests ADD COLUMN cost_per_mtok REAL NOT NULL DEFAULT 0")
    conn.commit()
    conn.close()


_db_lock = threading.Lock()


@contextmanager
def _db():
    with _db_lock:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()


_init_db(DB_PATH)

_recent: deque = deque(maxlen=100)
_startup_time = time.time()

# Per-user compression cache — avoids re-compressing content seen in earlier requests
MAX_USER_SESSIONS = int(os.environ.get("HEADROOM_MAX_USER_SESSIONS", "200"))
MAX_CACHE_ENTRIES = int(os.environ.get("HEADROOM_MAX_CACHE_ENTRIES", "5000"))
SESSION_TTL_SECONDS = int(os.environ.get("HEADROOM_SESSION_TTL", "7200"))
_user_caches: OrderedDict[str, tuple[CompressionCache, float]] = OrderedDict()
_user_cache_lock = threading.Lock()


def _get_user_cache(user_id: str) -> CompressionCache:
    now = time.time()
    with _user_cache_lock:
        if user_id in _user_caches:
            cache, _ = _user_caches[user_id]
            _user_caches[user_id] = (cache, now)
            _user_caches.move_to_end(user_id)
            return cache
        cache = CompressionCache(max_entries=MAX_CACHE_ENTRIES)
        _user_caches[user_id] = (cache, now)
        # Evict oldest sessions if over limit
        while len(_user_caches) > MAX_USER_SESSIONS:
            _user_caches.popitem(last=False)
        # Evict expired sessions
        expired = [k for k, (_, ts) in _user_caches.items() if now - ts > SESSION_TTL_SECONDS]
        for k in expired:
            del _user_caches[k]
        return cache


def _load_recent_from_db() -> None:
    with _db() as conn:
        rows = conn.execute(
            "SELECT * FROM requests ORDER BY timestamp DESC LIMIT 100"
        ).fetchall()
        for row in reversed(rows):
            _recent.append(dict(row))


_load_recent_from_db()

_prom_requests = 0
_prom_compressed = 0
_prom_tokens_before = 0
_prom_tokens_after = 0
_prom_tokens_saved = 0
_prom_errors = 0


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

class CompressRequest(BaseModel):
    messages: list
    model: str = "default"
    protect_recent: int | None = None
    min_tokens_to_compress: int | None = None


@app.post("/v1/compress")
def compress_messages(req: CompressRequest, request: Request):
    global _prom_requests, _prom_compressed, _prom_tokens_before, _prom_tokens_after, _prom_tokens_saved, _prom_errors

    user_id = request.headers.get(
        "x-maas-username",
        request.headers.get("x-headroom-user-id", "anonymous"),
    )

    try:
        kwargs = {}
        if req.protect_recent is not None:
            kwargs["protect_recent"] = req.protect_recent
        if req.min_tokens_to_compress is not None:
            kwargs["min_tokens_to_compress"] = req.min_tokens_to_compress

        cache = _get_user_cache(user_id)
        working_messages = cache.apply_cached(req.messages)
        result = compress(messages=working_messages, model=req.model, **kwargs)
        cache.update_from_result(req.messages, result.messages)
    except Exception as e:
        _prom_errors += 1
        return {"messages": req.messages, "tokens_before": 0, "tokens_after": 0,
                "tokens_saved": 0, "compression_ratio": 1.0, "error": str(e)}

    saved = result.tokens_saved
    pct = round((saved / result.tokens_before * 100) if result.tokens_before > 0 else 0, 1)
    now = datetime.now(timezone.utc)
    req_id = f"hr_{int(now.timestamp())}_{_prom_requests:06d}"

    model_cost = _cost_per_mtok(req.model)
    cost_saved = round(saved * model_cost / 1_000_000, 6) if saved > 0 else 0.0

    row = {
        "id": req_id,
        "timestamp": now.isoformat(),
        "model": req.model,
        "user_id": user_id,
        "tokens_before": result.tokens_before,
        "tokens_after": result.tokens_after,
        "tokens_saved": saved,
        "savings_pct": pct,
        "cost_saved_usd": cost_saved,
        "cost_per_mtok": model_cost,
        "transforms": ",".join(result.transforms_applied) if result.transforms_applied else "",
    }

    with _db() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO requests VALUES (:id,:timestamp,:model,:user_id,:tokens_before,:tokens_after,:tokens_saved,:savings_pct,:cost_saved_usd,:cost_per_mtok,:transforms)",
            row,
        )

    _recent.append(row)
    _prom_requests += 1
    _prom_tokens_before += result.tokens_before
    _prom_tokens_after += result.tokens_after
    _prom_tokens_saved += saved
    if saved > 0:
        _prom_compressed += 1

    return {
        "messages": result.messages,
        "tokens_before": result.tokens_before,
        "tokens_after": result.tokens_after,
        "tokens_saved": saved,
        "compression_ratio": result.compression_ratio,
        "transforms_applied": result.transforms_applied,
    }


@app.get("/stats")
def get_stats():
    with _db() as conn:
        # Only count cost on requests where compression actually happened
        agg = conn.execute("""
            SELECT
                COUNT(*) as total,
                SUM(CASE WHEN tokens_saved > 0 THEN 1 ELSE 0 END) as compressed,
                COALESCE(SUM(tokens_saved), 0) as total_saved,
                COALESCE(MAX(savings_pct), 0) as best_pct
            FROM requests
        """).fetchone()

        cost_agg = conn.execute("""
            SELECT
                COALESCE(SUM(tokens_before * cost_per_mtok / 1000000.0), 0) as cost_before,
                COALESCE(SUM(tokens_after * cost_per_mtok / 1000000.0), 0) as cost_after,
                COALESCE(SUM(cost_saved_usd), 0) as cost_saved
            FROM requests
            WHERE tokens_saved > 0
        """).fetchone()

        total = agg["total"]
        total_saved = agg["total_saved"]
        compressed_count = agg["compressed"] or 0

        # avg compression % only from compressed requests
        avg_row = conn.execute(
            "SELECT COALESCE(AVG(savings_pct), 0) as avg FROM requests WHERE tokens_saved > 0"
        ).fetchone()
        avg_pct = round(avg_row["avg"], 1)

        best_detail = ""
        if agg["best_pct"] > 0:
            best_row = conn.execute(
                "SELECT tokens_before, tokens_after, model FROM requests WHERE savings_pct = ? LIMIT 1",
                (agg["best_pct"],),
            ).fetchone()
            if best_row:
                best_detail = f"{best_row['tokens_before']} → {best_row['tokens_after']} tokens ({best_row['model']})"

    recent_list = [
        {
            "request_id": r["id"],
            "timestamp": r["timestamp"],
            "provider": "anthropic",
            "model": r["model"],
            "input_tokens_original": r["tokens_before"],
            "input_tokens_optimized": r["tokens_after"],
            "tokens_saved": r["tokens_saved"],
            "savings_percent": r["savings_pct"],
            "cost_saved_usd": r.get("cost_saved_usd", 0),
            "cost_per_mtok": r.get("cost_per_mtok", FALLBACK_COST_PER_MTOK),
            "tags": {"user-id": r["user_id"]},
            "total_latency_ms": 0,
        }
        for r in _recent
    ]

    return {
        "summary": {
            "api_requests": total,
            "compression": {
                "requests_compressed": compressed_count,
                "avg_compression_pct": avg_pct,
                "total_tokens_removed": total_saved,
                "best_compression_pct": agg["best_pct"],
                "best_detail": best_detail,
            },
            "uncompressed_requests": {
                "no_savings": total - compressed_count,
            },
            "cost": {
                "without_headroom_usd": round(cost_agg["cost_before"], 4),
                "with_headroom_usd": round(cost_agg["cost_after"], 4),
                "total_saved_usd": round(cost_agg["cost_saved"], 4),
            },
        },
        "recent_requests": recent_list,
    }


@app.get("/stats-history")
def get_stats_history():
    with _db() as conn:
        agg = conn.execute("""
            SELECT
                COUNT(*) as total,
                COALESCE(SUM(tokens_saved), 0) as total_saved,
                COALESCE(SUM(cost_saved_usd), 0) as total_cost_saved
            FROM requests
            WHERE tokens_saved > 0
        """).fetchone()

        total_all = conn.execute("SELECT COUNT(*) as c FROM requests").fetchone()["c"]

        history_rows = conn.execute(
            "SELECT * FROM requests WHERE tokens_saved > 0 ORDER BY timestamp DESC LIMIT 100"
        ).fetchall()

    return {
        "lifetime": {
            "requests": total_all,
            "tokens_saved": agg["total_saved"],
            "compression_savings_usd": round(agg["total_cost_saved"], 5),
        },
        "history": [
            {
                "timestamp": r["timestamp"],
                "model": r["model"],
                "total_tokens_saved": r["tokens_saved"],
                "compression_savings_usd": round(r["cost_saved_usd"], 5),
                "cost_per_mtok": r["cost_per_mtok"],
            }
            for r in history_rows
        ],
    }


@app.get("/pricing")
def get_pricing():
    _refresh_pricing()
    return {"models": _pricing, "fallback_cost_per_mtok": FALLBACK_COST_PER_MTOK}


@app.get("/sessions")
def get_sessions():
    with _user_cache_lock:
        now = time.time()
        sessions = []
        for uid, (cache, last_seen) in _user_caches.items():
            stats = cache.get_stats() if hasattr(cache, 'get_stats') else {}
            sessions.append({
                "user_id": uid,
                "last_active_seconds_ago": round(now - last_seen),
                "cache_entries": stats.get("entry_count", len(cache._cache) if hasattr(cache, '_cache') else 0),
                "cache_hits": cache._hits if hasattr(cache, '_hits') else 0,
                "cache_misses": cache._misses if hasattr(cache, '_misses') else 0,
                "tokens_saved_from_cache": cache._total_tokens_saved if hasattr(cache, '_total_tokens_saved') else 0,
            })
        return {
            "active_sessions": len(sessions),
            "max_sessions": MAX_USER_SESSIONS,
            "session_ttl_seconds": SESSION_TTL_SECONDS,
            "sessions": sessions,
        }


@app.get("/readyz")
def readyz():
    try:
        with _db() as conn:
            conn.execute("SELECT 1").fetchone()
        return {"status": "ready", "db": DB_PATH, "uptime_seconds": round(time.time() - _startup_time)}
    except Exception as e:
        logger.error("readyz check failed: %s", e)
        return Response(
            content='{"status":"not_ready","error":"database unavailable"}',
            status_code=503,
            media_type="application/json",
        )


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    lines = [
        "# HELP headroom_requests_total Total compression requests",
        "# TYPE headroom_requests_total counter",
        f"headroom_requests_total {_prom_requests}",
        "",
        "# HELP headroom_compressed_total Requests with savings > 0",
        "# TYPE headroom_compressed_total counter",
        f"headroom_compressed_total {_prom_compressed}",
        "",
        "# HELP headroom_tokens_before_total Total input tokens before compression",
        "# TYPE headroom_tokens_before_total counter",
        f"headroom_tokens_before_total {_prom_tokens_before}",
        "",
        "# HELP headroom_tokens_after_total Total input tokens after compression",
        "# TYPE headroom_tokens_after_total counter",
        f"headroom_tokens_after_total {_prom_tokens_after}",
        "",
        "# HELP headroom_tokens_saved_total Total tokens removed by compression",
        "# TYPE headroom_tokens_saved_total counter",
        f"headroom_tokens_saved_total {_prom_tokens_saved}",
        "",
        "# HELP headroom_errors_total Compression errors",
        "# TYPE headroom_errors_total counter",
        f"headroom_errors_total {_prom_errors}",
        "",
        "# HELP headroom_uptime_seconds Seconds since service start",
        "# TYPE headroom_uptime_seconds gauge",
        f"headroom_uptime_seconds {round(time.time() - _startup_time)}",
    ]
    return Response(content="\n".join(lines) + "\n", media_type="text/plain; charset=utf-8")


if __name__ == "__main__":
    _refresh_pricing()
    uvicorn.run(app, host="0.0.0.0", port=8787)
