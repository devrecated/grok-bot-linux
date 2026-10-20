#!/usr/bin/env bash
# Build the grok-bot-linux helper .rpm (scripts only; no xAI binaries).
#
# Usage: packaging/dnf/build-rpm.sh [output-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
OUT="${1:-${ROOT}/dist/linux-repos}"
VERSION="$(tr -d '[:space:]' < "${ROOT}/packaging/linux/VERSION")"
PKG_NAME=grok-bot-linux

command -v rpmbuild >/dev/null || { echo "error: rpmbuild is required" >&2; exit 1; }

WORK="$(mktemp -d -t grokbot-linux-rpm-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Stage the install root that %install will copy into buildroot.
STAGE="${WORK}/BUILD/root"
mkdir -p \
  "${STAGE}/usr/lib/${PKG_NAME}/scripts" \
  "${STAGE}/usr/lib/${PKG_NAME}/packaging/linux" \
  "${STAGE}/usr/bin" \
  "${STAGE}/usr/share/doc/${PKG_NAME}"

install -m 0755 "${ROOT}/scripts/install-official.sh" \
  "${STAGE}/usr/lib/${PKG_NAME}/scripts/install-official.sh"
install -m 0644 "${ROOT}/packaging/anysphere-release-key.asc" \
  "${STAGE}/usr/lib/${PKG_NAME}/packaging/anysphere-release-key.asc"
install -m 0755 "${ROOT}/packaging/linux/install-official-system.sh" \
  "${STAGE}/usr/lib/${PKG_NAME}/packaging/linux/install-official-system.sh"
install -m 0644 "${ROOT}/LICENSE" \
  "${STAGE}/usr/share/doc/${PKG_NAME}/copyright"
install -m 0644 "${ROOT}/packaging/linux/VERSION" \
  "${STAGE}/usr/lib/${PKG_NAME}/VERSION"

cat > "${STAGE}/usr/bin/grok-bot-linux-setup" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/lib/grok-bot-linux/packaging/linux/install-official-system.sh "$@"
WRAP
chmod 0755 "${STAGE}/usr/bin/grok-bot-linux-setup"

cat > "${STAGE}/usr/share/doc/${PKG_NAME}/README" <<READMEEOF
grok-bot-linux ${VERSION}

This package installs the MIT-licensed helpers from
https://github.com/devrecated/grok-bot-linux. It does not contain Grok Bot
itself. After installing, run:

  sudo grok-bot-linux-setup

That command downloads Cursor's official Linux build, verifies it against
Cursor's signed package metadata, and installs it.

This is an unofficial community project and is not affiliated with xAI or
Cursor.
READMEEOF

SPEC="${WORK}/SPECS/${PKG_NAME}.spec"
mkdir -p "${WORK}/SPECS" "${WORK}/RPMS" "${WORK}/SRPMS" "${WORK}/SOURCES"
sed "s/@VERSION@/${VERSION}/g" "${ROOT}/packaging/dnf/grok-bot-linux.spec.in" > "$SPEC"

rpmbuild \
  --define "_topdir ${WORK}" \
  --define "_rpmdir ${WORK}/RPMS" \
  --define "_srcrpmdir ${WORK}/SRPMS" \
  --define "_sourcedir ${WORK}/SOURCES" \
  --define "_specdir ${WORK}/SPECS" \
  --define "stagedir ${STAGE}" \
  --nodeps \
  -bb "$SPEC"

mkdir -p "$OUT"
# noarch lands under RPMS/noarch/
RPM_SRC="$(find "${WORK}/RPMS" -type f -name '*.rpm' | head -1)"
[[ -n "$RPM_SRC" ]] || { echo "error: rpmbuild produced no rpm" >&2; exit 1; }
RPM_DEST="${OUT}/${PKG_NAME}-${VERSION}-1.noarch.rpm"
cp -a "$RPM_SRC" "$RPM_DEST"

# Sanity: the package must not contain proprietary payloads.
# --dbpath avoids needing a system rpmdb when querying a package file.
if rpm --dbpath /tmp -qlp "$RPM_DEST" 2>/dev/null | grep -Eiq 'app\.asar|Grok_Bot|chrome-sandbox|\.AppImage'; then
  echo "error: built .rpm appears to contain proprietary app payloads" >&2
  rpm --dbpath /tmp -qlp "$RPM_DEST" >&2 || true
  exit 1
fi

echo "$RPM_DEST"
