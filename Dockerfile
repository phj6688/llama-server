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
COPY healthcheck.sh /app/healthcheck.sh
COPY templates/ /app/templates/
RUN chmod +x /app/entrypoint.sh /app/healthcheck.sh

USER ubuntu
WORKDIR /app

EXPOSE 8000

# Timeout must exceed the script's own curl deadline (LLAMA_HEALTH_TIMEOUT,
# 25s by default) or docker kills the probe before it can decide.
HEALTHCHECK --interval=30s --timeout=30s --start-period=180s --retries=3 \
  CMD /app/healthcheck.sh

ENTRYPOINT ["dumb-init", "--"]
CMD ["/app/entrypoint.sh"]
