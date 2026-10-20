#!/usr/bin/env bash
# Build the apt + dnf repository tree for GitHub Pages
# (devrecated.github.io/grok-bot-linux).
#
# Usage:
#   packaging/repo/build-pages-repos.sh [pkg-dir] [out-dir]
#
# pkg-dir defaults to dist/linux-repos (built .deb/.rpm).
# out-dir defaults to dist/gh-pages.
#
# Env:
#   REPO_URL   Base URL (default https://devrecated.github.io/grok-bot-linux)
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
PKG_DIR="$(cd "${1:-${ROOT}/dist/linux-repos}" && pwd)"
OUT_RAW="${2:-${ROOT}/dist/gh-pages}"
REPO_URL="${REPO_URL:-https://devrecated.github.io/grok-bot-linux}"
PRODUCT=grok-bot-linux

mkdir -p "$OUT_RAW"
OUT="$(cd "$OUT_RAW" && pwd)"

rm -rf "$OUT/deb" "$OUT/rpm"
mkdir -p \
  "$OUT/deb/pool/main" \
  "$OUT/deb/dists/stable/main/binary-amd64" \
  "$OUT/deb/dists/stable/main/binary-arm64" \
  "$OUT/deb/dists/stable/main/binary-all" \
  "$OUT/rpm"

shopt -s nullglob
debs=("$PKG_DIR"/*.deb)
if ((${#debs[@]})); then
  cp -a "${debs[@]}" "$OUT/deb/pool/main/"
fi

build_apt_meta() {
  pushd "$OUT/deb" >/dev/null
  # Index Architecture: all packages into binary-all, and also list them
  # under amd64/arm64 so apt on those arches finds them without a
  # separate [arch=all] stanza.
  for arch in all amd64 arm64; do
    mkdir -p "dists/stable/main/binary-${arch}"
    if [ "$arch" = all ]; then
      apt-ftparchive packages pool/main > "dists/stable/main/binary-${arch}/Packages"
    else
      # Include arch:all packages for each concrete arch.
      apt-ftparchive --arch "$arch" packages pool/main > "dists/stable/main/binary-${arch}/Packages" || true
      # Merge in Architecture: all stanzas if apt-ftparchive --arch skipped them.
      if ! grep -q '^Package: ' "dists/stable/main/binary-${arch}/Packages" 2>/dev/null; then
        apt-ftparchive packages pool/main > "dists/stable/main/binary-${arch}/Packages"
      fi
    fi
    gzip -9fk "dists/stable/main/binary-${arch}/Packages"
  done
  apt-ftparchive release dists/stable > dists/stable/Release
  popd >/dev/null
}

if ((${#debs[@]})); then
  if command -v apt-ftparchive >/dev/null 2>&1; then
    build_apt_meta
  else
    echo "error: apt-ftparchive is required to build the apt index" >&2
    exit 1
  fi
fi

rpms=("$PKG_DIR"/*.rpm)
if ((${#rpms[@]})); then
  cp -a "${rpms[@]}" "$OUT/rpm/"
fi

if ((${#rpms[@]})); then
  if command -v createrepo_c >/dev/null 2>&1; then
    createrepo_c "$OUT/rpm"
  else
    echo "error: createrepo_c is required to build the dnf index" >&2
    exit 1
  fi
fi

REPO_TMPL="${ROOT}/packaging/repo"
sed "s#@REPO_URL@#${REPO_URL}#g" "${REPO_TMPL}/grok-bot-linux.list.in" > "$OUT/${PRODUCT}.list"
sed "s#@REPO_URL@#${REPO_URL}#g" "${REPO_TMPL}/grok-bot-linux.repo.in" > "$OUT/${PRODUCT}.repo"
sed "s#@REPO_URL@#${REPO_URL}#g" "${REPO_TMPL}/install-apt.sh" > "$OUT/install-apt.sh"
sed "s#@REPO_URL@#${REPO_URL}#g" "${REPO_TMPL}/install-dnf.sh" > "$OUT/install-dnf.sh"
sed "s#@REPO_URL@#${REPO_URL}#g" "${REPO_TMPL}/index.html.in" > "$OUT/index.html"
chmod +x "$OUT/install-apt.sh" "$OUT/install-dnf.sh"
touch "$OUT/.nojekyll"

echo "OK pages tree → $OUT"
find "$OUT" -type f | sort
