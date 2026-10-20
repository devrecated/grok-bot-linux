#!/bin/bash
# Rebuild the official Grok Bot Mac app on an older Electron so it runs on
# macOS 11 (Big Sur), which the official build no longer supports.
#
#   scripts/build-macos.sh            # newest stable release
#   scripts/build-macos.sh X.Y.Z      # a specific release
#   scripts/build-macos.sh --install  # also copy the result to /Applications
#
# The official app.asar and its native addons are reused unchanged. They are
# N-API modules built for macOS 11 (arm64) or 10.13 (x86_64), so they load
# under Electron 37. Only the Electron runtime is swapped. The result is
# ad-hoc signed and written to dist/macos/Grok Bot.app.
#
# Needs Node.js 18+ and npm. If they are missing it installs them from
# MacPorts (https://www.macports.org/): sudo port install nodejs22 npm10.
# Everything else (curl, hdiutil, ditto, PlistBuddy, codesign, shasum)
# ships with macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${ROOT}/.cache/macos"
OUT="${ROOT}/dist/macos"
APP_NAME="Grok Bot"

# Electron 37 is the last line that supports macOS 11; 38+ needs macOS 12.
# https://www.electronjs.org/blog/electron-38-0#removed-macos-11-support
ELECTRON_VERSION="${ELECTRON_VERSION:-37.10.3}"
MIN_MACOS="11.0"
ASAR_VERSION="3.4.1"
# Anysphere's Developer ID team, which signs the official Mac app.
OFFICIAL_TEAM_ID="DCNK4UB866"
PORTS="nodejs22 npm10"

die() { echo "error: $*" >&2; exit 1; }
# plist_set FILE KEY VALUE: set a string key, adding it if it is missing.
plist_set() {
  /usr/libexec/PlistBuddy -c "Set :$2 $3" "$1" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add :$2 string $3" "$1" ||
    die "could not set $2 in $1"
}
step() { echo "==> $*"; }

INSTALL=0
VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) VERSION="$1" ;;
  esac
  shift
done

# ---- preflight --------------------------------------------------------------
[ "$(uname -s)" = Darwin ] || die "this script runs on macOS; on Linux use make build"

OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
if [ "$OS_MAJOR" = 10 ]; then
  die "macOS ${OS_VERSION} is too old. This rebuild targets macOS 11 (Big Sur).
Electron releases that still run on 10.15 (32.x and older) fail to start this
version of Grok Bot, so there is no working path for 10.x yet."
fi
if [ "$OS_MAJOR" -ge 12 ] 2>/dev/null; then
  echo "note: macOS ${OS_VERSION} runs the official app; this build is only needed on macOS 11."
fi

ARCH="$(uname -m)"
# A Rosetta shell on Apple silicon reports x86_64; build for the real CPU.
if [ "$ARCH" = x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
  ARCH=arm64
fi
case "$ARCH" in
  arm64) FEED_ARCH=darwin-arm64; EL_ARCH=darwin-arm64 ;;
  x86_64) FEED_ARCH=darwin-x64; EL_ARCH=darwin-x64 ;;
  *) die "unsupported CPU $ARCH" ;;
esac

node_ok() {
  command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 &&
    [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -ge 18 ]
}
[ -x /opt/local/bin/port ] && export PATH="/opt/local/bin:/opt/local/sbin:${PATH}"
if ! node_ok; then
  if [ ! -x /opt/local/bin/port ]; then
    die "Node.js 18+ and npm are needed, and MacPorts is not installed.
Install MacPorts for macOS ${OS_VERSION} from https://www.macports.org/install.php
(it needs the Xcode Command Line Tools: xcode-select --install), open a new
terminal, and run this again. It will then run: sudo port install ${PORTS}"
  fi
  step "installing MacPorts packages: ${PORTS} (asks for your password)"
  # shellcheck disable=SC2086
  sudo port -N install $PORTS || die "sudo port install ${PORTS} failed"
  hash -r
  node_ok || die "node/npm still not usable after installing ${PORTS}"
fi
echo "Using Node.js $(node -v) from $(command -v node)"
for tool in curl hdiutil ditto codesign shasum file /usr/libexec/PlistBuddy; do
  command -v "$tool" >/dev/null 2>&1 || die "missing $tool"
done

mkdir -p "$CACHE" "$OUT"

# ---- official app -----------------------------------------------------------
FEED="https://api2.cursor.sh/updates/api/download/stable/${FEED_ARCH}/sand"
step "reading ${FEED}"
FEED_JSON="$(curl -fsSL "$FEED")" || die "could not reach Cursor's download feed"
DMG_URL="$(printf '%s' "$FEED_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).downloadUrl||""))')"
LATEST="$(printf '%s' "$FEED_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).version||""))')"
[ -n "$DMG_URL" ] && [ -n "$LATEST" ] || die "unexpected feed response: $FEED_JSON"
if [ -n "$VERSION" ] && [ "$VERSION" != "$LATEST" ]; then
  DMG_URL="${DMG_URL//\/${LATEST}\//\/${VERSION}\/}"
  DMG_URL="${DMG_URL//_${LATEST}/_${VERSION}}"
fi
VERSION="${VERSION:-$LATEST}"
echo "Grok Bot ${VERSION} (${ARCH}) on Electron ${ELECTRON_VERSION}, minimum macOS ${MIN_MACOS}"

DMG="${CACHE}/Grok_Bot_${VERSION}_${ARCH}.dmg"
if [ ! -s "$DMG" ]; then
  step "downloading ${DMG_URL}"
  curl -fL --progress-bar -o "${DMG}.part" "$DMG_URL" || die "download failed: $DMG_URL"
  mv "${DMG}.part" "$DMG"
fi

OFFICIAL="${CACHE}/official-${VERSION}-${ARCH}.app"
if [ ! -d "$OFFICIAL" ]; then
  step "extracting the official app"
  MNT="$(mktemp -d /tmp/grokbot-dmg.XXXXXX)"
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null ||
    { rm -f "$DMG"; die "could not open $DMG (deleted; rerun to download again)"; }
  ditto "${MNT}/${APP_NAME}.app" "${OFFICIAL}.part" || { hdiutil detach -quiet "$MNT"; die "copy failed"; }
  hdiutil detach -quiet "$MNT" || true
  mv "${OFFICIAL}.part" "$OFFICIAL"
fi

# The official signature is checked so a tampered download is never reused.
step "verifying the official app's signature"
codesign --verify --deep --strict "$OFFICIAL" 2>/dev/null ||
  { rm -rf "$OFFICIAL" "$DMG"; die "official app signature is invalid (download deleted)"; }
TEAM="$(codesign -dv "$OFFICIAL" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ "$TEAM" = "$OFFICIAL_TEAM_ID" ] ||
  { rm -rf "$OFFICIAL" "$DMG"; die "official app is signed by team '$TEAM', expected $OFFICIAL_TEAM_ID"; }

# ---- Electron ---------------------------------------------------------------
EL_ZIP="${CACHE}/electron-v${ELECTRON_VERSION}-${EL_ARCH}.zip"
EL_SUMS="${CACHE}/SHASUMS256-${ELECTRON_VERSION}.txt"
EL_BASE="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}"
[ -s "$EL_SUMS" ] || curl -fsSL -o "$EL_SUMS" "${EL_BASE}/SHASUMS256.txt" || die "could not download Electron checksums"
if [ ! -s "$EL_ZIP" ]; then
  step "downloading Electron ${ELECTRON_VERSION} (${EL_ARCH})"
  curl -fL --progress-bar -o "${EL_ZIP}.part" "${EL_BASE}/$(basename "$EL_ZIP")" || die "Electron download failed"
  mv "${EL_ZIP}.part" "$EL_ZIP"
fi
want="$(grep " \*$(basename "$EL_ZIP")\$" "$EL_SUMS" | cut -d' ' -f1)"
got="$(shasum -a 256 "$EL_ZIP" | cut -d' ' -f1)"
[ -n "$want" ] && [ "$want" = "$got" ] || { rm -f "$EL_ZIP"; die "Electron zip checksum mismatch (deleted; rerun)"; }

# ---- assemble ---------------------------------------------------------------
APP="${OUT}/${APP_NAME}.app"
step "assembling ${APP}"
rm -rf "$APP" "${OUT}/electron"
ditto -x -k "$EL_ZIP" "${OUT}/electron"
mv "${OUT}/electron/Electron.app" "$APP"
rm -rf "${OUT}/electron"

C="${APP}/Contents"
PB=/usr/libexec/PlistBuddy
mv "${C}/MacOS/Electron" "${C}/MacOS/${APP_NAME}"

# Helpers must be named after the main executable or Electron cannot find them.
for helper in "${C}/Frameworks/Electron Helper"*.app; do
  old="$(basename "$helper" .app)"
  new="${APP_NAME}${old#Electron}"
  mv "${helper}/Contents/MacOS/${old}" "${helper}/Contents/MacOS/${new}"
  suffix="$($PB -c 'Print :CFBundleIdentifier' "${helper}/Contents/Info.plist")"
  suffix="${suffix#com.github.Electron}"
  plist_set "${helper}/Contents/Info.plist" CFBundleExecutable "$new"
  plist_set "${helper}/Contents/Info.plist" CFBundleName "$new"
  plist_set "${helper}/Contents/Info.plist" CFBundleIdentifier "com.anysphere.sand${suffix}"
  $PB -c "Delete :CFBundleDisplayName" "${helper}/Contents/Info.plist" 2>/dev/null || true
  mv "$helper" "${C}/Frameworks/${new}.app"
done

# The official Info.plist carries the bundle id, URL schemes (grokbot://,
# sand://) and privacy strings. Lower the minimum OS, drop the asar hash that
# no longer matches, and keep updates off for Finder/Dock launches as well.
cp "${OFFICIAL}/Contents/Info.plist" "${C}/Info.plist"
plist_set "${C}/Info.plist" LSMinimumSystemVersion "$MIN_MACOS"
$PB -c "Delete :ElectronAsarIntegrity" "${C}/Info.plist" 2>/dev/null || true
$PB -c "Delete :CFBundleIconName" "${C}/Info.plist" 2>/dev/null || true
$PB -c "Add :LSEnvironment dict" "${C}/Info.plist" 2>/dev/null || true
plist_set "${C}/Info.plist" LSEnvironment:SAND_DISABLE_UPDATES 1

R="${C}/Resources"
rm -f "${R}/default_app.asar" "${R}/electron.icns"
cp "${OFFICIAL}/Contents/Resources/icon.icns" "${R}/icon.icns"
if [ -d "${OFFICIAL}/Contents/Helpers" ]; then
  ditto "${OFFICIAL}/Contents/Helpers" "${C}/Helpers"
fi

ASAR_MOD="${CACHE}/asar-${ASAR_VERSION}/node_modules/@electron/asar"
if [ ! -f "${ASAR_MOD}/package.json" ]; then
  step "installing @electron/asar ${ASAR_VERSION}"
  npm install --silent --no-audit --no-fund --ignore-scripts \
    --prefix "${CACHE}/asar-${ASAR_VERSION}" "@electron/asar@${ASAR_VERSION}" >/dev/null ||
    die "npm install @electron/asar failed"
fi
node "${ROOT}/scripts/macos-asar.cjs" "$ASAR_MOD" \
  "${OFFICIAL}/Contents/Resources/app.asar" "${R}/app.asar" "${ROOT}/packaging/macos-entry.cjs"
# Use the official unpacked tree as-is so modes and signatures are untouched.
rm -rf "${R}/app.asar.unpacked"
ditto "${OFFICIAL}/Contents/Resources/app.asar.unpacked" "${R}/app.asar.unpacked"

# Report native code that asks for a newer macOS than this build targets.
# Those pieces fail to load on macOS 11 even though the app itself starts.
step "checking native code minimum macOS versions"
target_major="${MIN_MACOS%%.*}"
while IFS= read -r -d '' f; do
  command -v otool >/dev/null 2>&1 || break
  file -b "$f" | grep -q Mach-O || continue
  for minos in $(otool -l "$f" 2>/dev/null | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; b=0} /LC_VERSION_MIN_MACOSX/{v=1} v&&/version/{print $2; v=0}' | sort -u); do
    if [ "${minos%%.*}" -gt "$target_major" ] 2>/dev/null; then
      echo "  warning: ${f#"${C}"/} needs macOS ${minos}"
    fi
  done
done < <(find "${R}/app.asar.unpacked" "${C}/Helpers" -type f -print0 2>/dev/null)

# ---- sign -------------------------------------------------------------------
# Ad-hoc signature, inside out: Electron's frameworks, the renamed helpers,
# then the bundle. Apple silicon refuses to run code with a broken
# signature. The official binaries in app.asar.unpacked and Contents/Helpers
# are not re-signed and keep Anysphere's signatures.
step "ad-hoc signing"
xattr -cr "$APP"
for fw in "${C}/Frameworks/"*.framework; do
  codesign --force --deep --sign - "$fw" 2>/dev/null || die "codesign failed: $fw"
done
for helper in "${C}/Frameworks/${APP_NAME} Helper"*.app; do
  codesign --force --sign - "$helper" 2>/dev/null || die "codesign failed: $helper"
done
codesign --force --sign - "$APP" 2>/dev/null || die "codesign failed: $APP"
codesign --verify --deep --strict "$APP" || die "signature check failed"

echo
echo "Built ${APP}"
if [ "$INSTALL" = 1 ]; then
  step "installing to /Applications"
  if [ -d "/Applications/${APP_NAME}.app" ]; then
    rm -rf "/Applications/${APP_NAME}.app" 2>/dev/null || sudo rm -rf "/Applications/${APP_NAME}.app"
  fi
  ditto "$APP" "/Applications/${APP_NAME}.app" 2>/dev/null || sudo ditto "$APP" "/Applications/${APP_NAME}.app"
  echo "Installed /Applications/${APP_NAME}.app"
else
  echo "Run it with:  open \"${APP}\""
  echo "Install with: make mac-install"
fi
