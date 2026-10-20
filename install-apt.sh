#!/usr/bin/env bash
# Add the grok-bot-linux apt repo, install the helper package, then fetch
# Cursor's official Grok Bot build (verified). Re-run with sudo.
set -euo pipefail
REPO_URL="${REPO_URL:-https://devrecated.github.io/grok-bot-linux}"
if [ "$(id -u)" -ne 0 ]; then
  echo "re-run with sudo" >&2
  exit 1
fi
curl -fsSL "${REPO_URL}/grok-bot-linux.list" -o /etc/apt/sources.list.d/grok-bot-linux.list
if curl -fsSL "${REPO_URL}/grok-bot-linux.asc" -o /usr/share/keyrings/grok-bot-linux.asc 2>/dev/null; then
  sed -i 's/\[trusted=yes\]/[signed-by=\/usr\/share\/keyrings\/grok-bot-linux.asc]/' /etc/apt/sources.list.d/grok-bot-linux.list || true
fi
apt-get update -qq
apt-get install -y grok-bot-linux
# Fetch and verify the official build now (network required). The .deb itself
# never contained it.
grok-bot-linux-setup
echo "OK: grok-bot-linux helper + official Grok Bot installed"
