FROM vllm/vllm-openai:v0.25.1

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir "huggingface_hub[hf_transfer]>=0.26.0"
