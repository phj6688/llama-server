#!/bin/sh
# Verify the running llama-server end to end.
#
# POSIX sh on purpose: this runs from a throwaway container next to the
# server, and the obvious ones (alpine/curl) ship busybox without bash.
#
# The tool-call section is the regression gate for the crash class described
# in entrypoint.sh: with strict chat parsing, llama.cpp throws on a fenced
# tool call. The two request modes fail differently, so each is checked and
# each must prove itself:
#   plain    -> HTTP 500 "Failed to parse input at pos N"
#   streamed -> HTTP 200, then an error frame and no [DONE]
# The client loses the whole turn either way.
#
# The gate only means something when the trigger actually fires, and the
# resident model fences its call only some of the time. So each mode repeats,
# and each mode must produce at least one fenced reply of its own. A fence
# seen only while streaming says nothing about the plain HTTP 500 path, so a
# shared counter would let one mode vouch for the other.
#
# The second gate is the leak. A tools template with extraction off orders the
# model to answer with {"name": ..., "parameters": ...} and leaves that text in
# the content field, so the user reads a raw JSON blob where the answer
# belongs. No round may do that, in either mode. The fence gate below cannot
# catch it: a leak is a well-formed reply that simply says the wrong thing.
#
# Expected results by mode:
#   LLAMA_SKIP_CHAT_PARSING=true   -> PASS
#   LLAMA_SKIP_CHAT_PARSING=false  -> FAIL (this is how the gate is shown red)
#
# Exit: 0 PASS, 1 FAIL, 2 INCONCLUSIVE.
set -eu

URL="${LLAMA_URL:-http://llama-server:8000}"
MODEL="${LLAMA_MODEL_ALIAS:-medgemma-4b}"
ROUNDS="${VERIFY_ROUNDS:-8}"
failures=0

note() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

# Rebuild the assistant text from a response body. A streamed reply arrives one
# token per frame, so the tool-call shape never appears contiguously in the raw
# body and a plain grep over it reports clean. Cutting each frame down to its
# content value and joining them puts the text back together.
#
# The value ends at the first quote that is not escaped. Cutting on the frame's
# trailing punctuation instead would tie this to the key order llama.cpp emits
# today, and would truncate early on any reply that contains that punctuation.
assistant_text() {
  printf '%s\n' "$1" |
    sed -n 's/.*"content":"//p' |
    sed 's/\(\([^"\\]\|\\.\)*\)".*/\1/' |
    tr -d '\n'
}

# A working tool_calls reply carries the schema's own property names and never
# the literal "parameters", so this separates the leak from a real call.
is_leak() { assistant_text "$1" | grep -qF '\"parameters\"'; }

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

plain_fenced=0
stream_fenced=0
plain_tool_calls=0
stream_tool_calls=0
plain_leaked=0
stream_leaked=0

# Only an armed template can make the model call a tool or fence a reply. Ask
# the server for the template it loaded rather than reading an env var this
# shell may not share with the container under test.
props=$(curl -fsS -m 10 "$URL/props") || props=""
tools_armed=no
if printf '%s' "$props" | grep -qF 'You have access to functions'; then
  tools_armed=yes
fi
note
note "== tool calling: armed=$tools_armed =="

note
note "== tool call, plain ($ROUNDS rounds) =="
i=1
while [ "$i" -le "$ROUNDS" ]; do
  body=$(curl -s -m 180 -w '
%{http_code}' -X POST "$URL/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$(tool_body false)") || body='
000'
  code=$(printf '%s' "$body" | tail -n 1)
  payload=$(printf '%s' "$body" | sed '$d')
  marks=""
  if printf '%s' "$payload" | grep -q '```'; then
    plain_fenced=$((plain_fenced + 1)); marks="$marks fenced"
  fi
  if printf '%s' "$payload" | grep -q '"tool_calls"'; then
    plain_tool_calls=$((plain_tool_calls + 1)); marks="$marks tool_calls"
  fi
  if is_leak "$payload"; then
    plain_leaked=$((plain_leaked + 1)); marks="$marks leaked"
  fi
  if [ "$code" = "200" ]; then
    note "round $i: 200$marks"
  else
    fail "round $i returned $code -- strict chat parsing is on, or the server is down"
  fi
  i=$((i + 1))
done

note
note "== tool call, streamed ($ROUNDS rounds) =="
i=1
while [ "$i" -le "$ROUNDS" ]; do
  stream=$(curl -s -m 180 -X POST "$URL/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$(tool_body true)") || stream=""
  marks=""
  if printf '%s' "$stream" | grep -q '```'; then
    stream_fenced=$((stream_fenced + 1)); marks="$marks fenced"
  fi
  if printf '%s' "$stream" | grep -q '"tool_calls"'; then
    stream_tool_calls=$((stream_tool_calls + 1)); marks="$marks tool_calls"
  fi
  if is_leak "$stream"; then
    stream_leaked=$((stream_leaked + 1)); marks="$marks leaked"
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
  i=$((i + 1))
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

# A raw tool-call blob in content is a user-visible failure whether or not the
# turn survived, so it is fatal in both modes. Assert it before the fence gate,
# which can only exit INCONCLUSIVE and would hide this.
if [ "$plain_leaked" -ne 0 ] || [ "$stream_leaked" -ne 0 ]; then
  fail "raw tool-call blob in content (plain=$plain_leaked streamed=$stream_leaked of $ROUNDS rounds each)"
  note "verify.sh: FAIL ($failures)"
  exit 1
fi
note "ok: no round leaked a raw tool-call blob into content"

# The fenced reply is the trigger for the strict-parser crash, and only an
# armed template can produce one. With tool calling off there is nothing to
# fence, so demanding a fence would report a correct server as inconclusive
# forever.
if [ "$tools_armed" = yes ]; then
  # Each mode must have exercised its own crash path, or its green result is
  # only evidence that the model happened not to fence this time.
  if [ "$plain_fenced" -eq 0 ] || [ "$stream_fenced" -eq 0 ]; then
    note "INCONCLUSIVE: fenced replies plain=$plain_fenced streamed=$stream_fenced"
    note "in $ROUNDS rounds each. A mode with zero never exercised its crash"
    note "path, so its pass proves nothing. Re-run, or raise VERIFY_ROUNDS."
    exit 2
  fi
  note "ok: fenced replies plain=$plain_fenced streamed=$stream_fenced"
else
  note "ok: tool calling is off, so no round could fence or call a tool"
fi

# With parsing skipped, llama.cpp must not extract tool calls in either mode.
# Seeing any means the flag is not in effect and the strict parser is armed.
if [ "$plain_tool_calls" -ne 0 ] || [ "$stream_tool_calls" -ne 0 ]; then
  fail "tool_calls returned (plain=$plain_tool_calls streamed=$stream_tool_calls), so --skip-chat-parsing is not in effect"
else
  note "ok: no round returned tool_calls in either mode"
fi

note
if [ "$failures" -eq 0 ]; then
  note "verify.sh: PASS"
  exit 0
fi
note "verify.sh: FAIL ($failures)"
exit 1
