FROM python:3.11-slim

RUN pip install --no-cache-dir "headroom-ai[proxy]==0.25.0" onnxruntime

# Writable dirs for OpenShift (runs as random UID, not root)
ENV HF_HOME=/opt/huggingface
ENV HOME=/opt/app
ENV HEADROOM_DATA_DIR=/opt/headroom-data
RUN mkdir -p /opt/huggingface /opt/app /opt/headroom-data

# Pre-download Kompress ONNX model + ModernBERT tokenizer (no runtime downloads)
RUN python -c "\
from huggingface_hub import snapshot_download; \
snapshot_download('chopratejas/kompress-v2-base'); \
snapshot_download('answerdotai/ModernBERT-base')"

RUN chmod -R 777 /opt/huggingface /opt/app /opt/headroom-data

EXPOSE 8787

ENTRYPOINT ["headroom", "proxy", "--port", "8787", "--host", "0.0.0.0"]
