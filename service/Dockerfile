FROM python:3.12-slim

ARG RUNTIME=cpu

RUN pip install --no-cache-dir "headroom-ai[ml]" fastapi uvicorn psycopg2-binary && \
    if [ "$RUNTIME" = "gpu" ]; then \
      pip install --no-cache-dir onnxruntime-gpu; \
    else \
      pip install --no-cache-dir onnxruntime; \
    fi

ENV HF_HOME=/opt/huggingface
ENV HOME=/opt/app
ENV HEADROOM_STATS_DB=/data/headroom-stats.db

ARG HF_TOKEN=""
RUN mkdir -p /opt/huggingface /opt/app /data && \
    HF_TOKEN=${HF_TOKEN} python -c "\
import os; \
from huggingface_hub import snapshot_download; \
token = os.environ.get('HF_TOKEN') or None; \
snapshot_download('chopratejas/kompress-v2-base', token=token); \
snapshot_download('answerdotai/ModernBERT-base', token=token)" && \
    chmod -R 777 /opt/huggingface /opt/app /data

COPY headroom_service.py /app/headroom_service.py
WORKDIR /app
EXPOSE 8787
CMD ["python", "headroom_service.py"]
