#!/usr/bin/env bash
set -euo pipefail

MIN_FREE_GB="${LLAMA_MIN_FREE_GB:-4}"
MAX_SWAP_GB="${LLAMA_MAX_SWAP_GB:-10}"

read_mem() {
  free -g | awk -v field="$1" -v row="$2" 'NR==row { print $field }'
}

free_gb=$(read_mem 7 2)
swap_used_gb=$(read_mem 3 3)

: "${free_gb:=0}"
: "${swap_used_gb:=0}"

if (( free_gb < MIN_FREE_GB )); then
  echo "FATAL: available memory ${free_gb}G below LLAMA_MIN_FREE_GB=${MIN_FREE_GB}G" >&2
  exit 78
fi

if (( swap_used_gb >= MAX_SWAP_GB )); then
  echo "FATAL: swap usage ${swap_used_gb}G at or above LLAMA_MAX_SWAP_GB=${MAX_SWAP_GB}G" >&2
  exit 78
fi

MODEL_PATH="${LLAMA_MODEL_PATH:?LLAMA_MODEL_PATH required}"
CTX="${LLAMA_CONTEXT:-8192}"
NGL="${LLAMA_GPU_LAYERS:-999}"
KV_K="${LLAMA_KV_TYPE_K:-q8_0}"
KV_V="${LLAMA_KV_TYPE_V:-q8_0}"
ALIAS="${LLAMA_MODEL_ALIAS:-default}"
HOST="${LLAMA_HOST:-0.0.0.0}"
PORT="${LLAMA_PORT:-8000}"

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "FATAL: model file not found at LLAMA_MODEL_PATH=$MODEL_PATH" >&2
  exit 78
fi

echo "boot guard ok: free=${free_gb}G swap_used=${swap_used_gb}G; loading $MODEL_PATH ctx=$CTX kv=$KV_K/$KV_V"

exec /app/llama-server \
  -m "$MODEL_PATH" \
  --ctx-size "$CTX" \
  -ngl "$NGL" \
  --cache-type-k "$KV_K" --cache-type-v "$KV_V" \
  --alias "$ALIAS" \
  --host "$HOST" --port "$PORT" \
  --no-webui
