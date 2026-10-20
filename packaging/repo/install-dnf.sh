#!/usr/bin/env bash
# Add the grok-bot-linux dnf/yum repo, install the helper package, then fetch
# Cursor's official Grok Bot build (verified). Re-run with sudo.
set -euo pipefail
REPO_URL="${REPO_URL:-@REPO_URL@}"
if [ "$(id -u)" -ne 0 ]; then
  echo "re-run with sudo" >&2
  exit 1
fi
curl -fsSL "${REPO_URL}/grok-bot-linux.repo" -o /etc/yum.repos.d/grok-bot-linux.repo
if command -v dnf >/dev/null 2>&1; then
  dnf install -y grok-bot-linux
elif command -v yum >/dev/null 2>&1; then
  yum install -y grok-bot-linux
else
  echo "need dnf or yum" >&2
  exit 1
fi
grok-bot-linux-setup
echo "OK: grok-bot-linux helper + official Grok Bot installed"
