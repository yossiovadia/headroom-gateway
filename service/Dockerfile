FROM python:3.12-slim

RUN pip install --no-cache-dir "headroom-ai[ml]" fastapi uvicorn onnxruntime

ENV HF_HOME=/opt/huggingface
ENV HOME=/opt/app
RUN mkdir -p /opt/huggingface /opt/app && \
    python -c "\
from huggingface_hub import snapshot_download; \
snapshot_download('chopratejas/kompress-v2-base'); \
snapshot_download('answerdotai/ModernBERT-base')" && \
    chmod -R 777 /opt/huggingface /opt/app

COPY headroom_service.py /app/headroom_service.py
WORKDIR /app
EXPOSE 8787
CMD ["python", "headroom_service.py"]
