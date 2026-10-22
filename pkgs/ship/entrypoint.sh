#!/bin/bash
# Docker entrypoint script for Ship container
# This script runs as root to fix workspace permissions, apply package mirrors
# and inject built-in skills into the shared workspace, then drops to the
# shipyard user (no capabilities, no_new_privs) to start the application.
# Nothing in the container runs as root after that.

set -e

EXEC_USER=shipyard
NIX_USER_PROFILE=/nix/var/nix/profiles/per-user/shipyard/profile
MANAGED_MARKER="# Managed by Ship entrypoint"

quote_shell_value() {
    local value="$1"
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

# ── Package mirrors ─────────────────────────────────────
# Each SHIPYARD_*_MIRROR is translated into the setting its tools read. The
# result is exported here, so the Ship server and everything it starts
# (shell commands, the IPython kernel, terminals) inherit it. Tools' own
# variables (PIP_INDEX_URL, NPM_CONFIG_REGISTRY, ...) set on the container are
# inherited as well and need no translation.
apply_mirrors() {
    if [ -n "${SHIPYARD_PYPI_MIRROR:-}" ]; then
        export PIP_INDEX_URL="$SHIPYARD_PYPI_MIRROR"
        export UV_DEFAULT_INDEX="$SHIPYARD_PYPI_MIRROR"
    fi
    if [ -n "${SHIPYARD_CONDA_MIRROR:-}" ]; then
        # Channel alias: conda-forge resolves to <mirror>/conda-forge.
        export CONDA_CHANNEL_ALIAS="${SHIPYARD_CONDA_MIRROR%/}"
    fi
    if [ -n "${SHIPYARD_NPM_MIRROR:-}" ]; then
        export NPM_CONFIG_REGISTRY="$SHIPYARD_NPM_MIRROR"
        export BUN_CONFIG_REGISTRY="$SHIPYARD_NPM_MIRROR"
    fi
    if [ -n "${SHIPYARD_RUSTUP_MIRROR:-}" ]; then
        export RUSTUP_DIST_SERVER="${SHIPYARD_RUSTUP_MIRROR%/}"
        export RUSTUP_UPDATE_ROOT="${SHIPYARD_RUSTUP_MIRROR%/}/rustup"
    fi
    if [ -n "${SHIPYARD_PYTHON_MIRROR:-}" ]; then
        export UV_PYTHON_INSTALL_MIRROR="$SHIPYARD_PYTHON_MIRROR"
    fi
    if [ -n "${SHIPYARD_NIX_MIRROR:-}" ]; then
        # Mirrors of cache.nixos.org carry its signatures, so the default
        # trusted key still applies. Several mirrors may be space-separated.
        export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}substituters = $SHIPYARD_NIX_MIRROR https://cache.nixos.org/"
    fi

    # Cargo has no environment variable for source replacement, so the mirror
    # goes into $CARGO_HOME/config.toml. Only a file this script wrote is
    # rewritten or removed; one the agent wrote is left alone.
    local cargo_config="${CARGO_HOME:-/opt/cargo}/config.toml"
    if [ -e "$cargo_config" ] && ! head -n 1 "$cargo_config" | grep -qF "$MANAGED_MARKER"; then
        if [ -n "${SHIPYARD_CRATES_MIRROR:-}" ]; then
            echo "[ship] $cargo_config was edited in the sandbox; not applying SHIPYARD_CRATES_MIRROR"
        fi
    elif [ -n "${SHIPYARD_CRATES_MIRROR:-}" ]; then
        local registry="$SHIPYARD_CRATES_MIRROR"
        case "$registry" in
            sparse+*|git+*|registry+*) ;;
            *) registry="sparse+${registry%/}/" ;;
        esac
        mkdir -p "$(dirname "$cargo_config")"
        {
            echo "$MANAGED_MARKER from SHIPYARD_CRATES_MIRROR; edit it to take it over."
            echo '[source.crates-io]'
            echo 'replace-with = "shipyard-mirror"'
            echo '[source.shipyard-mirror]'
            printf 'registry = "%s"\n' "$registry"
        } > "$cargo_config"
        chown "$EXEC_USER:$EXEC_USER" "$cargo_config"
    else
        rm -f "$cargo_config"
    fi
}

# ── Shell startup files ─────────────────────────────────
# Older images baked a .bashrc/.bash_profile into the workspace that pinned
# PATH to the Ubuntu layout; on a reused workspace that line would hide the
# toolchains, so it is dropped. Missing files get a minimal default.
init_shell_files() {
    local legacy_path_line='export PATH=/opt/conda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    local rc
    for rc in /workspace/.bashrc /workspace/.bash_profile; do
        if [ -f "$rc" ] && grep -qxF "$legacy_path_line" "$rc"; then
            grep -vxF "$legacy_path_line" "$rc" > "$rc.tmp" || true
            cat "$rc.tmp" > "$rc"
            rm -f "$rc.tmp"
        fi
    done
    if [ ! -e /workspace/.bashrc ]; then
        echo "export PS1='\\u@shipyard:\\w\\$ '" > /workspace/.bashrc
    fi
    if [ ! -e /workspace/.bash_profile ]; then
        echo '[ -f ~/.bashrc ] && . ~/.bashrc' > /workspace/.bash_profile
    fi
}

if [ "$(id -u)" != "0" ]; then
    # Already started unprivileged (e.g. a pod securityContext): nothing to
    # fix or drop, just apply what does not need root.
    apply_mirrors
    exec catatonit -- "$@"
fi

apply_mirrors

# pacman's mirror list is a root-owned file, so it is set here rather than in
# apply_mirrors. The agent cannot install with pacman (no root), but it can
# search the bundled package databases, and root maintenance uses this list.
# Accepts a base URL (…/archlinux) or a full one containing $repo/$arch.
if [ -n "${SHIPYARD_PACMAN_MIRROR:-}" ]; then
    : > /etc/pacman.d/mirrorlist
    for mirror in $SHIPYARD_PACMAN_MIRROR; do
        case "$mirror" in
            *'$repo'*) ;;
            *) mirror="${mirror%/}/\$repo/os/\$arch" ;;
        esac
        echo "Server = $mirror" >> /etc/pacman.d/mirrorlist
    done
fi

# Generate environment variables file for shell/python execution.
# Always rewrite the file to avoid stale env from a reused workspace.
mkdir -p /workspace
echo "# Auto-generated by Ship from runtime environment" > /workspace/.bay_env.sh

# Propagate container-level proxy vars into shell/python user processes.
for name in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy; do
    value="${!name}"
    if [ -n "$value" ]; then
        printf 'export %s=' "$name" >> /workspace/.bay_env.sh
        quote_shell_value "$value" >> /workspace/.bay_env.sh
        printf '\n' >> /workspace/.bay_env.sh
    fi
done

# Split by colon and export each variable
if [ -n "$BAY_PROFILE_ENV" ]; then
    IFS=':' read -ra ENV_PAIRS <<< "$BAY_PROFILE_ENV"
    for pair in "${ENV_PAIRS[@]}"; do
        # Only export if it contains an equals sign and isn't empty
        if [[ "$pair" == *"="* ]]; then
            key="${pair%%=*}"
            value="${pair#*=}"
            printf 'export %s=' "$key" >> /workspace/.bay_env.sh
            quote_shell_value "$value" >> /workspace/.bay_env.sh
            printf '\n' >> /workspace/.bay_env.sh
        fi
    done
fi

chmod 644 /workspace/.bay_env.sh
echo "[ship] generated /workspace/.bay_env.sh from runtime env"

init_shell_files

# `nix profile` installs into the profile ~/.nix-profile points at. Keep it
# in /nix, next to the store it refers to: the workspace outlives the
# container, the store does not.
ln -sfn "$NIX_USER_PROFILE" /workspace/.nix-profile

# Fix workspace permissions for shipyard user
# This is needed when /workspace is a mounted volume with root ownership
if [ -d /workspace ]; then
    chown -R shipyard:shipyard /workspace 2>/dev/null || true
    chmod 755 /workspace 2>/dev/null || true
fi

# Inject built-in skills into /workspace/skills/ (per-skill overwrite).
# Each skill directory in /app/skills/ is individually rm+cp'd so that:
#   - built-in skills are always at the image version (idempotent)
#   - skills from other runtimes (Gull) or upper-layer agents are untouched
if [ -d /app/skills ] && [ "$(ls -A /app/skills 2>/dev/null)" ]; then
    mkdir -p /workspace/skills
    for skill_dir in /app/skills/*/; do
        [ -d "$skill_dir" ] || continue
        skill_name=$(basename "$skill_dir")
        rm -rf "/workspace/skills/$skill_name"
        cp -r "$skill_dir" "/workspace/skills/$skill_name"
    done
    chown -R shipyard:shipyard /workspace/skills
    echo "[ship] injected built-in skills to /workspace/skills/"
fi

# Drop to shipyard for good: no capabilities, and no_new_privs so that no
# setuid binary can bring root back. catatonit stays PID 1 to reap orphaned
# processes (browsers, background jobs), which the server would leave as
# zombies counting against the pids limit.
export HOME=/workspace USER="$EXEC_USER" LOGNAME="$EXEC_USER" SHELL=/bin/bash
exec setpriv --reuid="$EXEC_USER" --regid="$EXEC_USER" --init-groups \
    --inh-caps=-all --bounding-set=-all --no-new-privs -- catatonit -- "$@"
