from headroom import compress
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from datetime import datetime
from collections import deque
import threading
import uvicorn

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

stats_lock = threading.Lock()
total_requests = 0
total_compressed = 0
total_tokens_before = 0
total_tokens_after = 0
total_tokens_saved = 0
recent_requests = deque(maxlen=50)

class CompressRequest(BaseModel):
    messages: list
    model: str = "default"

@app.post("/v1/compress")
def compress_messages(req: CompressRequest, request: Request):
    global total_requests, total_compressed, total_tokens_before, total_tokens_after, total_tokens_saved

    user_id = request.headers.get("x-maas-username", request.headers.get("x-headroom-user-id", "anonymous"))

    result = compress(messages=req.messages, model=req.model)

    with stats_lock:
        total_requests += 1
        total_tokens_before += result.tokens_before
        total_tokens_after += result.tokens_after
        saved = result.tokens_saved
        total_tokens_saved += saved
        if saved > 0:
            total_compressed += 1

        recent_requests.append({
            "request_id": "hr_%d_%06d" % (int(datetime.utcnow().timestamp()), total_requests),
            "timestamp": datetime.utcnow().isoformat(),
            "provider": "anthropic",
            "model": req.model,
            "input_tokens_original": result.tokens_before,
            "input_tokens_optimized": result.tokens_after,
            "tokens_saved": saved,
            "savings_percent": round((saved / result.tokens_before * 100) if result.tokens_before > 0 else 0, 1),
            "tags": {"user-id": user_id},
            "total_latency_ms": 0,
        })

    return {
        "messages": result.messages,
        "tokens_before": result.tokens_before,
        "tokens_after": result.tokens_after,
        "tokens_saved": saved,
        "compression_ratio": result.compression_ratio
    }

@app.get("/stats")
def get_stats():
    with stats_lock:
        avg_pct = round((total_tokens_saved / total_tokens_before * 100) if total_tokens_before > 0 else 0, 1)
        best = max((r["savings_percent"] for r in recent_requests), default=0)
        best_detail = ""
        for r in recent_requests:
            if r["savings_percent"] == best and best > 0:
                best_detail = "%d → %d tokens" % (r["input_tokens_original"], r["input_tokens_optimized"])
                break

        return {
            "summary": {
                "api_requests": total_requests,
                "compression": {
                    "requests_compressed": total_compressed,
                    "avg_compression_pct": avg_pct,
                    "total_tokens_removed": total_tokens_saved,
                    "best_compression_pct": best,
                    "best_detail": best_detail,
                },
                "uncompressed_requests": {"no_savings": sum(1 for r in recent_requests if r["tokens_saved"] == 0)},
                "cost": {
                    "without_headroom_usd": round(total_tokens_before * 15 / 1000000, 4),
                    "with_headroom_usd": round(total_tokens_after * 15 / 1000000, 4),
                    "total_saved_usd": round(total_tokens_saved * 15 / 1000000, 4),
                },
            },
            "recent_requests": list(recent_requests),
        }

@app.get("/stats-history")
def get_stats_history():
    with stats_lock:
        return {
            "lifetime": {
                "requests": total_requests,
                "tokens_saved": total_tokens_saved,
                "compression_savings_usd": round(total_tokens_saved * 15 / 1000000, 5),
                "total_input_tokens": total_tokens_before,
                "total_input_cost_usd": round(total_tokens_before * 15 / 1000000, 4),
            },
            "history": [r for r in recent_requests if r["tokens_saved"] > 0],
            "series": {"hourly": [], "daily": [], "weekly": [], "monthly": []},
        }

@app.get("/health")
def health():
    return {"status": "ok"}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8787)
