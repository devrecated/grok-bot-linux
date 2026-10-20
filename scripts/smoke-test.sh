#!/usr/bin/env bash
# Quick check that a staged Linux build actually works:
#   1. every native addon in runtime-deps-manifest.json loads in the app's
#      own Electron and exports what its wrapper expects
#   2. the app starts under Xvfb and stays up without the errors a broken
#      port produces (missing module, missing export, PE/ELF mix-ups)
#
# Usage: scripts/smoke-test.sh [--no-launch] [APP_DIR]
# APP_DIR defaults to the newest dist/Grok_Bot_*_linux_x64.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH=1
APP=""
for arg in "$@"; do
  case "$arg" in
    --no-launch) LAUNCH=0 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) APP="$arg" ;;
  esac
done
if [ -z "$APP" ]; then
  APP="$(ls -dt "$ROOT"/dist/Grok_Bot_*_linux_x64 2>/dev/null | head -n1 || true)"
fi
if [ -z "$APP" ] || [ ! -x "$APP/grok-bot" ]; then
  echo "error: no staged build found; run make build or pass APP_DIR" >&2
  exit 2
fi
APP="$(cd "$APP" && pwd)"
echo "Testing $APP"

status=0
[ -f "$APP/resources/icon.png" ] && echo "ok    resources/icon.png" ||
  { echo "FAIL  resources/icon.png missing"; status=1; }

# The app resolves its bundled deps (node-gyp-build etc.) from dist/deps.
NODE_PATH="$APP/resources/app.asar.unpacked/dist/deps" ELECTRON_RUN_AS_NODE=1 "$APP/grok-bot" "$ROOT/scripts/smoke-test.js" "$APP/resources" || status=1

if [ "$LAUNCH" = 1 ]; then
  if ! command -v Xvfb >/dev/null 2>&1; then
    echo "skip  launch test (install Xvfb, or pass --no-launch to silence this)"
  else
    tmp="$(mktemp -d)"
    display=":$((90 + RANDOM % 100))"
    Xvfb "$display" -screen 0 1280x800x24 >/dev/null 2>&1 &
    xvfb=$!
    sleep 1
    sandbox=()
    unshare --user true 2>/dev/null || sandbox=(--no-sandbox)
    DISPLAY="$display" HOME="$tmp" XDG_CONFIG_HOME="$tmp/config" ELECTRON_ENABLE_LOGGING=1 \
      "$APP/grok-bot" "${sandbox[@]}" --disable-gpu --class=grok-bot >"$tmp/log" 2>&1 &
    app=$!
    sleep "${SMOKE_WAIT:-15}"
    if kill -0 "$app" 2>/dev/null; then
      echo "ok    app still running after ${SMOKE_WAIT:-15}s"
    else
      echo "FAIL  app exited early"; status=1
    fi
    kill "$app" 2>/dev/null || true
    sleep 1
    pkill -9 -f "^$APP/grok-bot" 2>/dev/null || true
    kill "$xvfb" 2>/dev/null || true
    pattern='Cannot find module|is not a function|invalid ELF header|not a valid Win32|Failed to load image|icon.png'
    if grep -E "$pattern" "$tmp/log" >/dev/null; then
      echo "FAIL  errors in app log:"
      grep -E "$pattern" "$tmp/log" | sort -u | head -n 10 | sed 's/^/        /'
      status=1
    else
      echo "ok    no load errors in app log"
    fi
    [ "$status" = 0 ] && rm -rf "$tmp" || echo "      log kept at $tmp/log"
  fi
fi

[ "$status" = 0 ] && echo "smoke test passed" || echo "smoke test FAILED"
exit "$status"
