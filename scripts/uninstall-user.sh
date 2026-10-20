#!/usr/bin/env bash
# Remove the ~/.local install made by scripts/install-user.sh.
set -euo pipefail

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APPDIR="${DATA}/grok-bot-unofficial"
BIN="${HOME}/.local/bin/grok-bot"
APPS="${DATA}/applications"
DESKTOP="${APPS}/grok-bot.desktop"
ICONS="${DATA}/icons/hicolor"
MIMEAPPS="${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list"

rm -rf "$APPDIR" "${APPDIR}.new"
if [[ -f "$BIN" ]] && grep -q 'grok-bot-unofficial' "$BIN"; then
  rm -f "$BIN"
fi
if [[ -f "$DESKTOP" ]] && grep -q 'grok-bot-unofficial\|\.local/bin/grok-bot' "$DESKTOP"; then
  rm -f "$DESKTOP"
fi
for size in 256 512; do
  rm -f "${ICONS}/${size}x${size}/apps/grok-bot.png"
done
# Drop the scheme handler defaults this install registered.
if [[ -f "$MIMEAPPS" ]]; then
  sed -i -E '/^x-scheme-handler\/(grokbot|sand)=grok-bot\.desktop;?$/d' "$MIMEAPPS"
fi
command -v update-desktop-database >/dev/null && update-desktop-database -q "$APPS" || true

echo "Removed the user install of unofficial Grok Bot."
