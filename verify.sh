#!/usr/bin/env bash
# Verify the running llama-server end to end.
#
# The tool-call check is the regression gate for the crash class described in
# entrypoint.sh: llama.cpp's strict template parser throws on a fenced tool
# call, which surfaces as HTTP 500 "Failed to parse input at pos N" and costs
# the client the whole turn. The resident model wraps its calls in a fence
# often enough that a single request proves nothing, so the check repeats.
#
# Exits non-zero on any failure.
set -euo pipefail

URL="${LLAMA_URL:-http://llama-server:8000}"
MODEL="${LLAMA_MODEL_ALIAS:-medgemma-4b}"
ROUNDS="${VERIFY_ROUNDS:-8}"
failures=0

note() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

note "== health =="
if curl -fsS -m 10 "$URL/health" >/dev/null; then
  note "ok: $URL/health"
else
  fail "$URL/health did not answer 200"
fi

note
note "== models =="
if curl -fsS -m 10 "$URL/v1/models" | grep -q "$MODEL"; then
  note "ok: $MODEL advertised"
else
  fail "$MODEL missing from $URL/v1/models"
fi

note
note "== plain completion =="
plain=$(curl -s -m 120 -o /dev/null -w '%{http_code}' -X POST "$URL/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"say ok\"}]}")
if [ "$plain" = "200" ]; then
  note "ok: plain completion 200"
else
  fail "plain completion returned $plain"
fi

note
note "== tool-call parse regression ($ROUNDS rounds) =="
tool_body=$(cat <<JSON
{"model":"$MODEL","max_tokens":256,
 "messages":[{"role":"user","content":"Use pubmed_search right now to search for 'otitis media adults' and list the top 3 results."}],
 "tools":[{"type":"function","function":{"name":"pubmed_search",
   "description":"Search PubMed for biomedical literature.",
   "parameters":{"type":"object","properties":{
     "query":{"type":"string"},"top_k":{"type":"integer"}},"required":["query"]}}}]}
JSON
)

for i in $(seq 1 "$ROUNDS"); do
  code=$(curl -s -m 180 -o /dev/null -w '%{http_code}' -X POST "$URL/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$tool_body")
  if [ "$code" = "200" ]; then
    note "round $i: 200"
  else
    fail "round $i returned $code (strict chat parsing is back on, or the server is down)"
  fi
done

note
note "== streamed tool call must finish with [DONE] =="
# The streamed form of the same crash keeps HTTP 200 and instead ends with an
# error frame and no [DONE], so the status code alone would miss it.
stream=$(curl -s -m 180 -X POST "$URL/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "$(printf '%s' "$tool_body" | sed 's/^{/{"stream":true,/')")
if printf '%s' "$stream" | grep -q '\[DONE\]'; then
  note "ok: stream terminated with [DONE]"
else
  fail "stream did not terminate with [DONE]"
fi
if printf '%s' "$stream" | grep -q 'Failed to parse input'; then
  fail "stream carried a parse error frame"
else
  note "ok: no parse error frame in stream"
fi

note
if [ "$failures" -eq 0 ]; then
  note "verify.sh: PASS"
  exit 0
fi
note "verify.sh: FAIL ($failures)"
exit 1
