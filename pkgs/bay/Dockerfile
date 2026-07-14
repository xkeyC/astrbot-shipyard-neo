# Bay Dockerfile
# Multi-stage build for smaller image

# ── Proxy support ──────────────────────────────────────
# Pass via --build-arg HTTP_PROXY=... HTTPS_PROXY=... NO_PROXY=...
# NOTE: before first FROM only ARG is allowed (no ENV).
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

FROM python:3.13-slim AS builder

# ── Proxy (must re-declare ARG in each FROM) ───────────
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy
ENV HTTP_PROXY=${HTTP_PROXY} HTTPS_PROXY=${HTTPS_PROXY} NO_PROXY=${NO_PROXY}
ENV http_proxy=${http_proxy} https_proxy=${https_proxy} no_proxy=${no_proxy}
# apt doesn't honour *_proxy env vars; configure it explicitly
# Prefer uppercase, fallback to lowercase (both are set by ENV above if passed).
RUN _http_proxy="${HTTP_PROXY:-${http_proxy:-}}"; \
    _https_proxy="${HTTPS_PROXY:-${https_proxy:-}}"; \
    if [ -n "${_http_proxy}" ]; then \
      echo "Acquire::http::Proxy \"${_http_proxy}\";"   > /etc/apt/apt.conf.d/99proxy ; \
      echo "Acquire::https::Proxy \"${_https_proxy}\";" >> /etc/apt/apt.conf.d/99proxy ; \
    fi

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app

# Copy dependency files (README.md required by hatchling build backend)
COPY pyproject.toml uv.lock README.md ./

# Install dependencies
RUN uv sync --frozen --no-dev --no-editable

# Copy application code
COPY app/ ./app/

# Production stage
FROM python:3.13-slim

# ── Proxy: ARG only (no ENV!) — export in RUN, cleaned up after use ──
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

WORKDIR /app

# Install curl for container health checks through the configured mirror/proxy.
RUN _proxy="${HTTP_PROXY:-${http_proxy:-}}"; \
    _sproxy="${HTTPS_PROXY:-${https_proxy:-}}"; \
    if [ -n "${_proxy}" ]; then \
      echo "Acquire::http::Proxy \"${_proxy}\";" > /etc/apt/apt.conf.d/99proxy; \
      echo "Acquire::https::Proxy \"${_sproxy}\";" >> /etc/apt/apt.conf.d/99proxy; \
    fi && \
    export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    sed -i \
        -e 's|http://deb.debian.org/debian|http://mirror.sjtu.edu.cn/debian|g' \
        -e 's|http://deb.debian.org/debian-security|http://mirror.sjtu.edu.cn/debian-security|g' \
        /etc/apt/sources.list.d/debian.sources && \
    apt-get update && apt-get install -y --no-install-recommends curl && \
    rm -f /etc/apt/apt.conf.d/99proxy && \
    rm -rf /var/lib/apt/lists/*

# Copy virtual environment from builder
COPY --from=builder /app/.venv /app/.venv

# Copy application code
COPY --from=builder /app/app ./app/

# Copy pyproject.toml for runtime version detection
COPY --from=builder /app/pyproject.toml ./

# Set environment
ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONPATH="/app"
ENV BAY_SERVER__HOST="0.0.0.0"
ENV BAY_SERVER__PORT="8114"

# Expose port
EXPOSE 8114

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8114/health || exit 1

# Run
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8114"]
