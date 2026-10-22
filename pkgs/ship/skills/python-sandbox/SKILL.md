---
name: python-sandbox
description: "Ship sandbox guide: what is installed (Arch Linux, conda Python 3.13 with data/document libraries, uv, bun in place of Node.js, rustup with stable Rust, Nix, CUDA + cuDNN, Playwright browsers, ffmpeg, ImageMagick) and how to add packages without root (uv/pip, conda, bun, cargo, nix profile). Also covers running Python and long jobs from the shell, /workspace file rules and what survives a sandbox restart. Read it before installing anything or when a tool seems missing."
---

# Ship Sandbox: Shell & Toolchains

Ship is the sandbox's code-execution container. You work in it through **shell commands** and **file operations**, rooted at `/workspace`; Python, JavaScript, Rust and everything else run from the shell.

## The Basics

- **OS**: Arch Linux (rolling).
- **User**: `shipyard` (uid 1000), `HOME=/workspace`. **There is no root and no sudo**, so `pacman`, `apt`, `sudo` and writes outside the user-owned directories fail. Install what you need with the user-level package managers below.
- **Workspace**: `/workspace` is the persistent volume (default limit about 1 GB). It survives sandbox restarts; everything else does not (see [What Persists](#what-persists)).
- **Package mirrors** may be preconfigured by the operator through environment variables (`PIP_INDEX_URL`, `UV_DEFAULT_INDEX`, `CONDA_CHANNEL_ALIAS`, `NPM_CONFIG_REGISTRY`, `RUSTUP_DIST_SERVER`, `NIX_CONFIG`, `$CARGO_HOME/config.toml`). They apply automatically: do not override them.

## What Is Installed

| Area | What | Where |
|------|------|-------|
| Python | Python 3.13 in conda `base` (Miniforge, conda-forge), the default `python`/`python3`; `pip`, `conda`, `mamba` | `/opt/conda` (owned by you) |
| Python packaging | `uv` | system |
| JavaScript / TypeScript | `bun`; `node` and `npx` are shims that run bun (`npx` = `bun x`, `node --version` reports the Node.js version bun emulates). No npm/pnpm/yarn | system; global packages in `/opt/bun` |
| Rust | rustup with the `stable` toolchain (rustc, cargo, rustfmt, clippy) | `/opt/rustup`, `/opt/cargo` (owned by you) |
| Nix | single-user Nix with flakes; registry `nixpkgs` is pinned and already in the store | `/nix` (owned by you) |
| GPU | CUDA toolkit with `nvcc`, cuDNN. A GPU is only visible in GPU profiles: check with `nvidia-smi` | `/opt/cuda` |
| Browsers | Python Playwright with Chromium (Firefox and WebKit are not installed) | `/ms-playwright` |
| C/C++ builds | gcc, make, cmake, ninja, meson, pkgconf, autotools | system |
| Media & documents | ffmpeg, ImageMagick (`magick`), poppler (`pdftotext`, `pdftoppm`, ...) | system |
| CLI | git, git-lfs, ssh, curl, wget, jq, ripgrep (`rg`), fd, sqlite3, tmux, htop, lsof, ip, rsync, tree, zip/unzip/7z, zstd, vim, nano, less | system |
| Fonts | Noto Sans CJK (SC also as a standalone font that matplotlib can use), WenQuanYi Micro Hei / Zen Hei, Noto Color Emoji, Noto Sans, DejaVu | system |

### Pre-installed Python Libraries (conda `base`)

| Category | Libraries |
|----------|-----------|
| Data science | numpy, pandas, scipy, scikit-learn, matplotlib, seaborn |
| Images | Pillow, opencv-python-headless, imageio |
| Documents | python-docx, python-pptx, openpyxl, xlrd, pypdf, pdfplumber, reportlab |
| Web / HTTP | requests, httpx, beautifulsoup4, lxml, jinja2 |
| Browser automation | playwright |
| Utilities | pydantic, tenacity, cachetools, tqdm, orjson, python-slugify, tomli, ipython |

## Installing More

Pick the package manager by what you need:

| Need | Command |
|------|---------|
| A Python library for `python` | `uv pip install --system <pkg>` (or `pip install <pkg>`) |
| A library with native parts, or a non-Python tool from conda-forge | `conda install -y <pkg>` |
| An isolated Python project, or another Python version | `uv init` / `uv venv` / `uv run`, `uv python install 3.12` |
| JavaScript / TypeScript dependencies | `bun install`, `bun add <pkg>`, `bun run <script>`, `bun file.ts` |
| A one-off JS CLI | `bunx <cli>` (same as `npx <cli>`) |
| A global JS CLI | `bun add -g <pkg>` (binaries land in `/opt/bun/bin`, already on `PATH`) |
| A Rust crate's binary | `cargo install <crate>` (lands in `/opt/cargo/bin`, on `PATH`) |
| Another Rust toolchain or target | `rustup toolchain install nightly`, `rustup target add <triple>` |
| Any other program or system tool | `nix profile install nixpkgs#<pkg>` (on `PATH` immediately) |
| A tool for one command only | `nix shell nixpkgs#<pkg> -c <command>` |

Notes:

- Prefer `uv pip install --system` for Python packages: it is the fastest. The first `conda install` in a fresh container downloads the conda-forge index, which can take a while.
- Find a Nix package name with `nix search nixpkgs <term>` (slow: it evaluates nixpkgs) or guess the common name. Unfree packages need `NIXPKGS_ALLOW_UNFREE=1 nix profile install --impure nixpkgs#<pkg>`. List / remove with `nix profile list` / `nix profile remove <name>`, and reclaim space with `nix-collect-garbage -d`.
- Use `nix profile`, not `nix-env`: the profile is managed by `nix profile`.
- To compile C/C++ against a library you do not have, get it from Nix together with its compiler and pkg-config, e.g. `nix shell nixpkgs#gcc nixpkgs#pkg-config nixpkgs#openssl -c make`, or use the conda-forge build of the library.
- PyTorch and most CUDA wheels bundle their own CUDA runtime; `/opt/cuda` is for `nvcc` and for software that looks for a system CUDA (`CUDA_HOME=/opt/cuda`).
- Package caches live in `/var/cache/shipyard`, outside the workspace quota.

## What Persists

| Location | Survives |
|----------|----------|
| `/workspace` (files, git repos, venvs you create there, `node_modules`, `target/`) | Everything, until the sandbox is deleted |
| conda `base` changes, `uv pip install --system`, `bun add -g`, `cargo install`, `rustup` changes, `nix profile install` | Only while the container lives. When an idle sandbox is reclaimed, the next command gets a fresh container from the image |

So for anything you will need again, keep the recipe in `/workspace` (a `requirements.txt`, `package.json`, `Cargo.toml`, or a `setup.sh` with the install commands) and re-run it when a tool is missing. Large dependency trees inside `/workspace` (a venv, `node_modules`, `target/`) persist but count against the workspace limit.

## Running Code

Commands run in `bash` as `shipyard`, in `/workspace` unless a working directory (relative to `/workspace`) is given. Shell operators (`&&`, `|`, `;`, `>`) work as usual. Each command starts fresh processes: nothing in memory carries over between commands, so keep intermediate results in files.

### Python

Write a script and run it, or pass short code through a heredoc:

```bash
python analyze.py

python - <<'PY'
import pandas as pd
df = pd.read_csv("data.csv")
df.describe().to_csv("summary.csv")
print(len(df))
PY
```

**Plots with CJK text** (fonts and the matplotlib cache are ready; save figures to files):

```python
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
plt.rcParams["font.sans-serif"] = ["Noto Sans CJK SC", "WenQuanYi Micro Hei", "DejaVu Sans"]
plt.rcParams["axes.unicode_minus"] = False
fig, ax = plt.subplots(figsize=(10, 6))
ax.plot([1, 2, 3], [3, 1, 2])
ax.set_title("趋势")
fig.savefig("chart.png", dpi=150, bbox_inches="tight")
```

### Playwright

Chromium is already downloaded into `/ms-playwright`; do not run `playwright install`. There is no display, so launch it headless (the default).

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1280, "height": 720})
    page.goto("https://example.com", wait_until="networkidle")
    page.screenshot(path="/workspace/example.png", full_page=True)
    browser.close()
```

Save screenshots, downloads and traces under `/workspace`. In a `browser-python` sandbox the Gull container shares `/workspace` with Ship.

### Other Languages and Tools

```bash
# Project scaffolding
mkdir -p src tests && git init

# JavaScript / TypeScript with bun
bun init -y && bun add express && bun run index.ts

# Rust
cargo new hello && cd hello && cargo run --release

# A tool that is not installed
nix profile install nixpkgs#hyperfine && hyperfine 'sleep 0.1'

# Media
ffmpeg -i input.mp4 -vf scale=640:-2 output.mp4
```

### Long-running Jobs

Start servers, builds, training runs and other long jobs in the background with their output in a log file, then check the log in later commands:

```bash
nohup python train.py > train.log 2>&1 &
tail -n 20 train.log
```

## File Operations

Direct file read/write/list/delete without the shell.

- Paths are **relative to `/workspace`** (or absolute under `/workspace`); parent directories are created on write.
- Anything resolving outside `/workspace` is rejected with HTTP 403: `../etc/passwd`, `/etc/passwd` and `subdir/../../etc/passwd` are all blocked; `src/main.py`, `./output/data.csv` and `/workspace/src/main.py` are fine.

## Environment Variables

Profile-level variables from Bay's `config.yaml` (`profiles[].env`) are injected into the container, so every command sees them (`$NAME` in the shell, `os.environ` in Python); `/workspace/.bay_env.sh` holds a copy that every shell command sources. Changes to a profile only reach newly created sandboxes. For your own variables across shell commands, add `export` lines to `/workspace/.bashrc`.

## Constraints Summary

| Constraint | Value |
|------------|-------|
| User | `shipyard`, no root, no sudo, no system package manager |
| Workspace root | `/workspace`, persistent; everything else resets when the container is recreated |
| Path security | File operation paths must resolve within `/workspace` |
| Write file limit | 5 MB (UTF-8 encoded) |
| Upload/download limit | 50 MB per file |
| Python | 3.13 in conda `base` (`/opt/conda`), the default `python` |
| Other runtimes | bun (`node`/`npx` shims), Rust stable via rustup, Nix with pinned `nixpkgs` |
| GPU | CUDA + cuDNN in `/opt/cuda`; devices only in GPU profiles |
