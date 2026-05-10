ARG LLAMA_CPP_TAG=server-rocm-b9070
FROM ghcr.io/ggml-org/llama.cpp:${LLAMA_CPP_TAG} AS runtime

USER root

RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
        dumb-init \
        curl \
        ca-certificates \
        procps \
 && rm -rf /var/lib/apt/lists/*

RUN getent group render >/dev/null || groupadd -g 110 render \
 && getent group video  >/dev/null || groupadd -g 44  video \
 && usermod -aG render,video ubuntu

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

USER ubuntu
WORKDIR /app

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8000/health >/dev/null || exit 1

ENTRYPOINT ["dumb-init", "--"]
CMD ["/app/entrypoint.sh"]
