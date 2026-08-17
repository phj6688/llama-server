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
CHAT_TEMPLATE_FILE="${LLAMA_CHAT_TEMPLATE_FILE:-}"
SKIP_CHAT_PARSING="${LLAMA_SKIP_CHAT_PARSING:-true}"

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "FATAL: model file not found at LLAMA_MODEL_PATH=$MODEL_PATH" >&2
  exit 78
fi

echo "boot guard ok: free=${free_gb}G swap_used=${swap_used_gb}G; loading $MODEL_PATH ctx=$CTX kv=$KV_K/$KV_V"

EXTRA_ARGS=()
if [[ -n "$CHAT_TEMPLATE_FILE" && -f "$CHAT_TEMPLATE_FILE" ]]; then
  EXTRA_ARGS+=(--jinja --chat-template-file "$CHAT_TEMPLATE_FILE")
  echo "tool calling enabled via $CHAT_TEMPLATE_FILE"
fi

# llama.cpp derives a strict PEG parser from the Jinja template and throws
# when the model writes anything the grammar cannot place, such as the
# ```tool_code and ```json fences Gemma models like to wrap a call in. The
# throw becomes HTTP 500 "Failed to parse input at pos N" on a non-streamed
# request and an SSE error frame with no [DONE] on a streamed one, so the
# client loses the whole turn instead of one bad call. Upstream llama.cpp
# issue 20650 is open, its fix PR 20708 was rejected, and the workaround
# PR 20729 is unmerged, so the parser stays strict for now.
#
# --skip-chat-parsing keeps everything the model wrote in the content field.
# A malformed call degrades to visible text rather than a lost turn. It also
# turns off tool-call extraction, which costs nothing here: the resident
# model is MedGemma-4B, and ADR 0002 in the medchat repo keeps tool calling
# on the cloud route until a local harness passes.
#
# Set LLAMA_SKIP_CHAT_PARSING=false to get strict parsing back once a model
# that emits well-formed calls is resident.
if [[ "$SKIP_CHAT_PARSING" == "true" ]]; then
  EXTRA_ARGS+=(--skip-chat-parsing)
  echo "chat parsing skipped: malformed tool calls degrade to content, not HTTP 500"
fi

exec /app/llama-server \
  -m "$MODEL_PATH" \
  --ctx-size "$CTX" \
  -ngl "$NGL" \
  --cache-type-k "$KV_K" --cache-type-v "$KV_V" \
  --alias "$ALIAS" \
  --host "$HOST" --port "$PORT" \
  --no-webui \
  "${EXTRA_ARGS[@]}"
