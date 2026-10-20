#!/usr/bin/env bash
# Install a tree built with `make build` into ~/.local, without root, with a
# menu entry and the grokbot:// and sand:// handlers that browser sign-in
# returns to. Based on the user install in lyffseba's fork.
#
# Usage: scripts/install-user.sh [X.Y.Z]   (default: newest tree in dist/)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(find "${ROOT}/dist" -maxdepth 1 -type d -name 'Grok_Bot_*_linux_x64' 2>/dev/null |
    sed -E 's/.*Grok_Bot_([0-9.]+)_linux_x64$/\1/' | sort -V | tail -1)"
fi
[[ -n "$VERSION" ]] || { echo "error: no built tree in dist/. Run: make build" >&2; exit 1; }

STAGE="${ROOT}/dist/Grok_Bot_${VERSION}_linux_x64"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APPDIR="${DATA}/grok-bot-unofficial"
BINDIR="${HOME}/.local/bin"
APPS="${DATA}/applications"
ICONS="${DATA}/icons/hicolor"
BIN="${BINDIR}/grok-bot"
DESKTOP="${APPS}/grok-bot.desktop"

[[ -x "${STAGE}/grok-bot" ]] || { echo "error: ${STAGE}/grok-bot is missing. Run: make build" >&2; exit 1; }
if [[ -e "$BIN" && ! -L "$BIN" ]] && ! grep -q 'grok-bot-unofficial' "$BIN" 2>/dev/null; then
  echo "error: ${BIN} exists and was not created by this script" >&2
  exit 1
fi

mkdir -p "$APPDIR" "$BINDIR" "$APPS" "${XDG_CONFIG_HOME:-$HOME/.config}"
echo "Installing unofficial Grok Bot ${VERSION} to ${APPDIR}"
rm -rf "${APPDIR}.new"
cp -a "${STAGE}" "${APPDIR}.new"
# A user install cannot own chrome-sandbox as root:root 4755; the launcher
# falls back to --no-sandbox when the setuid helper is unavailable.
chmod 0755 "${APPDIR}.new/chrome-sandbox" 2>/dev/null || true
rm -rf "$APPDIR"
mv "${APPDIR}.new" "$APPDIR"

# Reuse the packaged launcher with this install's location.
sed "s|^APPDIR=.*|APPDIR=\"${APPDIR}\"|" "${ROOT}/packaging/grok-bot.sh" > "$BIN"
chmod 0755 "$BIN"

sed "s|^Exec=.*|Exec=\"${BIN}\" %U|" "${ROOT}/packaging/grok-bot.desktop" > "$DESKTOP"
chmod 0644 "$DESKTOP"

if [[ -f "${APPDIR}/grok-bot.png" ]]; then
  for size in 256 512; do
    install -Dm0644 "${APPDIR}/grok-bot.png" "${ICONS}/${size}x${size}/apps/grok-bot.png"
  done
fi

command -v desktop-file-validate >/dev/null && desktop-file-validate "$DESKTOP" || true
command -v update-desktop-database >/dev/null && update-desktop-database -q "$APPS" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$ICONS" 2>/dev/null || true
if command -v xdg-mime >/dev/null; then
  xdg-mime default grok-bot.desktop x-scheme-handler/grokbot x-scheme-handler/sand
else
  echo "note: xdg-mime not found (package xdg-utils); browser sign-in may not return to the app" >&2
fi

echo
echo "Installed for this user:"
echo "  command : ${BIN}"
echo "  menu    : Grok Bot"
echo "  links   : grokbot:// and sand:// open Grok Bot"
echo "  remove  : make uninstall-user"
case ":${PATH}:" in *":${BINDIR}:"*) ;; *) echo "note: ${BINDIR} is not on your PATH" ;; esac
