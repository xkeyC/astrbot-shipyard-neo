# ── Proxy support ──────────────────────────────────────
# Pass via --build-arg HTTP_PROXY=... HTTPS_PROXY=... NO_PROXY=...
# NOTE: before first FROM only ARG is allowed (no ENV).
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy
# Override when Docker Hub is unreachable, e.g. docker.m.daocloud.io/library/archlinux:base-devel
ARG BASE_IMAGE=archlinux:base-devel

# ===== 最终镜像 =====
FROM ${BASE_IMAGE}

# ── Proxy: ARG only, export in RUN, no ENV — clean runtime ──
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ARG http_proxy
ARG https_proxy
ARG no_proxy

# 构建期镜像源，全部可选：不传就用官方源。运行期的镜像源由容器环境变量
# SHIPYARD_*_MIRROR 决定（见 entrypoint.sh），与这里无关。
#   PACMAN_MIRROR      Arch 源根地址（…/archlinux），也写进镜像里的 mirrorlist
#   PYPI_MIRROR        PyPI simple index
#   CONDA_MIRROR       conda channel alias（conda-forge → <mirror>/conda-forge）
#   MINIFORGE_MIRROR   Miniforge 安装脚本所在目录（GitHub latest release 的镜像）
#   RUSTUP_MIRROR      rustup 分发服务器
#   PLAYWRIGHT_MIRROR  Playwright 浏览器下载地址
#   PYTHON_MIRROR      uv 下载 Python 构建（python-build-standalone）的地址
#   NIXPKGS_MIRROR     nixpkgs 源码 tarball（如 channel 镜像的 nixexprs.tar.xz）
ARG PACMAN_MIRROR
ARG PYPI_MIRROR
ARG CONDA_MIRROR
ARG MINIFORGE_MIRROR
ARG RUSTUP_MIRROR
ARG PLAYWRIGHT_MIRROR
ARG PYTHON_MIRROR
ARG NIXPKGS_MIRROR

# Agent 以 shipyard（uid 1000）身份运行，没有 root/sudo。用户态工具链都装在
# shipyard 拥有的目录里，agent 可以自行增删：
#   /opt/conda   Miniforge（conda base = Python 3.13，IPython 内核在这里跑）
#   /opt/rustup, /opt/cargo   rustup 工具链与 cargo install 的程序
#   /opt/bun     bun 全局包
#   /nix         单用户 Nix，nix profile 在 /nix/var/nix/profiles/per-user/shipyard/profile
# Ship 服务本身在 root 拥有的 /opt/ship/venv 里，agent 改动 conda 不会影响它。
ENV LANG=C.UTF-8 \
    CONDA_DIR=/opt/conda \
    RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    BUN_INSTALL=/opt/bun \
    NIX_PATH=nixpkgs=flake:nixpkgs \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    XDG_CACHE_HOME=/var/cache/shipyard \
    CUDA_HOME=/opt/cuda \
    CUDA_PATH=/opt/cuda \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,video \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PATH=/nix/var/nix/profiles/per-user/shipyard/profile/bin:/opt/cargo/bin:/opt/bun/bin:/opt/conda/bin:/usr/local/sbin:/usr/local/bin:/usr/bin:/opt/cuda/bin

WORKDIR /app

# 系统包：构建工具、常用命令行工具、媒体/文档工具、字体，以及 Playwright 浏览器的运行库。
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    if [ -n "${PACMAN_MIRROR}" ]; then \
      echo "Server = ${PACMAN_MIRROR}/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist; \
    fi && \
    pacman -Syu --noconfirm --needed \
      git git-lfs openssh curl wget gnupg ca-certificates \
      cmake ninja meson pkgconf \
      uv bun rustup nix \
      catatonit tmux htop procps-ng lsof iproute2 less nano vim which file tree rsync \
      jq ripgrep fd sqlite \
      zip unzip p7zip tar gzip bzip2 xz zstd \
      ffmpeg imagemagick poppler \
      libpng libjpeg-turbo glib2 mesa libxml2 libxslt \
      fontconfig ttf-dejavu noto-fonts noto-fonts-cjk noto-fonts-emoji wqy-microhei wqy-zenhei \
      nss nspr alsa-lib at-spi2-core libcups libdrm libxkbcommon dbus cairo pango \
      libx11 libxcb libxext libxfixes libxcomposite libxdamage libxrandr \
    && rm -rf /var/cache/pacman/pkg/* \
    && echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen && locale-gen

# CUDA toolkit + cuDNN（/opt/cuda）。驱动库（libcuda、nvidia-smi）由 NVIDIA Container
# Toolkit 在运行时从宿主机注入，所以去掉会与宿主驱动版本冲突的 opencl-nvidia。
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    pacman -S --noconfirm --needed cuda cudnn \
    && pacman -Rdd --noconfirm opencl-nvidia \
    && rm -rf /var/cache/pacman/pkg/*

# 运行用户和它拥有的用户态目录。shipyard 不在 sudoers 里。
RUN useradd -u 1000 -U -d /workspace -M -s /bin/bash shipyard \
    && install -d -o shipyard -g shipyard -m 755 \
       /workspace /opt/conda /opt/rustup /opt/cargo /opt/bun /ms-playwright \
       /var/cache/shipyard /nix \
    && chown -R shipyard:shipyard /nix \
    && mkdir -p /etc/nix \
    && printf '%s\n' \
       'experimental-features = nix-command flakes' \
       'build-users-group =' \
       'sandbox = false' \
       'max-jobs = auto' \
       'flake-registry = /etc/nix/registry.json' \
       > /etc/nix/nix.conf

USER shipyard

# Miniforge，conda base 固定为 Python 3.13。
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    if [ -n "${CONDA_MIRROR}" ]; then export CONDA_CHANNEL_ALIAS="${CONDA_MIRROR}"; fi && \
    curl -fsSL --retry 5 --retry-all-errors "${MINIFORGE_MIRROR:-https://github.com/conda-forge/miniforge/releases/latest/download}/Miniforge3-Linux-$(uname -m).sh" -o /tmp/miniforge.sh \
    && bash /tmp/miniforge.sh -b -u -p "$CONDA_DIR" \
    && rm /tmp/miniforge.sh \
    && conda install -n base -y python=3.13 pip \
    && conda clean -afy

# 预装的 Python 库（含 ipykernel、playwright）装进 conda base。
COPY --chown=shipyard:shipyard requirements-sandbox.txt /tmp/requirements-sandbox.txt
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    if [ -n "${PYPI_MIRROR}" ]; then export UV_DEFAULT_INDEX="${PYPI_MIRROR}"; fi && \
    uv pip install --no-cache --python "$CONDA_DIR/bin/python" --system -r /tmp/requirements-sandbox.txt \
    && rm /tmp/requirements-sandbox.txt \
    && { find "$CONDA_DIR" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true; }

# Playwright 只装 Chromium（含 headless shell）。Arch 不在 Playwright 的支持列表里，它会下载 Ubuntu 构建；
# 运行库已在上面用 pacman 装好，所以不用 --with-deps。
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    if [ -n "${PLAYWRIGHT_MIRROR}" ]; then export PLAYWRIGHT_DOWNLOAD_HOST="${PLAYWRIGHT_MIRROR}"; fi && \
    python -m playwright install chromium

# rustup：stable 工具链（minimal + rustfmt + clippy）。
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    if [ -n "${RUSTUP_MIRROR}" ]; then export RUSTUP_DIST_SERVER="${RUSTUP_MIRROR}"; fi && \
    rustup toolchain install stable --profile minimal -c rustfmt -c clippy \
    && rustup default stable \
    && rustc --version && cargo --version

# 单用户 Nix：把 nixpkgs 源码预取进 /nix/store（`flake metadata` 只放进下载缓存，
# 不进 store），用 GC root 保住，再删掉已经用不上的下载缓存。
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    mkdir -p /nix/var/nix/profiles/per-user/shipyard /nix/var/nix/gcroots \
    && nix flake prefetch --json "${NIXPKGS_MIRROR:-github:NixOS/nixpkgs/nixpkgs-unstable}" > /nix/var/nix/nixpkgs-pin.json \
    && ln -sfn "$(jq -r .storePath /nix/var/nix/nixpkgs-pin.json)" /nix/var/nix/gcroots/shipyard-nixpkgs \
    && rm -rf "$XDG_CACHE_HOME/nix"

USER root

# flake registry：`nixpkgs` 指向构建时预取的那份源码。
RUN jq '{version: 2, flakes: [{from: {type: "indirect", id: "nixpkgs"}, to: ({type: "path", path: .storePath} + (.locked | {narHash, lastModified}))}]}' \
       /nix/var/nix/nixpkgs-pin.json > /etc/nix/registry.json \
    && cat /etc/nix/registry.json

# bun 代替 Node.js：node / npx 是转给 bun 的小脚本，`#!/usr/bin/env node` 的 CLI 也能跑。
# `node --version` 报 bun 模拟的 Node 版本（vX.Y.Z），检查 Node 版本的工具才认。
RUN printf '#!/bin/sh\ncase "$1" in -v|--version) exec bun -e "console.log(process.version)" ;; esac\nexec bun "$@"\n' > /usr/local/bin/node \
    && printf '#!/bin/sh\nexec bun x "$@"\n' > /usr/local/bin/npx \
    && chmod 755 /usr/local/bin/node /usr/local/bin/npx

# Ship 服务的独立 venv（uv 管理的 Python 3.13，root 拥有）。IPython 内核仍用 conda base。
COPY requirements.txt /tmp/requirements.txt
RUN export HTTP_PROXY="${HTTP_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}" \
           http_proxy="${http_proxy}" https_proxy="${https_proxy}" \
           NO_PROXY="${NO_PROXY}" no_proxy="${no_proxy}" && \
    if [ -n "${PYPI_MIRROR}" ]; then export UV_DEFAULT_INDEX="${PYPI_MIRROR}"; fi && \
    if [ -n "${PYTHON_MIRROR}" ]; then export UV_PYTHON_INSTALL_MIRROR="${PYTHON_MIRROR}"; fi && \
    UV_PYTHON_INSTALL_DIR=/opt/ship/python uv venv --no-cache --managed-python --python 3.13 /opt/ship/venv \
    && uv pip install --no-cache --python /opt/ship/venv/bin/python -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt \
    && mkdir -p /opt/ship/venv/share/jupyter/kernels/python3 \
    && printf '%s\n' \
       '{' \
       '  "argv": ["/opt/conda/bin/python", "-m", "ipykernel_launcher", "-f", "{connection_file}"],' \
       '  "display_name": "Python 3 (conda base)",' \
       '  "language": "python"' \
       '}' > /opt/ship/venv/share/jupyter/kernels/python3/kernel.json

# Arch 的 Noto CJK 只有 .ttc，matplotlib 只读其中第一个字形集（JP），用不了
# "Noto Sans CJK SC"。把简体中文的常规体和粗体抽成单独的 .otf。
RUN /opt/conda/bin/python - <<'EOF' && fc-cache -f
from pathlib import Path
from fontTools.ttLib import TTCollection

out = Path("/usr/local/share/fonts/noto-cjk-sc")
out.mkdir(parents=True, exist_ok=True)
for weight in ("Regular", "Bold"):
    collection = TTCollection(f"/usr/share/fonts/noto-cjk/NotoSansCJK-{weight}.ttc")
    face = next(f for f in collection.fonts if f["name"].getDebugName(1) == "Noto Sans CJK SC")
    face.save(out / f"NotoSansCJKsc-{weight}.otf")
EOF

# 预热 matplotlib 字体缓存（构建时完成，运行时跳过），缓存在 $XDG_CACHE_HOME/matplotlib。
USER shipyard
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

USER root

# 构建过程中以 shipyard 身份写进 /workspace（HOME）的东西不进镜像：workspace 是挂载卷。
RUN find /workspace -mindepth 1 -delete

# 复制项目文件（依赖 .dockerignore 排除不需要的文件）
COPY . .

# 设置入口脚本权限
RUN chmod +x /app/entrypoint.sh

# 暴露端口
EXPOSE 8123

# 入口脚本以 root 修正 workspace 权限、写入镜像源配置，然后降权为 shipyard
# （无 capability、no_new_privs）启动 Ship，之后容器里不再有 root 进程。
ENTRYPOINT ["/app/entrypoint.sh"]

CMD ["/opt/ship/venv/bin/python", "run.py"]
