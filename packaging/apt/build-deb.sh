#!/usr/bin/env bash
# Build the grok-bot-linux helper .deb (scripts only; no xAI binaries).
#
# Usage: packaging/apt/build-deb.sh [output-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
OUT="${1:-${ROOT}/dist/linux-repos}"
VERSION="$(tr -d '[:space:]' < "${ROOT}/packaging/linux/VERSION")"
ARCH=all
PKG_NAME=grok-bot-linux

command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb is required" >&2; exit 1; }

WORK="$(mktemp -d -t grokbot-linux-deb-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PKG="${WORK}/${PKG_NAME}_${VERSION}_${ARCH}"
mkdir -p \
  "${PKG}/DEBIAN" \
  "${PKG}/usr/lib/${PKG_NAME}/scripts" \
  "${PKG}/usr/lib/${PKG_NAME}/packaging/linux" \
  "${PKG}/usr/bin" \
  "${PKG}/usr/share/doc/${PKG_NAME}"

install -m 0755 "${ROOT}/scripts/install-official.sh" \
  "${PKG}/usr/lib/${PKG_NAME}/scripts/install-official.sh"
install -m 0644 "${ROOT}/packaging/anysphere-release-key.asc" \
  "${PKG}/usr/lib/${PKG_NAME}/packaging/anysphere-release-key.asc"
install -m 0755 "${ROOT}/packaging/linux/install-official-system.sh" \
  "${PKG}/usr/lib/${PKG_NAME}/packaging/linux/install-official-system.sh"
install -m 0644 "${ROOT}/LICENSE" \
  "${PKG}/usr/share/doc/${PKG_NAME}/copyright"
install -m 0644 "${ROOT}/packaging/linux/VERSION" \
  "${PKG}/usr/lib/${PKG_NAME}/VERSION"

# Thin CLI that points at the packaged install-official.sh.
cat > "${PKG}/usr/bin/grok-bot-linux-setup" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/lib/grok-bot-linux/packaging/linux/install-official-system.sh "$@"
WRAP
chmod 0755 "${PKG}/usr/bin/grok-bot-linux-setup"

cat > "${PKG}/usr/share/doc/${PKG_NAME}/README.Debian" <<READMEEOF
grok-bot-linux ${VERSION}

This package installs the MIT-licensed helpers from
https://github.com/devrecated/grok-bot-linux. It does not contain Grok Bot
itself. After installing, run:

  sudo grok-bot-linux-setup

That command downloads Cursor's official Linux build, verifies it against
Cursor's signed package metadata, and installs it. Updates then arrive
through Cursor's own apt repository (or the AppImage updater).

This is an unofficial community project and is not affiliated with xAI or
Cursor.
READMEEOF

cat > "${PKG}/DEBIAN/control" <<CTRLEOF
Package: ${PKG_NAME}
Version: ${VERSION}
Section: misc
Priority: optional
Architecture: ${ARCH}
Maintainer: Adam Siwiec <73085927+adamsiwiec1@users.noreply.github.com>
Depends: curl, python3, ca-certificates, coreutils
Recommends: gpgv | gnupg, libfuse2 | libfuse2t64
Suggests: pkexec | sudo
Homepage: https://github.com/devrecated/grok-bot-linux
Description: Helper that installs Cursor's official Grok Bot on Linux
 Ships the MIT-licensed install scripts from grok-bot-linux. Run
 grok-bot-linux-setup after installing to download and verify Cursor's
 official .deb, .rpm, or AppImage. The package never redistributes
 xAI or Cursor binaries.
CTRLEOF

cat > "${PKG}/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
case "$1" in
  configure)
    cat <<'MSG'
grok-bot-linux: helper scripts installed.

This package does not contain Grok Bot. To download and verify Cursor's
official Linux build, run:

  sudo grok-bot-linux-setup

Or, for a specific format: sudo grok-bot-linux-setup --format appimage
MSG
    ;;
esac
exit 0
POSTINST
chmod 0755 "${PKG}/DEBIAN/postinst"

cat > "${PKG}/DEBIAN/prerm" <<'PRERM'
#!/bin/sh
set -e
# Intentionally leave any official grok-bot package or AppImage alone.
# Those were installed by Cursor's own packages / by the user's choice.
exit 0
PRERM
chmod 0755 "${PKG}/DEBIAN/prerm"

mkdir -p "$OUT"
DEB="${OUT}/${PKG_NAME}_${VERSION}_${ARCH}.deb"
if command -v fakeroot >/dev/null; then
  fakeroot dpkg-deb --build "$PKG" "$DEB" >/dev/null
else
  dpkg-deb --build "$PKG" "$DEB" >/dev/null
fi

# Sanity: the package must not contain anything from Cursor/xAI payloads.
if dpkg-deb -c "$DEB" | grep -Eiq 'app\.asar|Grok_Bot|chrome-sandbox|\.AppImage'; then
  echo "error: built .deb appears to contain proprietary app payloads" >&2
  dpkg-deb -c "$DEB" >&2
  exit 1
fi

echo "$DEB"
