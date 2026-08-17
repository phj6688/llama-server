# llama-server

Shared homelab inference server. Wraps llama.cpp's ROCm server image with a boot guard and env-driven configuration. Exposes an OpenAI-compatible API at port 8000 on `platform-net`.

## Quick start

```bash
cp .env.example .env
# edit .env: set LLAMA_MODEL_PATH and LLAMA_MODELS_DIR
docker compose up -d --build
```

## API

OpenAI-compatible at `http://llama-server:8000/v1` (from any container on `platform-net`):

```bash
curl http://llama-server:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"medgemma-4b","messages":[{"role":"user","content":"hello"}]}'
```

## Configuration

All config via environment variables in `.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `LLAMA_MODEL_PATH` | (required) | Path to GGUF inside container |
| `LLAMA_MODEL_ALIAS` | `default` | Model name in API responses |
| `LLAMA_MODELS_DIR` | `./models` | Host path mounted at `/models` |
| `LLAMA_CONTEXT` | `8192` | Context window size |
| `LLAMA_GPU_LAYERS` | `999` | Layers offloaded to GPU |
| `LLAMA_KV_TYPE_K` | `q8_0` | KV cache key type |
| `LLAMA_KV_TYPE_V` | `q8_0` | KV cache value type |
| `LLAMA_MEM_LIMIT` | `18g` | Container memory ceiling |
| `LLAMA_MIN_FREE_GB` | `4` | Boot guard: min free RAM |
| `LLAMA_MAX_SWAP_GB` | `10` | Boot guard: max swap used |
| `HSA_OVERRIDE_GFX_VERSION` | `11.0.0` | ROCm ISA override |
| `LLAMA_CPP_TAG` | `server-rocm-b9070` | Upstream image tag |
| `LLAMA_CHAT_TEMPLATE_FILE` | (empty) | Jinja template; enables `--jinja` |
| `LLAMA_SKIP_CHAT_PARSING` | `true` | Keep model output in `content` (see below) |
| `LLAMA_HEALTH_TIMEOUT` | `25` | Seconds the healthcheck waits for one token |
| `LLAMA_HEALTH_MAX_FAILS` | `4` | Consecutive stalls before the server restarts |

## Chat parsing

With a Jinja template loaded, llama.cpp builds a strict PEG parser and throws
when the model writes anything the grammar cannot place. Gemma models wrap a
tool call in a ```` ```tool_code ```` or ```` ```json ```` fence often enough
that this is routine, and the throw costs the client the whole turn:

- non-streamed: `HTTP 500 {"error":{"message":"Failed to parse input at pos N: ```"}}`
- streamed: `HTTP 200`, then an error frame and no `[DONE]`

Upstream llama.cpp issue 20650 is open, its fix PR 20708 was rejected, and the
workaround PR 20729 is unmerged, so the parser stays strict.

`LLAMA_SKIP_CHAT_PARSING=true` (the default) passes `--skip-chat-parsing`, so
everything the model wrote stays in `content`. A malformed call degrades to
visible text instead of a lost turn. Tool-call extraction is off while this is
on. Set it to `false` when a model that emits well-formed calls is resident.

`./verify.sh` covers both failure shapes, repeats each one, and exits
INCONCLUSIVE (2) when no round produced a fenced reply, because a run that
never triggered the crash path proves nothing. Run it from a container that
has `bash`, `curl` and `grep` on `platform-net`:

```bash
cd ~/deploy/llama-server
docker run --rm --network platform-net -v "$PWD:/w" -w /w alpine/curl:latest sh verify.sh
```

Set `LLAMA_SKIP_CHAT_PARSING=false` and redeploy to see the gate go red.

## Healthcheck

The probe asks the model for one token rather than calling `/health`. The HTTP
thread answers `/health` even when the model cannot decode, so the old probe
reported a healthy container straight through a total inference stall; that
happened twice on 2026-08-17 and nothing restarted, because docker restarts a
container for exiting, never for going unhealthy.

After `LLAMA_HEALTH_MAX_FAILS` consecutive stalls the probe signals PID 1, so
the compose restart policy reloads the model. Any success resets the counter,
so one slow reply is never enough. The container is marked unhealthy at 3
retries, one round before it restarts itself.

## Boot guard

The entrypoint refuses to start if:
- Available RAM < `LLAMA_MIN_FREE_GB`
- Disk-backed swap used >= `LLAMA_MAX_SWAP_GB`

This protects sibling containers from OOM pressure during model load.

The swap reading counts only disk-backed devices from `/proc/swaps`. zram is
excluded on purpose: its pages are compressed RAM, so the available-RAM check
already covers them. Counting zram made the guard latch. On 2026-08-17 one
26B model load pushed the combined figure past the ceiling, the figure never
fell back, and the guard then refused every boot of the resident 4B model
until the pages decompressed. A transient spike became a lasting outage.

## Consumers

Any service on `platform-net` can reach `http://llama-server:8000/v1`. Current consumers:
- `medchat` (LibreChat at chat.peyman.io, endpoint "MedGemma (local)")

## Model swap

```bash
docker compose stop
# edit .env: LLAMA_MODEL_PATH, LLAMA_MODEL_ALIAS, LLAMA_CONTEXT
docker compose up -d
```

Only one model runs at a time.
