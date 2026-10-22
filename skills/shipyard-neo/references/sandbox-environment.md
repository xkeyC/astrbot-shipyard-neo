# Sandbox Environment Details

A sandbox's container topology depends on the **profile** used to create it. Some profiles use a single container, others use multiple containers sharing a Cargo Volume.

## Discovering Profiles at Runtime

Call `list_profiles` to discover available profiles and their container topology:

```
list_profiles()
```

**Example output** (with container detail):

```
Available Profiles (5)

- python-default: capabilities=[filesystem, shell, python], idle_timeout=43200s
    └ primary (ship): [filesystem, python, shell]
- browser-python — Browser automation with Python backend: capabilities=[browser, filesystem, python, shell], idle_timeout=43200s
    └ ship (ship): [filesystem, python, shell]
    └ browser (gull): [browser]
```

Key observations:
- `python-default` has **one container** (`primary` of type `ship`) — only Python/Shell/Filesystem operations available
- `browser-python` has **two containers** (`ship` + `browser` of type `gull`) — both code execution and browser automation available
- If `browser` capability is not in the profile's capabilities list, `execute_browser` and `execute_browser_batch` will fail

## Example: Single-Container Profile (`python-default`)

```
┌──────────────────────────────────────┐
│           Sandbox                    │
│  ┌────────────────────────────────┐  │
│  │       Ship Container           │  │
│  │  Arch Linux, user shipyard     │  │
│  │  conda Python 3.13 + uv        │  │
│  │  bun, Rust (rustup), Nix, CUDA │  │
│  │  ffmpeg, git, curl, etc.       │  │
│  └──────────┬─────────────────────┘  │
│             │                        │
│  ┌──────────┴─────────────────────┐  │
│  │       Cargo Volume             │  │
│  │       /workspace               │  │
│  └────────────────────────────────┘  │
└──────────────────────────────────────┘
```

**Available MCP tools**: `execute_python`, `execute_shell`, `read_file`, `write_file`, `list_files`, `delete_file`

**Not available**: `execute_browser`, `execute_browser_batch` (no Gull container)

## Example: Multi-Container Profile (`browser-python`)

```
┌──────────────────────────────────────────────────────────┐
│                    Sandbox                                │
│  ┌──────────────────┐      ┌──────────────────┐          │
│  │  Ship Container   │      │  Gull Container   │         │
│  │  (code execution) │      │ (browser automat.)│         │
│  │                   │      │                   │         │
│  │  Python, Shell,   │      │  agent-browser    │         │
│  │  Filesystem       │      │  Chromium headless│         │
│  └────────┬──────────┘      └────────┬──────────┘         │
│           │                          │                    │
│           └──────────┬───────────────┘                    │
│                      │                                    │
│           ┌──────────┴──────────┐                         │
│           │   Cargo Volume      │                         │
│           │   /workspace        │                         │
│           └─────────────────────┘                         │
└──────────────────────────────────────────────────────────┘
```

**Available MCP tools**: All tools — code execution + browser automation + file operations

**Critical rules for multi-container profiles**:
- **Never run `agent-browser` in `execute_shell`** — Ship does not have agent-browser
- **Never add `agent-browser` prefix to `execute_browser` cmd** — Gull auto-injects it
- Both containers share `/workspace` via the Cargo Volume

## Ship Container Environment

Ship containers run Arch Linux. Code runs as the unprivileged user `shipyard` (uid 1000, `HOME=/workspace`); there is **no root, no sudo and no system package manager** inside the sandbox. The toolchains below are owned by `shipyard`, so their package managers work without privileges.

### Language Runtimes and Package Managers

| Runtime | Location | Install more with |
|---------|----------|-------------------|
| **Python 3.13** (conda `base`, IPython kernel; variables persist across `execute_python` calls) | `/opt/conda` | `uv pip install --system <pkg>`, `pip install <pkg>`, `conda install -y <pkg>` (conda-forge) |
| **uv** | system | `uv venv`, `uv run`, `uv python install 3.12` for other projects / Python versions |
| **bun** (replaces Node.js; `node` and `npx` are shims to bun, no npm/pnpm) | `/opt/bun` | `bun add <pkg>`, `bun add -g <pkg>`, `bunx <cli>` |
| **Rust** stable via rustup (rustc, cargo, rustfmt, clippy) | `/opt/rustup`, `/opt/cargo` | `cargo install <crate>`, `rustup toolchain install <name>`, `rustup target add <triple>` |
| **Nix** (single-user, flakes on, `nixpkgs` pinned in the registry and already in the store) | `/nix` | `nix profile install nixpkgs#<pkg>`, `nix shell nixpkgs#<pkg> -c <cmd>` |
| **CUDA** toolkit (`nvcc`) + cuDNN | `/opt/cuda` | — (GPU devices only in GPU profiles; check `nvidia-smi`) |
| **Playwright** (Python) with Chromium only | `/ms-playwright` | — (do not run `playwright install`) |

### Persistence

Only `/workspace` (the Cargo Volume) persists. Everything installed elsewhere stays only while the container lives; when an idle sandbox is reclaimed, the next call starts a fresh container from the image. Keep install recipes (`requirements.txt`, `package.json`, `Cargo.toml`, a setup script) in `/workspace`.

### Package Mirrors

Operators can preset mirrors for every package manager through profile env (`SHIPYARD_PYPI_MIRROR`, `SHIPYARD_CONDA_MIRROR`, `SHIPYARD_NPM_MIRROR`, `SHIPYARD_RUSTUP_MIRROR`, `SHIPYARD_CRATES_MIRROR`, `SHIPYARD_NIX_MIRROR`, `SHIPYARD_PACMAN_MIRROR`, `SHIPYARD_PYTHON_MIRROR`); Ship turns them into each tool's own setting at startup. Inside the sandbox they simply apply.

### Pre-installed Python Libraries

| Category | Libraries |
|----------|-----------|
| Data Science | numpy, pandas, scipy, scikit-learn, matplotlib, seaborn |
| Image Processing | Pillow, opencv-python-headless, imageio |
| Document Processing | python-docx, python-pptx, openpyxl, xlrd, pypdf, pdfplumber, reportlab |
| Web/XML | beautifulsoup4, lxml, jinja2, requests, httpx |
| Browser Automation | playwright |
| Utilities | pydantic, tomli, tenacity, cachetools, tqdm, orjson, python-slugify |

### System Tools

Build: `gcc`, `make`, `cmake`, `ninja`, `meson`, `pkgconf`, autotools. CLI: `git`, `git-lfs`, `ssh`, `curl`, `wget`, `jq`, `rg`, `fd`, `sqlite3`, `tmux`, `htop`, `lsof`, `ip`, `rsync`, `tree`, `zip`/`unzip`/`7z`, `zstd`, `vim`, `nano`, `less`. Media/documents: `ffmpeg`, ImageMagick (`magick`), poppler (`pdftotext`, `pdftoppm`, ...).

### Fonts

CJK fonts (Noto Sans CJK, WenQuanYi Micro Hei / Zen Hei), emoji (Noto Color Emoji), Noto and DejaVu Sans are pre-installed. Matplotlib font cache is pre-warmed.

### Playwright Artifacts

Playwright runs in the Ship container. Inside `execute_python` use the async API (the kernel already runs an event loop). Save screenshots, downloads, traces, and generated files under `/workspace` so they are available to file tools and, in multi-container profiles, to Gull.

## Gull Container Environment

Gull containers provide browser automation via the `agent-browser` CLI.

### Auto-injected Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `--session` | Sandbox ID | Browser instance isolation |
| `--profile` | `/workspace/.browser/profile/` | Persistent browser state |

### Browser State Persistence

Cookies, localStorage, IndexedDB, service workers, and cache are persisted to `/workspace/.browser/profile/` on the Cargo Volume. State survives container restarts and is cleaned up on sandbox deletion.

## Cargo Volume

| Property | Details |
|----------|---------|
| Mount path | `/workspace` |
| Shared between | All containers in the same sandbox |
| Default size limit | 1024 MB |
| Persistence | Survives container restarts; deleted with sandbox |

### Cross-Container File Access

```
# Gull writes screenshot → Ship reads it
execute_browser(cmd="screenshot /workspace/page.png")
execute_python(code="from PIL import Image; img = Image.open('page.png')")

# Ship writes file → Gull opens it
execute_python(code="open('report.html', 'w').write(html)")
execute_browser(cmd="open file:///workspace/report.html")
```
