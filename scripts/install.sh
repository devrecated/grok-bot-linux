#!/usr/bin/env bash
# One-command installer for Grok Bot Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/devrecated/grok-bot-linux/main/scripts/install.sh | bash
#
# It clones (or updates) this repository into your home directory and runs the
# repo's own hardened pipeline. By default it installs Cursor's official Linux
# build, verified against Cursor's signed package metadata. When no official
# build is available for your machine, it falls back to the from-source rebuild
# (make update / make build).
#
# This installer never bundles or re-hosts xAI's app: the official app is always
# fetched at install time by the repo scripts.
#
# Environment overrides:
#   GROK_BOT_LINUX_REPO    git URL to clone (default: devrecated/grok-bot-linux)
#   GROK_BOT_LINUX_BRANCH  branch to use (default: main)
#   GROK_BOT_LINUX_SRC     checkout directory (default: ~/.local/share/grok-bot-linux/src)
#   GROK_BOT_LINUX_MODE    official | source | auto (default: auto)
#   GROK_BOT_LINUX_NO_DEPS set to 1 to skip installing build dependencies
set -euo pipefail

REPO_URL="${GROK_BOT_LINUX_REPO:-https://github.com/devrecated/grok-bot-linux.git}"
BRANCH="${GROK_BOT_LINUX_BRANCH:-main}"
SRC_DIR="${GROK_BOT_LINUX_SRC:-$HOME/.local/share/grok-bot-linux/src}"
MODE="${GROK_BOT_LINUX_MODE:-auto}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Linux" ] || die "this installer only supports Linux (found $(uname -s)). On macOS use 'make mac'."

case "$(uname -m)" in
  x86_64|amd64|aarch64|arm64) ;;
  *) die "unsupported architecture: $(uname -m) (x86_64 and aarch64 are supported)" ;;
esac

case "$MODE" in official|source|auto) ;; *) die "GROK_BOT_LINUX_MODE must be official, source or auto" ;; esac

have() { command -v "$1" >/dev/null 2>&1; }

# Detect the distro package manager so we can install dependencies.
PKG=""
if   have apt-get; then PKG=apt
elif have dnf;     then PKG=dnf
elif have pacman;  then PKG=pacman
elif have zypper;  then PKG=zypper
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if have sudo; then SUDO="sudo"; fi
fi

run_root() {
  if [ -n "$SUDO" ]; then
    "$SUDO" "$@"
  elif [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
# Minimal set needed to clone and to run make install-official. The from-source
# path pulls heavier tools; we install those only when we fall back to it.
ensure_core_tools() {
  local missing=()
  for t in git curl make python3; do
    have "$t" || missing+=("$t")
  done
  # The official path needs a signature checker.
  if ! have gpgv && ! have gpg; then missing+=("gpg"); fi
  if ! have sha256sum; then missing+=("sha256sum"); fi

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi
  if [ "${GROK_BOT_LINUX_NO_DEPS:-0}" = "1" ]; then
    die "missing tools: ${missing[*]} (GROK_BOT_LINUX_NO_DEPS=1 set; install them yourself)"
  fi
  log "installing core tools: ${missing[*]}"
  install_packages git curl make python3 gpg coreutils
}

# Map generic names to each distro's packages and install them.
install_packages() {
  [ -n "$PKG" ] || { warn "no known package manager; install these yourself: $*"; return 0; }
  case "$PKG" in
    apt)
      run_root apt-get update -y || warn "apt-get update failed; continuing"
      run_root apt-get install -y "$@" || warn "apt-get install failed for: $*"
      ;;
    dnf)    run_root dnf install -y "$@"    || warn "dnf install failed for: $*" ;;
    zypper) run_root zypper install -y "$@" || warn "zypper install failed for: $*" ;;
    pacman) run_root pacman -S --needed --noconfirm "$@" || warn "pacman install failed for: $*" ;;
  esac
}

# Per-distro build dependencies for the from-source rebuild path.
install_build_deps() {
  [ "${GROK_BOT_LINUX_NO_DEPS:-0}" = "1" ] && { warn "skipping build deps (GROK_BOT_LINUX_NO_DEPS=1)"; return 0; }
  log "installing build dependencies for the from-source rebuild"
  case "$PKG" in
    apt)    install_packages p7zip-full curl unzip build-essential python3 libfuse2 fakeroot ;;
    dnf)    install_packages nodejs npm gcc gcc-c++ unzip python3 curl p7zip p7zip-plugins fuse-libs fakeroot ;;
    pacman) install_packages nodejs npm gcc unzip python curl 7zip fuse2 fakeroot ;;
    zypper) install_packages nodejs npm gcc gcc-c++ unzip python3 curl p7zip fuse-libs fakeroot ;;
    *)      warn "install build deps manually: 7zip, curl, unzip, a C/C++ toolchain, python3, Node.js 20+, fakeroot" ;;
  esac
  if ! have node; then
    warn "Node.js not found. The rebuild needs Node 20+. See https://github.com/nvm-sh/nvm or NodeSource."
  fi
}

# ---------------------------------------------------------------------------
# Fetch the repository
# ---------------------------------------------------------------------------
fetch_repo() {
  if [ -d "$SRC_DIR/.git" ]; then
    log "updating existing checkout in $SRC_DIR"
    git -C "$SRC_DIR" remote set-url origin "$REPO_URL"
    git -C "$SRC_DIR" fetch --depth 1 origin "$BRANCH"
    git -C "$SRC_DIR" checkout -q "$BRANCH"
    git -C "$SRC_DIR" reset --hard "origin/$BRANCH"
  else
    log "cloning $REPO_URL ($BRANCH) into $SRC_DIR"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
  fi
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
install_official() {
  log "installing Cursor's official Linux build (verified)"
  make -C "$SRC_DIR" install-official
}

install_from_source() {
  install_build_deps
  log "building and installing from source"
  make -C "$SRC_DIR" update
}

main() {
  ensure_core_tools
  fetch_repo

  case "$MODE" in
    official)
      install_official
      ;;
    source)
      install_from_source
      ;;
    auto)
      if "$SRC_DIR/scripts/install-official.sh" --check >/dev/null 2>&1 && install_official; then
        :
      else
        warn "official build unavailable or failed; falling back to the from-source rebuild"
        install_from_source
      fi
      ;;
  esac

  log "done. Launch Grok Bot from your app menu or run: grok-bot"
  log "checkout kept at $SRC_DIR (re-run this installer, or 'grok-bot-update', to update)"
}

main "$@"
