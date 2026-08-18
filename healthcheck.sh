#!/usr/bin/env bash
# Container healthcheck. Exercises inference, not just /health.
#
# /health answers 200 from the HTTP thread even when the model cannot produce
# a token, so the previous curl-/health check reported a healthy container
# through a total inference stall. Observed twice on 2026-08-17: chat requests
# hung until their client timeout while docker still showed "healthy", so
# nothing restarted and the local model stayed dead until a hand recreate.
#
# Docker does not restart a container for going unhealthy, only for exiting.
# So after LLAMA_HEALTH_MAX_FAILS consecutive stalls this kills PID 1 and lets
# the compose restart policy bring the server back. The counter resets on any
# success, so a single slow reply is never enough.
set -uo pipefail

PORT="${LLAMA_PORT:-8000}"
ALIAS="${LLAMA_MODEL_ALIAS:-default}"
TIMEOUT="${LLAMA_HEALTH_TIMEOUT:-25}"
MAX_FAILS="${LLAMA_HEALTH_MAX_FAILS:-4}"
STATE=/tmp/llama-health-fails

read_fails() { cat "$STATE" 2>/dev/null || echo 0; }

# One token is enough to prove the model can still decode.
if curl -fsS -m "$TIMEOUT" -o /dev/null \
     -X POST "http://127.0.0.1:${PORT}/v1/chat/completions" \
     -H 'Content-Type: application/json' \
     -d "{\"model\":\"${ALIAS}\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}]}"
then
  echo 0 > "$STATE" 2>/dev/null || true
  exit 0
fi

fails=$(( $(read_fails) + 1 ))
echo "$fails" > "$STATE" 2>/dev/null || true
echo "inference did not answer within ${TIMEOUT}s (${fails}/${MAX_FAILS})" >&2

if [ "$fails" -ge "$MAX_FAILS" ]; then
  echo "stalled ${fails} times in a row; exiting so the restart policy reloads the model" >&2
  kill -TERM 1 2>/dev/null || true
fi
exit 1
