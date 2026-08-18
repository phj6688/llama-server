#!/usr/bin/env bash
set -euo pipefail

MIN_FREE_GB="${LLAMA_MIN_FREE_GB:-4}"
MAX_SWAP_GB="${LLAMA_MAX_SWAP_GB:-10}"

read_mem() {
  free -g | awk -v field="$1" -v row="$2" 'NR==row { print $field }'
}

# Disk-backed swap only. This host runs a 16 GiB zram device, and zram pages
# live in RAM, so `free` counts them as swap while they are really compressed
# memory that the available-RAM reading below already accounts for. Counting
# zram made the guard latch: one pressure spike pushed the total past the
# ceiling, the total never came back down, and the server then refused every
# boot for as long as the pages stayed compressed. That turned a transient
# spike into a permanent outage of the resident model on 2026-08-17.
disk_swap_used_gb() {
  awk 'NR > 1 && $1 !~ /zram/ { used += $4 } END { printf "%d", used / 1048576 }' /proc/swaps
}

free_gb=$(read_mem 7 2)
swap_used_gb=$(disk_swap_used_gb)

: "${free_gb:=0}"
: "${swap_used_gb:=0}"

if (( free_gb < MIN_FREE_GB )); then
  echo "FATAL: available memory ${free_gb}G below LLAMA_MIN_FREE_GB=${MIN_FREE_GB}G" >&2
  exit 78
fi

if (( swap_used_gb >= MAX_SWAP_GB )); then
  echo "FATAL: disk swap usage ${swap_used_gb}G at or above LLAMA_MAX_SWAP_GB=${MAX_SWAP_GB}G" >&2
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

echo "boot guard ok: free=${free_gb}G disk_swap=${swap_used_gb}G; loading $MODEL_PATH ctx=$CTX kv=$KV_K/$KV_V"

# Tool calling needs both halves: the Jinja template that renders the function
# list into the prompt, and the parser that lifts the model's reply back into
# tool_calls. Arming one without the other has one guaranteed outcome. The
# template orders the model to answer with {"name": ..., "parameters": ...},
# nothing downstream converts that text, so it stays in the content field and
# the user reads a raw JSON blob where the answer belongs. Measured on the
# resident model: 6 of 6 tool-bearing requests, plain and streamed alike. That
# is what reached chat.peyman.io as a visible tool call.
#
# So parsing decides first, and the template is armed only when the parser is
# there to meet it. The two settings are one decision, not two independent
# ones, and the broken combination is now unreachable.
#
# llama.cpp derives a strict PEG parser from the Jinja template and throws
# when the model writes anything the grammar cannot place, such as the
# ```tool_code and ```json fences Gemma models like to wrap a call in. The
# throw becomes HTTP 500 "Failed to parse input at pos N" on a non-streamed
# request and an SSE error frame with no [DONE] on a streamed one, so the
# client loses the whole turn instead of one bad call. Upstream llama.cpp
# issue 20650 is open, its fix PR 20708 was rejected, and the workaround
# PR 20729 is unmerged, so the parser stays strict for now.
#
# --skip-chat-parsing keeps everything the model wrote in the content field,
# and turns off tool-call extraction with it. That is why the template stays
# down in this mode. It costs nothing here: the resident model is MedGemma-4B,
# and ADR 0002 in the medchat repo keeps tool calling on the cloud route until
# a local harness passes. A tools array from the client is then ignored by the
# built-in template, and the model answers in prose.
#
# Set LLAMA_SKIP_CHAT_PARSING=false to arm the template and get strict parsing
# back once a model that emits well-formed calls is resident. An unreadable
# value is fatal rather than a silent fall-through, because falling through
# re-arms a user-visible outage and the boot log would not say so.
EXTRA_ARGS=()
case "${SKIP_CHAT_PARSING,,}" in
  1|true|yes|on)
    EXTRA_ARGS+=(--skip-chat-parsing)
    echo "chat parsing: skipped, tool calling off"
    if [[ -n "$CHAT_TEMPLATE_FILE" ]]; then
      echo "tool template not loaded: $CHAT_TEMPLATE_FILE"
      echo "  reason: tool-call extraction is off, so the template could only" \
           "leak a raw tool call into the reply. Set" \
           "LLAMA_SKIP_CHAT_PARSING=false to arm it."
    fi
    ;;
  0|false|no|off)
    # Pass the negative form so this script owns the setting either way.
    # llama.cpp also reads LLAMA_ARG_SKIP_CHAT_PARSING from the environment,
    # and a command-line flag wins over it.
    EXTRA_ARGS+=(--no-skip-chat-parsing)
    echo "chat parsing: strict, a malformed tool call will fail the request"
    if [[ -n "$CHAT_TEMPLATE_FILE" && -f "$CHAT_TEMPLATE_FILE" ]]; then
      EXTRA_ARGS+=(--jinja --chat-template-file "$CHAT_TEMPLATE_FILE")
      echo "tool calling enabled via $CHAT_TEMPLATE_FILE"
    fi
    ;;
  *)
    echo "FATAL: LLAMA_SKIP_CHAT_PARSING must be true or false, got '${SKIP_CHAT_PARSING}'" >&2
    exit 78
    ;;
esac

exec /app/llama-server \
  -m "$MODEL_PATH" \
  --ctx-size "$CTX" \
  -ngl "$NGL" \
  --cache-type-k "$KV_K" --cache-type-v "$KV_V" \
  --alias "$ALIAS" \
  --host "$HOST" --port "$PORT" \
  --no-webui \
  "${EXTRA_ARGS[@]}"
