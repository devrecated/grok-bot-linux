#!/usr/bin/env bash
# Build an Ubuntu/Debian amd64 .deb from a staged Linux app directory.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <staged-app-dir> <version> [output-dir]" >&2
  exit 1
fi

STAGE="$(readlink -f "$1")"
VERSION="$2"
OUT="${3:-$(pwd)/dist}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -x "${STAGE}/grok-bot" ]]; then
  echo "error: ${STAGE}/grok-bot is not an executable" >&2
  exit 1
fi

WORKDIR="$(mktemp -d -t grokbot-deb-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

PKG="${WORKDIR}/grok-bot_${VERSION}_amd64"
mkdir -p \
  "${PKG}/DEBIAN" \
  "${PKG}/opt/grok-bot" \
  "${PKG}/usr/bin" \
  "${PKG}/usr/share/applications" \
  "${PKG}/usr/share/icons/hicolor/256x256/apps" \
  "${PKG}/usr/share/doc/grok-bot"

cp -a "${STAGE}/." "${PKG}/opt/grok-bot/"
install -m 0755 "${ROOT}/packaging/grok-bot.sh" "${PKG}/usr/bin/grok-bot"
install -m 0644 "${ROOT}/packaging/grok-bot.desktop" \
  "${PKG}/usr/share/applications/grok-bot.desktop"
install -Dm 0644 "${ROOT}/packaging/apparmor-grok-bot" \
  "${PKG}/opt/grok-bot/resources/apparmor-profile"

ICON=""
if [[ -f "${STAGE}/grok-bot.png" ]]; then
  ICON="${STAGE}/grok-bot.png"
else
  ICON="$(find "${STAGE}" -name 'app-icon*.png' | head -1 || true)"
fi
if [[ -n "$ICON" && -f "$ICON" ]]; then
  install -m 0644 "$ICON" "${PKG}/usr/share/icons/hicolor/256x256/apps/grok-bot.png"
  install -m 0644 "$ICON" "${PKG}/opt/grok-bot/grok-bot.png"
fi

cat > "${PKG}/usr/share/doc/grok-bot/README.Debian" <<EOF
Grok Bot for Linux (unofficial)

This package rebuilds the official Windows desktop app on Electron for
Linux. It is not affiliated with xAI or Cursor. Sign in with the same
Cursor account you use on macOS or Windows.

User flags: ~/.config/grok-bot/electron-flags.conf
EOF

cat > "${PKG}/DEBIAN/control" <<EOF
Package: grok-bot
Version: ${VERSION}
Section: net
Priority: optional
Architecture: amd64
Maintainer: grok-bot-linux contributors
Depends: libgtk-3-0 | libgtk-3-0t64, libnotify4, libnss3, libxss1, libxtst6, xdg-utils, libatspi2.0-0 | libatspi2.0-0t64, libsecret-1-0, libasound2 | libasound2t64, libgbm1, libxkbcommon0, libdrm2, libcups2 | libcups2t64, libxcomposite1, libxdamage1, libxrandr2, libuuid1
Recommends: libfuse2 | libfuse2t64
Description: Unofficial Linux build of the Grok Bot desktop app
 Rebuilds Cursor's official Windows Grok Bot installer on the
 official Electron Linux runtime. Native Windows addons are replaced
 with Linux ELF binaries before packaging.
EOF

cat > "${PKG}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
SANDBOX=/opt/grok-bot/chrome-sandbox
if [ -f "$SANDBOX" ]; then
  chown root:root "$SANDBOX" 2>/dev/null || true
  chmod 4755 "$SANDBOX" 2>/dev/null || chmod 0755 "$SANDBOX"
fi
if command -v update-desktop-database >/dev/null; then
  update-desktop-database -q /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null; then
  gtk-update-icon-cache -q /usr/share/icons/hicolor || true
fi
# Install the AppArmor profile that grants user namespaces to the app, so
# the sandbox works where unprivileged userns is restricted (Ubuntu 24.04+).
PROFILE_SRC=/opt/grok-bot/resources/apparmor-profile
PROFILE=/etc/apparmor.d/grok-bot
if command -v apparmor_parser >/dev/null && [ -d /etc/apparmor.d ] && \
    apparmor_parser --skip-kernel-load --debug "$PROFILE_SRC" >/dev/null 2>&1; then
  cp -f "$PROFILE_SRC" "$PROFILE"
  if [ -d /sys/kernel/security/apparmor ] && \
      ! { [ -x /usr/bin/ischroot ] && /usr/bin/ischroot; }; then
    apparmor_parser --replace --write-cache --skip-read-cache "$PROFILE" || true
  fi
fi
EOF
chmod 0755 "${PKG}/DEBIAN/postinst"

cat > "${PKG}/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
PROFILE=/etc/apparmor.d/grok-bot
if [ "$1" = remove ] || [ "$1" = purge ]; then
  if [ -f "$PROFILE" ]; then
    if command -v apparmor_parser >/dev/null && [ -d /sys/kernel/security/apparmor ]; then
      apparmor_parser --remove "$PROFILE" >/dev/null 2>&1 || true
    fi
    rm -f "$PROFILE"
  fi
fi
EOF
chmod 0755 "${PKG}/DEBIAN/postrm"

# chrome-sandbox must be root:root 4755 in the package for dpkg to keep setuid
if [[ -f "${PKG}/opt/grok-bot/chrome-sandbox" ]]; then
  chmod 4755 "${PKG}/opt/grok-bot/chrome-sandbox" || true
fi

mkdir -p "$OUT"
DEB="${OUT}/grok-bot_${VERSION}_amd64.deb"
if command -v fakeroot >/dev/null; then
  fakeroot dpkg-deb --build "$PKG" "$DEB" >/dev/null
else
  dpkg-deb --build "$PKG" "$DEB" >/dev/null
fi
echo "$DEB"
