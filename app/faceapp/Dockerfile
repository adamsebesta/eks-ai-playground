# CUDA 12.x runtime base — VERIFY this matches your GPU node's actual driver
# once make gpu-up is running: `kubectl exec -it <pod-on-gpu-node> -- nvidia-smi`
# shows the driver's max supported CUDA version. onnxruntime-gpu 1.19.x targets
# CUDA 12.x; mismatch here is the #1 cause of "works locally, fails on the
# cluster" for GPU workloads.
# --platform pinned explicitly: this only ever needs to run on the x86_64
# g5.xlarge node, and onnxruntime-gpu/NVIDIA's CUDA images have no ARM build
# at all — without this, building on an Apple Silicon Mac defaults to arm64
# and pip can't find a matching wheel for anything GPU-related.
FROM --platform=linux/amd64 nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

# build-essential + python3-dev: insightface ships a Cython C++ extension
# (mesh_core_cython) that compiles from source at install time — no
# precompiled wheel exists for it, unlike the pure-Python/onnxruntime deps.
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-dev build-essential libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip3 install --no-cache-dir --upgrade pip setuptools wheel \
    && pip3 install --no-cache-dir -r requirements.txt

COPY main.py .

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
