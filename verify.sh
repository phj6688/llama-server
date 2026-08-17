#!/usr/bin/env bash
# Verify the running llama-server end to end.
#
# The tool-call section is the regression gate for the crash class described
# in entrypoint.sh: with strict chat parsing, llama.cpp throws on a fenced
# tool call, which surfaces as HTTP 500 "Failed to parse input at pos N" on a
# plain request and as an error frame with no [DONE] on a streamed one. The
# client loses the whole turn either way.
#
# The gate only means something when the trigger actually fires, and the
# resident model fences its call only some of the time. So each shape repeats,
# and a run where no round produced a fence exits INCONCLUSIVE (2) rather than
# claiming a pass it did not earn.
#
# Expected results by mode:
#   LLAMA_SKIP_CHAT_PARSING=true   -> PASS
#   LLAMA_SKIP_CHAT_PARSING=false  -> FAIL (this is how the gate is shown red)
#
# Exit: 0 PASS, 1 FAIL, 2 INCONCLUSIVE.
set -euo pipefail

URL="${LLAMA_URL:-http://llama-server:8000}"
MODEL="${LLAMA_MODEL_ALIAS:-medgemma-4b}"
ROUNDS="${VERIFY_ROUNDS:-8}"
failures=0

note() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

tool_body() {
  # $1 is the literal true/false for "stream". Built here rather than patched
  # afterwards, so reflowing this JSON cannot silently corrupt the request.
  cat <<JSON
{"model":"$MODEL","max_tokens":256,"stream":$1,
 "messages":[{"role":"user","content":"Use pubmed_search right now to search for 'otitis media adults' and list the top 3 results."}],
 "tools":[{"type":"function","function":{"name":"pubmed_search",
   "description":"Search PubMed for biomedical literature.",
   "parameters":{"type":"object","properties":{
     "query":{"type":"string"},"top_k":{"type":"integer"}},"required":["query"]}}}]}
JSON
}

note "== health =="
if curl -fsS -m 10 "$URL/health" >/dev/null; then
  note "ok: $URL/health"
else
  fail "$URL/health did not answer 200"
fi

note
note "== models =="
models_body=$(curl -fsS -m 10 "$URL/v1/models") || models_body=""
if printf '%s' "$models_body" | grep -q "$MODEL"; then
  note "ok: $MODEL advertised"
else
  fail "$MODEL missing from $URL/v1/models"
fi

note
note "== plain completion =="
plain=$(curl -s -m 120 -o /dev/null -w '%{http_code}' -X POST "$URL/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"say ok\"}]}") || plain="000"
if [ "$plain" = "200" ]; then
  note "ok: plain completion 200"
else
  fail "plain completion returned $plain"
fi

fenced=0
tool_calls_seen=0

note
note "== tool call, plain ($ROUNDS rounds) =="
for i in $(seq 1 "$ROUNDS"); do
  body=$(curl -s -m 180 -w '\n%{http_code}' -X POST "$URL/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$(tool_body false)") || body=$'\n000'
  code=${body##*$'\n'}
  payload=${body%$'\n'*}
  marks=""
  if printf '%s' "$payload" | grep -q '```'; then
    fenced=$((fenced + 1)); marks="$marks fenced"
  fi
  if printf '%s' "$payload" | grep -q '"tool_calls"'; then
    tool_calls_seen=$((tool_calls_seen + 1)); marks="$marks tool_calls"
  fi
  if [ "$code" = "200" ]; then
    note "round $i: 200$marks"
  else
    fail "round $i returned $code -- strict chat parsing is on, or the server is down"
  fi
done

note
note "== tool call, streamed ($ROUNDS rounds) =="
for i in $(seq 1 "$ROUNDS"); do
  stream=$(curl -s -m 180 -X POST "$URL/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$(tool_body true)") || stream=""
  marks=""
  if printf '%s' "$stream" | grep -q '```'; then
    fenced=$((fenced + 1)); marks="$marks fenced"
  fi
  if printf '%s' "$stream" | grep -q '\[DONE\]'; then
    note "round $i: terminated$marks"
  else
    fail "stream round $i did not terminate with [DONE]"
  fi
  # Any error frame counts, not only the one wording llama.cpp uses today.
  if printf '%s' "$stream" | grep -q 'data: *{"error"'; then
    fail "stream round $i carried an error frame"
  fi
done

note
note "== assertions =="
# Real failures outrank an inconclusive verdict. A server that is simply down
# produces no fenced reply either, and reporting that as "re-run with more
# rounds" would send the reader looking in the wrong place.
if [ "$failures" -ne 0 ]; then
  note "verify.sh: FAIL ($failures)"
  exit 1
fi

# A green run proves nothing unless the model actually produced the output
# shape that breaks the strict parser at least once.
if [ "$fenced" -eq 0 ]; then
  note "INCONCLUSIVE: no round produced a fenced reply in $((ROUNDS * 2)) tries,"
  note "so the crash path was never exercised. Re-run, or raise VERIFY_ROUNDS."
  exit 2
fi
note "ok: $fenced of $((ROUNDS * 2)) rounds produced a fenced reply"

# With parsing skipped, llama.cpp must not extract tool calls at all. Seeing
# any means the flag is not in effect and the strict parser is still armed.
if [ "$tool_calls_seen" -ne 0 ]; then
  fail "$tool_calls_seen rounds returned tool_calls, so --skip-chat-parsing is not in effect"
else
  note "ok: no round returned tool_calls, --skip-chat-parsing is in effect"
fi

note
if [ "$failures" -eq 0 ]; then
  note "verify.sh: PASS"
  exit 0
fi
note "verify.sh: FAIL ($failures)"
exit 1
