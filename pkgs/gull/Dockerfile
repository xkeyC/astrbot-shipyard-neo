# Gull runtime container
# - Python + FastAPI wrapper
# - agent-browser CLI (Node.js)
# - Playwright Chromium + Linux deps

# ── Proxy support ──────────────────────────────────────
# Pass via --build-arg HTTP_PROXY=... HTTPS_PROXY=... NO_PROXY=...
# NOTE: before first FROM only ARG is allowed (no ENV).
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

FROM ghcr.io/astral-sh/uv:0.5.30-python3.11-bookworm-slim

# ── Proxy: ARG only, export in RUN, no ENV — clean runtime ──
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

WORKDIR /app

# --- System deps + Node.js ---
# Proxy via export, apt.conf written+cleaned inline; retain the local mirror.
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    _p="${HTTP_PROXY:-${http_proxy:-}}"; \
    _sp="${HTTPS_PROXY:-${https_proxy:-}}"; \
    if [ -n "${_p}" ]; then \
      echo "Acquire::http::Proxy \"${_p}\";"   > /etc/apt/apt.conf.d/99proxy ; \
      echo "Acquire::https::Proxy \"${_sp}\";" >> /etc/apt/apt.conf.d/99proxy ; \
    fi && \
    sed -i \
      -e 's|http://deb.debian.org/debian|http://mirror.sjtu.edu.cn/debian|g' \
      -e 's|http://deb.debian.org/debian-security|http://mirror.sjtu.edu.cn/debian-security|g' \
      /etc/apt/sources.list.d/debian.sources && \
    apt-get update \
    && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/apt/apt.conf.d/99proxy

# --- agent-browser + Playwright Chromium ---
# 1. Install agent-browser globally
# 2. Install Playwright as a local project dependency so `npx playwright` works
# 3. Install Chromium browser + system deps
# We keep PLAYWRIGHT_BROWSERS_PATH at default (/root/.cache/ms-playwright) so
# agent-browser can find the Chromium binary at runtime.
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    npm install -g agent-browser \
    && npm init -y \
    && npm install playwright \
    && npx playwright install --with-deps chromium \
    && rm -rf /tmp/* /var/lib/apt/lists/*

# --- Python deps (uv) ---
# Keep README.md in build context because pyproject.toml declares it as the project readme.
COPY pyproject.toml uv.lock README.md ./
COPY app ./app
COPY skills ./skills

RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    uv sync --frozen --no-dev

# Entrypoint: injects built-in skills into /workspace/skills/ before starting
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Runtime defaults
ENV BAY_WORKSPACE_PATH=/workspace

EXPOSE 8115

ENTRYPOINT ["/app/entrypoint.sh"]

# Run directly from the venv — uv sync already completed during build.
# Using uv run at runtime would trigger a re-sync that needs network access.
# --loop asyncio: Force standard asyncio event loop instead of uvloop.
# uvloop (installed via uvicorn[standard]) has compatibility issues with
# Node.js child processes (agent-browser): pipe management differs from
# standard asyncio, causing process.communicate() to hang waiting for EOF,
# which manifests as command timeouts.
ENV PATH="/app/.venv/bin:$PATH"
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8115", "--loop", "asyncio"]
