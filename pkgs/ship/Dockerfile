# ── Proxy support ──────────────────────────────────────
# Pass via --build-arg HTTP_PROXY=... HTTPS_PROXY=... NO_PROXY=...
# NOTE: before first FROM only ARG is allowed (no ENV).
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# ===== 最终镜像 =====
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    CONDA_DIR=/opt/conda \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    PATH=/opt/conda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

# ── Proxy: ARG only, export in RUN, no ENV — clean runtime ──
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

WORKDIR /app

# 使用国内 apt 镜像源，并保留到运行时供 agent 安装依赖。
RUN sed -i \
    -e 's|http://archive.ubuntu.com/ubuntu|http://mirror.sjtu.edu.cn/ubuntu|g' \
    -e 's|http://security.ubuntu.com/ubuntu|http://mirror.sjtu.edu.cn/ubuntu|g' \
    /etc/apt/sources.list.d/ubuntu.sources

# 安装运行时、构建依赖和常用命令行工具；构建代理不会保留到镜像环境。
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    _p="${HTTP_PROXY:-${http_proxy:-}}"; \
    _sp="${HTTPS_PROXY:-${https_proxy:-}}"; \
    if [ -n "${_p}" ]; then \
      echo "Acquire::http::Proxy \"${_p}\";" > /etc/apt/apt.conf.d/99proxy; \
      echo "Acquire::https::Proxy \"${_sp}\";" >> /etc/apt/apt.conf.d/99proxy; \
    fi && \
    apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    bash \
    sudo \
    curl \
    wget \
    gnupg \
    git \
    build-essential \
    pkg-config \
    libpng16-16 \
    libjpeg-turbo8 \
    libglib2.0-0 \
    libgl1 \
    libxml2 \
    libxslt1.1 \
    fontconfig \
    fonts-noto-cjk \
    fonts-noto-cjk-extra \
    fonts-noto-color-emoji \
    fonts-symbola \
    fonts-wqy-microhei \
    fonts-wqy-zenhei \
    zip \
    unzip \
    tar \
    gzip \
    bzip2 \
    xz-utils \
    ffmpeg \
    imagemagick \
    poppler-utils \
    jq \
    ripgrep \
    vim-tiny \
    nano \
    less \
    procps \
    htop \
    && rm -f /etc/apt/apt.conf.d/99proxy \
    && rm -rf /var/lib/apt/lists/*

# 创建运行用户和 workspace。
RUN if ! getent group shipyard >/dev/null; then \
        if getent group 1000 >/dev/null; then groupadd shipyard; else groupadd -g 1000 shipyard; fi; \
    fi \
    && if ! id -u shipyard >/dev/null 2>&1; then \
        if getent passwd 1000 >/dev/null; then useradd -g shipyard -d /workspace -s /bin/bash shipyard; else useradd -u 1000 -g shipyard -d /workspace -s /bin/bash shipyard; fi; \
    fi \
    && mkdir -p /workspace \
    && chown shipyard:shipyard /workspace \
    && chmod 755 /workspace \
    && echo "root ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers \
    && echo "Defaults:root !requiretty" >> /etc/sudoers \
    && echo "shipyard ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# 配置默认 shell 环境。
RUN echo '# Basic shell configuration for shipyard user' > /workspace/.bashrc \
    && echo "export PS1='\\u@shipyard:\\w\\$ '" >> /workspace/.bashrc \
    && echo 'export PATH=/opt/conda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' >> /workspace/.bashrc \
    && echo 'export PLAYWRIGHT_BROWSERS_PATH=/ms-playwright' >> /workspace/.bashrc \
    && echo 'export HOME=/workspace' >> /workspace/.bashrc \
    && echo 'cd /workspace' >> /workspace/.bashrc \
    && cp /workspace/.bashrc /workspace/.bash_profile \
    && chown shipyard:shipyard /workspace/.bashrc \
    && chown shipyard:shipyard /workspace/.bash_profile \
    && chmod 644 /workspace/.bashrc /workspace/.bash_profile

# 下载并安装 Miniforge/conda。
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    arch="$(uname -m)" \
    && case "$arch" in \
        x86_64) miniforge_arch="x86_64" ;; \
        aarch64) miniforge_arch="aarch64" ;; \
        *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${miniforge_arch}.sh" -o /tmp/miniforge.sh \
    && bash /tmp/miniforge.sh -b -p "$CONDA_DIR" \
    && rm /tmp/miniforge.sh

# 把 conda base 环境固定为 Python 3.13。
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    conda install -n base -y python=3.13 pip \
    && conda clean -afy

# 使用 uv 安装 Python 依赖到 conda base 环境。
COPY --from=ghcr.io/astral-sh/uv:0.5 /uv /usr/local/bin/uv
COPY requirements.txt .
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    uv pip install --no-cache --python "$CONDA_DIR/bin/python" --system -r requirements.txt \
    && { find "$CONDA_DIR" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true; } \
    && { find "$CONDA_DIR" -name '*.pyc' -delete 2>/dev/null || true; } \
    && { find "$CONDA_DIR" -name '*.pyo' -delete 2>/dev/null || true; }

# 预装 Playwright 浏览器，供 Ship 内 Python 自动化脚本直接使用。
RUN mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"

RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    python -m playwright install --with-deps chromium firefox webkit

RUN chown -R shipyard:shipyard "$PLAYWRIGHT_BROWSERS_PATH" \
    && chmod -R 755 "$PLAYWRIGHT_BROWSERS_PATH" \
    && rm -rf /var/lib/apt/lists/*

# 安装 Node.js (LTS) - 代理通过 export，用完即弃。
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    _p="${HTTP_PROXY:-${http_proxy:-}}"; \
    _sp="${HTTPS_PROXY:-${https_proxy:-}}"; \
    if [ -n "${_p}" ]; then \
      echo "Acquire::http::Proxy \"${_p}\";"   > /etc/apt/apt.conf.d/99proxy ; \
      echo "Acquire::https::Proxy \"${_sp}\";" >> /etc/apt/apt.conf.d/99proxy ; \
    fi && \
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/apt/apt.conf.d/99proxy \
    && npm install -g pnpm vercel --no-audit --no-fund \
    && npm cache clean --force \
    && rm -rf /root/.npm

# 复制项目文件（依赖 .dockerignore 排除不需要的文件）
COPY . .

# 设置入口脚本权限
RUN chmod +x /app/entrypoint.sh

# 预热 matplotlib 字体缓存（构建时完成，运行时跳过）
# 这可以节省每次容器启动时约 2-3 秒的字体缓存重建时间
RUN python <<'EOF'
import matplotlib.pyplot as plt
import matplotlib.font_manager as fm

# 构建字体缓存
fm._load_fontmanager(try_read_cache=False)

# 配置中文字体
font_candidates = [
    'Noto Sans CJK SC',
    'Noto Sans CJK JP',
    'Noto Sans CJK TC',
    'WenQuanYi Zen Hei',
    'WenQuanYi Micro Hei',
]

# 检查 Symbola 字体是否可用
symbola_available = any('Symbola' in f.name for f in fm.fontManager.ttflist)
if symbola_available:
    font_candidates.append('Symbola')

noto_color_emoji_available = any('Noto Color Emoji' in f.name for f in fm.fontManager.ttflist)
if noto_color_emoji_available:
    font_candidates.append('Noto Color Emoji')

font_candidates.append('DejaVu Sans')

plt.rcParams['font.sans-serif'] = font_candidates
plt.rcParams['axes.unicode_minus'] = False

# 创建一个图来触发完整的初始化
fig, ax = plt.subplots()
ax.set_title('Font cache warmup')
plt.close(fig)

print('Matplotlib font cache warmed up successfully')
EOF

# 暴露端口
EXPOSE 8123

# 入口脚本：修复 workspace 权限后启动应用
ENTRYPOINT ["/app/entrypoint.sh"]

# 启动命令（以 root 运行 FastAPI，内部通过 sudo 切换到 shipyard 执行命令）
CMD ["python", "run.py"]
