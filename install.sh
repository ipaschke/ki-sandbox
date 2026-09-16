#!/bin/bash
# Installer for the agent sandbox (docker + devcontainer CLI + sbx wrappers).
# Idempotent: re-run after pulling changes. Steps:
#   1. docker.io via apt (asks for the admin password via pkexec, or sudo)
#   2. docker service enabled, current user added to the docker group
#   3. @devcontainers/cli via npm, using a user-writable prefix
#   4. sbx-* shims in ~/.local/bin
#   5. Ptyxis: green header bar for sandbox windows (GTK user CSS)
#   6. optional image build (--build)
#
# Usage: ./install.sh [--build] [--no-docker] [--no-gtk]
set -euo pipefail

SANDBOX_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
BIN_DIR="$HOME/.local/bin"
do_build=0 do_docker=1 do_gtk=1
for a in "$@"; do
    case "$a" in
        --build) do_build=1 ;;
        --no-docker) do_docker=0 ;;
        --no-gtk) do_gtk=0 ;;
        -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
need_relogin=0

# Run a command as root, preferring the graphical polkit prompt.
as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"
    elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v pkexec >/dev/null; then pkexec "$@"
    else sudo "$@"
    fi
}

# ---- 1+2. docker --------------------------------------------------------
if [ "$do_docker" = 1 ]; then
    if ! command -v docker >/dev/null; then
        say "installing docker.io"
        as_root bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -q && apt-get install -y docker.io'
    else
        say "docker present: $(docker --version)"
    fi
    if ! systemctl is-active --quiet docker; then
        say "enabling docker service"
        as_root systemctl enable --now docker
    fi
    if ! id -nG | tr ' ' '\n' | grep -qx docker; then
        say "adding $USER to docker group"
        as_root usermod -aG docker "$USER"
        need_relogin=1
    fi
fi

# ---- 3. devcontainer CLI ------------------------------------------------
if ! command -v npm >/dev/null; then
    echo "npm not found; install nodejs first (apt install nodejs npm)" >&2
    exit 1
fi
prefix="$(npm config get prefix)"
if ! [ -w "$prefix/lib/node_modules" ] 2>/dev/null && ! [ -w "$prefix/lib" ] 2>/dev/null; then
    say "npm prefix $prefix not writable; switching to ~/.local"
    npm config set prefix "$HOME/.local"
fi
if command -v devcontainer >/dev/null; then
    say "devcontainer CLI present: $(devcontainer --version)"
else
    say "installing @devcontainers/cli"
    npm install -g @devcontainers/cli
fi

# ---- 4. shims -----------------------------------------------------------
say "installing shims into $BIN_DIR"
mkdir -p "$BIN_DIR"
chmod +x "$SANDBOX_DIR/sbx" "$SANDBOX_DIR/seed-config.sh" "$SANDBOX_DIR/sbx-git.py" \
         "$SANDBOX_DIR/.devcontainer/init-firewall.sh" "$SANDBOX_DIR/.devcontainer/git-wrapper.sh"
ln -sf "$SANDBOX_DIR/sbx" "$BIN_DIR/sbx"
for t in claude codex shell seed stop rebuild ps git; do
    printf '#!/bin/bash\nexec "%s/sbx" %s "$@"\n' "$SANDBOX_DIR" "$t" > "$BIN_DIR/sbx-$t"
    chmod +x "$BIN_DIR/sbx-$t"
done
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on PATH" ;;
esac

# ---- 5. Ptyxis header colour -------------------------------------------
# Ptyxis adds a .container CSS class to its window when the foreground
# process is docker/podman (like .remote for ssh) but ships no colour for it.
if [ "$do_gtk" = 1 ] && command -v ptyxis >/dev/null; then
    css="$HOME/.config/gtk-4.0/gtk.css"
    if ! grep -qs 'window.container' "$css"; then
        say "adding Ptyxis container colour to $css"
        mkdir -p "$(dirname "$css")"
        cat >> "$css" <<'CSS'
/* sbx: green header bar while the foreground process is docker/podman */
window.container .window-contents headerbar,
window.container .window-contents toolbarview > revealer > windowhandle {
  background-color: #1f6b3a;
  color: #ffffff;
}
CSS
        warn "restart Ptyxis (close all windows, or 'pkill ptyxis') to load the CSS"
    fi
fi

# ---- 6. image -----------------------------------------------------------
if [ "$do_build" = 1 ]; then
    if docker info >/dev/null 2>&1; then
        say "building sandbox image"
        tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
        "$SANDBOX_DIR/sbx" rebuild "$tmp" >/dev/null
        "$SANDBOX_DIR/sbx" stop "$tmp" >/dev/null
    elif [ "$need_relogin" = 1 ]; then
        warn "skipping build: docker group not active in this shell yet"
    else
        warn "skipping build: docker daemon not reachable"
    fi
fi

say "done"
if [ "$need_relogin" = 1 ]; then
    echo
    echo "Docker group added. Before using sbx-* in this shell run:"
    echo "    newgrp docker"
    echo "or log out and back in."
fi
echo
echo "Try:  cd <project> && sbx-claude"
echo "Docs: $SANDBOX_DIR/README.md"
