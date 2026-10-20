#!/usr/bin/env bash
# Rebuild the official Grok Bot Windows installer as a native Linux app.
#
# Usage:
#   scripts/build.sh                     # latest CDN version, every format this host can build
#   scripts/build.sh --formats tar       # only the runnable tree + tarball (any distro)
#   scripts/build.sh --deb-only          # same as --formats deb
#   scripts/build.sh X.Y.Z
#   scripts/build.sh --exe /path/to/Grok_Bot_X.Y.Z_Setup.exe
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${ROOT}/dist"
CACHE="${ROOT}/.cache"
# Electron is read from the Windows payload unless ELECTRON_VERSION is set.
ELECTRON_OVERRIDE="${ELECTRON_VERSION:-}"
NODE_API_HEADERS_VERSION="1.9.0"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--formats LIST] [--deb-only] [--exe /path/to/Grok_Bot_X.Y.Z_Setup.exe] [X.Y.Z]

Downloads the official Windows installer (or uses --exe), extracts the
Electron app without Wine, fuses it with the matching Electron for Linux,
replaces Windows native addons, and writes some of:

  dist/Grok_Bot_<ver>_linux_x64/          runnable tree (always)
  dist/Grok_Bot_<ver>_linux_x64.tar.gz    format "tar"
  dist/grok-bot_<ver>_amd64.deb           format "deb" (needs dpkg-deb)
  dist/Grok_Bot_<ver>_x86_64.AppImage     format "appimage" (needs mksquashfs, file)

--formats takes a comma-separated list of tar, deb, appimage. Without it,
every format this machine has the tools for is built, and the others are
skipped with a note. A format you ask for explicitly must succeed.
--deb-only is the same as --formats deb and skips the runnable tree in dist/.

Environment:
  ELECTRON_VERSION      use this Electron instead of the one in the payload
  GROKBOT_NODE_INCLUDE  directory containing node_api.h
EOF
}

EXE=""
VERSION=""
FORMATS=""
DEB_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deb-only) DEB_ONLY=1; FORMATS="deb"; shift ;;
    --formats) FORMATS="${2:?--formats needs a list such as tar,deb,appimage}"; shift 2 ;;
    --formats=*) FORMATS="${1#*=}"; shift ;;
    --exe) EXE="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option $1" >&2; usage >&2; exit 1 ;;
    *) VERSION="$1"; shift ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

# Print an install hint for the host's package manager.
hint() {
  local apt="$1" dnf="$2" pacman="$3"
  if command -v apt-get >/dev/null; then echo "  sudo apt install ${apt}"
  elif command -v dnf >/dev/null; then echo "  sudo dnf install ${dnf}"
  elif command -v pacman >/dev/null; then echo "  sudo pacman -S ${pacman}"
  elif command -v zypper >/dev/null; then echo "  sudo zypper install ${dnf}"
  fi
}

# --- preflight: everything is checked before the ~110 MB download ----------
missing=0
need() {
  local cmd="$1"; shift
  if ! command -v "$cmd" >/dev/null; then
    echo "missing required command: ${cmd}" >&2
    hint "$@" >&2
    missing=1
  fi
}
need curl curl curl curl
need unzip unzip unzip unzip
need node nodejs nodejs nodejs
need npm npm npm npm
need npx npm npm npm
need gcc build-essential gcc gcc
need g++ build-essential gcc-c++ gcc
need python3 python3 python3 python3
if ! command -v 7z >/dev/null && ! command -v 7za >/dev/null; then
  echo "missing required command: 7z" >&2
  hint p7zip-full p7zip-plugins 7zip >&2
  missing=1
fi
[[ "$missing" -eq 0 ]] || exit 1
SEVEN_ZIP="7z"
command -v 7z >/dev/null || SEVEN_ZIP="7za"

can_build() {
  case "$1" in
    tar) return 0 ;;
    deb) command -v dpkg-deb >/dev/null ;;
    appimage) command -v mksquashfs >/dev/null && command -v file >/dev/null ;;
    *) return 1 ;;
  esac
}
explain() {
  case "$1" in
    deb) echo "deb needs dpkg-deb"; hint dpkg-dev dpkg dpkg ;;
    appimage) echo "appimage needs mksquashfs and file"; hint "squashfs-tools file" "squashfs-tools file" "squashfs-tools file" ;;
  esac
}

declare -A WANT=()
EXPLICIT=0
if [[ -n "$FORMATS" ]]; then
  EXPLICIT=1
  IFS=',' read -r -a requested <<<"$FORMATS"
  for f in "${requested[@]}"; do
    case "$f" in
      tar|deb|appimage) ;;
      *) die "unknown format '${f}' (use tar, deb, appimage)" ;;
    esac
    if ! can_build "$f"; then
      explain "$f" >&2
      die "cannot build requested format: ${f}"
    fi
    WANT[$f]=1
  done
else
  for f in tar deb appimage; do
    if can_build "$f"; then
      WANT[$f]=1
    else
      echo "note: skipping ${f}: $(explain "$f" | head -1)" >&2
    fi
  done
fi
want() { [[ -n "${WANT[$1]:-}" ]]; }

# node_api.h: explicit path, the running node's own headers, nvm, system
# headers, and finally the header-only node-api-headers package from npm
# (distro nodejs packages usually ship without headers).
find_node_include() {
  local cand node_bin
  if [[ -n "${GROKBOT_NODE_INCLUDE:-}" && -f "${GROKBOT_NODE_INCLUDE}/node_api.h" ]]; then
    printf '%s\n' "$GROKBOT_NODE_INCLUDE"
    return 0
  fi
  node_bin="$(readlink -f "$(command -v node)")"
  cand="$(dirname "$(dirname "$node_bin")")/include/node"
  if [[ -f "${cand}/node_api.h" ]]; then
    printf '%s\n' "$cand"
    return 0
  fi
  cand="$(dirname "$(find "${HOME}/.nvm/versions/node" /usr/include /usr/local/include \
    -name node_api.h 2>/dev/null | sort | tail -1)")"
  if [[ -f "${cand}/node_api.h" ]]; then
    printf '%s\n' "$cand"
    return 0
  fi
  cand="${CACHE}/node-api-headers-${NODE_API_HEADERS_VERSION}/package/include"
  if [[ ! -f "${cand}/node_api.h" ]]; then
    local tmp
    tmp="$(mktemp -d)"
    ( cd "$tmp" && npm pack --silent "node-api-headers@${NODE_API_HEADERS_VERSION}" >/dev/null ) || { rm -rf "$tmp"; return 1; }
    mkdir -p "${CACHE}/node-api-headers-${NODE_API_HEADERS_VERSION}"
    tar -xzf "$tmp"/node-api-headers-*.tgz -C "${CACHE}/node-api-headers-${NODE_API_HEADERS_VERSION}"
    rm -rf "$tmp"
  fi
  if [[ -f "${cand}/node_api.h" ]]; then
    printf '%s\n' "$cand"
    return 0
  fi
  return 1
}

mkdir -p "$CACHE"
NODE_INCLUDE="$(find_node_include)" ||
  die "node_api.h not found and node-api-headers could not be fetched; set GROKBOT_NODE_INCLUDE"
export GROKBOT_NODE_INCLUDE="$NODE_INCLUDE"

# --- installer -----------------------------------------------------------------
if [[ -n "$EXE" ]]; then
  EXE="$(readlink -f "$EXE")"
  [[ -f "$EXE" ]] || die "not found: $EXE"
  if [[ -z "$VERSION" && "$EXE" =~ Grok_Bot_([0-9]+\.[0-9]+\.[0-9]+)_Setup\.exe$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
  fi
  [[ -n "$VERSION" ]] || die "cannot tell the version from $(basename "$EXE"); pass it as X.Y.Z"
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$("${ROOT}/scripts/detect-version.sh")"
fi

if [[ -z "$EXE" ]]; then
  EXE="${CACHE}/Grok_Bot_${VERSION}_Setup.exe"
  if [[ ! -f "$EXE" ]]; then
    url="https://downloads.cursor.com/grokbot/stable/win32-x64/${VERSION}/Grok_Bot_${VERSION}_Setup.exe"
    echo "Downloading ${url}"
    curl -fL --retry 3 -A 'Mozilla/5.0' -o "${EXE}.partial" "$url"
    mv "${EXE}.partial" "$EXE"
  fi
fi

WORKDIR="$(mktemp -d -t grokbot-build-XXXXXX)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

NSIS="${WORKDIR}/nsis"
APP="${WORKDIR}/winapp"
mkdir -p "$NSIS" "$APP"
( cd "$NSIS" && "$SEVEN_ZIP" x -y "$EXE" >/dev/null )
PAYLOAD="$(find "$NSIS" -type f \( -name 'app-64.7z' -o -name 'app-32.7z' \) | head -1)"
[[ -n "$PAYLOAD" ]] || die "app-64.7z missing from NSIS payload"
"$SEVEN_ZIP" x -y "$PAYLOAD" -o"$APP" >/dev/null
ASAR="${APP}/resources/app.asar"
if [[ ! -f "$ASAR" && -f "${APP}/app.asar" ]]; then
  mkdir -p "${APP}/resources"
  mv "${APP}/app.asar" "$ASAR"
  [[ -d "${APP}/app.asar.unpacked" ]] && mv "${APP}/app.asar.unpacked" "${APP}/resources/app.asar.unpacked"
fi
[[ -f "$ASAR" ]] || die "resources/app.asar missing"

# The Windows executable embeds its Electron version in the user agent string.
PAYLOAD_ELECTRON=""
WIN_EXE="$(find "$APP" -maxdepth 1 -iname '*.exe' ! -iname 'uninstall*' ! -iname 'elevate*' | head -1)"
if [[ -n "$WIN_EXE" ]]; then
  PAYLOAD_ELECTRON="$(grep -aoE 'Electron/[0-9]+\.[0-9]+\.[0-9]+' "$WIN_EXE" | head -1 | cut -d/ -f2 || true)"
fi
if [[ -n "$ELECTRON_OVERRIDE" ]]; then
  ELECTRON_VERSION="$ELECTRON_OVERRIDE"
  if [[ -n "$PAYLOAD_ELECTRON" && "$PAYLOAD_ELECTRON" != "$ELECTRON_VERSION" ]]; then
    echo "warn: payload was built for Electron ${PAYLOAD_ELECTRON}; using ELECTRON_VERSION=${ELECTRON_VERSION}" >&2
  fi
elif [[ -n "$PAYLOAD_ELECTRON" ]]; then
  ELECTRON_VERSION="$PAYLOAD_ELECTRON"
else
  die "could not read the Electron version from the payload; set ELECTRON_VERSION"
fi

echo "Windows installer : $EXE"
echo "Grok Bot version  : $VERSION"
echo "Electron          : $ELECTRON_VERSION"
echo "node_api.h        : $NODE_INCLUDE"
echo "Formats           : $(printf '%s ' "${!WANT[@]}")"
echo "Workdir           : $WORKDIR"

EL_ZIP="${CACHE}/electron-v${ELECTRON_VERSION}-linux-x64.zip"
mkdir -p "$CACHE"
if [[ ! -f "$EL_ZIP" ]]; then
  curl -fL --retry 3 -o "${EL_ZIP}.partial" \
    "https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-x64.zip"
  mv "${EL_ZIP}.partial" "$EL_ZIP"
fi
EL="${WORKDIR}/electron"
mkdir -p "$EL"
unzip -q "$EL_ZIP" -d "$EL"

STAGE="${WORKDIR}/Grok_Bot_${VERSION}_linux_x64"
mkdir -p "${STAGE}/resources"
cp "$EL/electron" "${STAGE}/grok-bot"
chmod 755 "${STAGE}/grok-bot"
for f in chrome-sandbox chrome_crashpad_handler libEGL.so libGLESv2.so libffmpeg.so \
         libvk_swiftshader.so libvulkan.so.1 vk_swiftshader_icd.json \
         icudtl.dat snapshot_blob.bin v8_context_snapshot.bin \
         chrome_100_percent.pak chrome_200_percent.pak resources.pak \
         LICENSE.electron.txt LICENSES.chromium.html; do
  [[ -e "$EL/$f" ]] && cp -a "$EL/$f" "$STAGE/"
done
[[ -d "$EL/locales" ]] && cp -a "$EL/locales" "$STAGE/"
chmod 755 "${STAGE}/chrome_crashpad_handler" 2>/dev/null || true
chmod 4755 "${STAGE}/chrome-sandbox" 2>/dev/null || chmod 755 "${STAGE}/chrome-sandbox"

cp -a "$ASAR" "${STAGE}/resources/app.asar"
if [[ -d "${APP}/resources/app.asar.unpacked" ]]; then
  cp -a "${APP}/resources/app.asar.unpacked" "${STAGE}/resources/"
fi
find "${STAGE}/resources" -type d -exec chmod 755 {} +
find "${STAGE}/resources" -type f -exec chmod 644 {} +
find "${STAGE}" -type f \( -name '*.node' -o -name '*.so' -o -name '*.so.*' \) -exec chmod 755 {} +

ASAR_TMP="${WORKDIR}/asar-unpacked"
npx --yes @electron/asar extract "${STAGE}/resources/app.asar" "$ASAR_TMP"

export GROKBOT_UNPACKED="${STAGE}/resources/app.asar.unpacked"
python3 "${ROOT}/scripts/fix-natives.py"

python3 - "$ASAR_TMP" "${ROOT}/packaging/linux-entry.cjs" <<'PY'
import json, shutil, sys
from pathlib import Path
asar = Path(sys.argv[1])
wrapper = Path(sys.argv[2])
pkg_path = asar / "package.json"
pkg = json.loads(pkg_path.read_text())
pkg["desktopName"] = "grok-bot.desktop"
pkg["main"] = "linux-entry.cjs"
pkg_path.write_text(json.dumps(pkg, indent=2) + "\n")
shutil.copy2(wrapper, asar / "linux-entry.cjs")
print("desktop identity: main=linux-entry.cjs")
PY

if [[ -d "${STAGE}/resources/app.asar.unpacked/dist/deps" ]]; then
  rm -rf "${ASAR_TMP}/dist/deps"
  mkdir -p "${ASAR_TMP}/dist"
  cp -a "${STAGE}/resources/app.asar.unpacked/dist/deps" "${ASAR_TMP}/dist/deps"
fi
npx --yes @electron/asar pack "$ASAR_TMP" "${STAGE}/resources/app.asar"

ICON="$(find "$ASAR_TMP" "${STAGE}/resources" -name 'app-icon*.png' 2>/dev/null | head -1 || true)"
if [[ -n "${ICON}" && -f "$ICON" ]]; then
  cp "$ICON" "${STAGE}/grok-bot.png"
  # The main process loads resources/icon.png for the window, tray and
  # notifications on Linux; the Windows payload uses an .ico instead.
  cp "$ICON" "${STAGE}/resources/icon.png"
fi

find "${STAGE}" -type d -exec chmod 755 {} +
find "${STAGE}" -type f -exec chmod 644 {} +
chmod 755 "${STAGE}/grok-bot"
[[ -f "${STAGE}/chrome-sandbox" ]] && chmod 4755 "${STAGE}/chrome-sandbox" || true
[[ -f "${STAGE}/chrome_crashpad_handler" ]] && chmod 755 "${STAGE}/chrome_crashpad_handler"
find "${STAGE}" -type f \( -name '*.node' -o -name '*.so' -o -name '*.so.*' \) -exec chmod 755 {} +

FAILED=0
mkdir -p "$DIST"
if [[ "$DEB_ONLY" -eq 1 ]]; then
  "${ROOT}/scripts/package-deb.sh" "$STAGE" "$VERSION" "$DIST"
else
  rm -rf "${DIST}/Grok_Bot_${VERSION}_linux_x64"
  cp -a "$STAGE" "${DIST}/Grok_Bot_${VERSION}_linux_x64"
  echo "tree ${DIST}/Grok_Bot_${VERSION}_linux_x64"

  if want tar; then
    TARBALL="${DIST}/Grok_Bot_${VERSION}_linux_x64.tar.gz"
    tar -C "$DIST" -czf "$TARBALL" "Grok_Bot_${VERSION}_linux_x64"
    echo "tarball $TARBALL"
  fi

  if want deb; then
    "${ROOT}/scripts/package-deb.sh" \
      "${DIST}/Grok_Bot_${VERSION}_linux_x64" "$VERSION" "$DIST"
  fi
fi

if want appimage; then
  APPDIR="${WORKDIR}/AppDir"
  mkdir -p "${APPDIR}/usr/bin" "${APPDIR}/usr/share/applications"
  cp -a "${STAGE}/." "${APPDIR}/usr/bin/"
  if [[ -f "${STAGE}/grok-bot.png" ]]; then
    cp "${STAGE}/grok-bot.png" "${APPDIR}/grok-bot.png"
    cp "${STAGE}/grok-bot.png" "${APPDIR}/.DirIcon"
    for size in 16 22 24 32 48 64 128 256; do
      mkdir -p "${APPDIR}/usr/share/icons/hicolor/${size}x${size}/apps"
      cp "${STAGE}/grok-bot.png" "${APPDIR}/usr/share/icons/hicolor/${size}x${size}/apps/grok-bot.png"
    done
  fi
  cat > "${APPDIR}/grok-bot.desktop" <<EOF
[Desktop Entry]
Name=Grok Bot
Comment=Grok Bot (unofficial Linux build)
Exec=grok-bot --no-sandbox --class=grok-bot
Icon=grok-bot
Type=Application
Categories=Network;
Terminal=false
StartupNotify=true
StartupWMClass=grok-bot
X-AppImage-Version=${VERSION}
EOF
  cp "${APPDIR}/grok-bot.desktop" "${APPDIR}/usr/share/applications/"
  install -m 0755 "${ROOT}/packaging/AppRun" "${APPDIR}/AppRun"

  TOOL="${CACHE}/appimagetool"
  if [[ ! -x "$TOOL" ]]; then
    curl -fL --retry 3 -o "$TOOL" \
      "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$TOOL"
  fi
  APPIMAGE="${DIST}/Grok_Bot_${VERSION}_x86_64.AppImage"
  if ARCH=x86_64 "$TOOL" --appimage-extract-and-run "$APPDIR" "$APPIMAGE"; then
    chmod +x "$APPIMAGE"
    echo "appimage $APPIMAGE"
  elif [[ "$EXPLICIT" -eq 1 ]]; then
    die "AppImage step failed"
  else
    echo "warn: AppImage step failed; the other formats are still in dist/" >&2
    FAILED=1
  fi
fi

echo "done ${VERSION}"
ls -lh "$DIST"
exit "$FAILED"
