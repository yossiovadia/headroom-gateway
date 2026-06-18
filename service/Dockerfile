FROM nvidia/cuda:12.9.0-runtime-ubuntu24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 python3-pip python3-venv && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf /usr/bin/python3 /usr/bin/python

RUN pip install --no-cache-dir --break-system-packages \
    "headroom-ai[ml]" fastapi uvicorn gunicorn psycopg2-binary onnxruntime-gpu

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
RUN NVIDIA_LIB_DIR=$(python3 -c "import nvidia.cu13; import os; print(os.path.join(os.path.dirname(nvidia.cu13.__file__), 'lib'))" 2>/dev/null || echo "") && \
    echo "NVIDIA_LIB_DIR=$NVIDIA_LIB_DIR" && \
    if [ -n "$NVIDIA_LIB_DIR" ]; then echo "$NVIDIA_LIB_DIR" > /nvidia_lib_path; fi
ENV LD_LIBRARY_PATH=/usr/local/lib/python3.12/dist-packages/nvidia/cu13/lib:/usr/local/lib/python3.12/dist-packages/nvidia/cudnn/lib
ENV HEADROOM_WORKERS=4
CMD ["sh", "-c", "gunicorn headroom_service:app --bind 0.0.0.0:8787 --workers ${HEADROOM_WORKERS} --worker-class uvicorn.workers.UvicornWorker --preload --timeout 120"]
