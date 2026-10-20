#!/bin/sh
# Installed launcher for /opt/grok-bot.
# Keeps Chromium's sandbox on whenever this machine can run it and only
# falls back to --no-sandbox (with a warning) when it cannot.

set -eu

APPDIR="/opt/grok-bot"
BIN="$APPDIR/grok-bot"
FLAGS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/grok-bot/electron-flags.conf"

# Chromium can sandbox with unprivileged user namespaces, with the setuid
# chrome-sandbox helper, or (Ubuntu 24.04+, where unprivileged userns is
# restricted) with userns granted by the grok-bot AppArmor profile.
sandbox_ok() {
  if command -v unshare >/dev/null 2>&1 && unshare --user true 2>/dev/null; then
    return 0
  fi
  if [ -u "$APPDIR/chrome-sandbox" ] && [ "$(stat -c %u "$APPDIR/chrome-sandbox" 2>/dev/null)" = 0 ]; then
    return 0
  fi
  grep -q '^grok-bot ' /sys/kernel/security/apparmor/profiles 2>/dev/null
}

# One flag per line; lines are passed as-is (no word splitting or globbing).
if [ -f "$FLAGS_FILE" ]; then
  flags=""
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    case "$trimmed" in ''|'#'*) continue ;; esac
    flags="${flags}$(printf '%s' "$trimmed" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/'/") "
  done < "$FLAGS_FILE"
  eval "set -- $flags \"\$@\""
fi

if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -z "${ELECTRON_OZONE_PLATFORM_HINT:-}" ]; then
  set -- --ozone-platform-hint=auto "$@"
fi

if ! sandbox_ok; then
  echo "grok-bot: Chromium sandbox unavailable here; starting with --no-sandbox" >&2
  set -- --no-sandbox "$@"
fi

exec "$BIN" --class=grok-bot "$@"
