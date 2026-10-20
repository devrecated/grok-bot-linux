#!/usr/bin/env bash
# Install Cursor's official Linux build of Grok Bot (.deb, .rpm or AppImage)
# after verifying it against Cursor's signed package metadata.
#
# Usage:
#   scripts/install-official.sh                    # pick the format for this distro
#   scripts/install-official.sh --format appimage  # deb | rpm | appimage
#   scripts/install-official.sh --check            # show installed vs available
#   scripts/install-official.sh --download-only DIR
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
KEY_FILE="${ROOT}/packaging/anysphere-release-key.asc"
# Anysphere Inc <security@anysphere.co>; the same key the official .deb and
# .rpm install for their apt and dnf repositories.
KEY_FPR="380FF4BCDC34A4BD92A3565342A1772E62E492D6"
APT_REPO="https://downloads.cursor.com/aptrepo"
YUM_REPO="https://downloads.cursor.com/yumrepo/grok-bot"
UNOFFICIAL_MAINTAINER="grok-bot-linux contributors"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--format deb|rpm|appimage] [--check] [--download-only DIR]

Downloads the current official Grok Bot Linux build from Cursor, verifies it,
and installs it. The .deb is checked against the GPG-signed apt repository
index, the .rpm against the GPG-signed dnf repository metadata, and the
AppImage against the SHA-256 published by Cursor's update service.

If this repository's unofficial grok-bot .deb is installed, it is replaced by
the official package. Your sign-in and settings in ~/.config/Grok Bot are kept.
USAGE
}

FORMAT=auto
CHECK_ONLY=0
DOWNLOAD_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format) FORMAT="${2:?--format needs deb, rpm or appimage}"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --download-only) DOWNLOAD_DIR="${2:?--download-only needs a directory}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

for cmd in curl python3 sha256sum; do
  command -v "$cmd" >/dev/null || die "missing required command: $cmd"
done
if command -v gpgv >/dev/null; then
  GPG_TOOL=gpgv
elif command -v gpg >/dev/null; then
  GPG_TOOL=gpg
else
  die "missing gpgv or gpg (package gpgv / gnupg2) to check Cursor's signatures"
fi

case "$(uname -m)" in
  x86_64|amd64) FEED_ARCH=linux-x64; DEB_ARCH=amd64; RPM_ARCH=x86_64 ;;
  aarch64|arm64) FEED_ARCH=linux-arm64; DEB_ARCH=arm64; RPM_ARCH=aarch64 ;;
  *) die "official builds exist for x86_64 and aarch64 only, not $(uname -m)" ;;
esac

if [[ "$FORMAT" == auto ]]; then
  if command -v dpkg >/dev/null && command -v apt-get >/dev/null; then
    FORMAT=deb
  elif command -v rpm >/dev/null && { command -v dnf >/dev/null || command -v zypper >/dev/null; }; then
    FORMAT=rpm
  else
    FORMAT=appimage
  fi
fi
case "$FORMAT" in deb|rpm|appimage) ;; *) die "unknown format: $FORMAT" ;; esac

WORK="$(mktemp -d -t grokbot-official-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
chmod 0755 "$WORK"

fetch() {
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 10 -o "$2" "$1"
}

# --- release feed -----------------------------------------------------------
fetch "https://api2.cursor.sh/updates/api/download/stable/${FEED_ARCH}/sand" "$WORK/feed.json"
read -r VERSION DEB_URL _RPM_URL APPIMAGE_URL < <(python3 - "$WORK/feed.json" <<'PY'
import json, re, sys
from urllib.parse import urlparse
feed = json.load(open(sys.argv[1]))
version = feed.get("version", "")
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    sys.exit("error: release feed has an invalid version")
urls = []
for key in ("debUrl", "rpmUrl", "downloadUrl"):
    url = feed.get(key) or ""
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname != "downloads.cursor.com" \
            or not parsed.path.startswith("/grokbot/stable/") or parsed.query:
        sys.exit(f"error: release feed {key} is not an official download URL")
    urls.append(url)
print(version, *urls)
PY
)
[[ -n "${VERSION:-}" && -n "${APPIMAGE_URL:-}" ]] || die "could not read the official release feed"

installed_version() {
  if command -v dpkg-query >/dev/null; then
    dpkg-query -W -f='${db:Status-Abbrev} ${Version} ${Maintainer}\n' grok-bot 2>/dev/null |
      awk '$1 ~ /^ii/ { $1 = ""; sub(/^ /, ""); print; exit }'
  elif command -v rpm >/dev/null; then
    if rpm -q grok-bot >/dev/null 2>&1; then
      rpm -q --qf '%{VERSION} %{VENDOR}\n' grok-bot
    fi
  fi
}
INSTALLED="$(installed_version || true)"
echo "Installed : ${INSTALLED:-not installed (package manager)}"
echo "Available : ${VERSION} (official, ${FORMAT}, ${FEED_ARCH})"
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  exit 0
fi

# --- signature helpers ------------------------------------------------------
# Dearmor the bundled key without needing gpg, then let gpgv (or gpg with a
# throwaway home) check signatures against that one key only.
KEYRING="$WORK/anysphere.gpg"
python3 - "$KEY_FILE" "$KEYRING" <<'PY2'
import base64, sys
lines = open(sys.argv[1]).read().splitlines()
body, inside = [], False
for line in lines:
    if line.startswith("-----BEGIN PGP PUBLIC KEY BLOCK"):
        inside = True; continue
    if line.startswith("-----END PGP PUBLIC KEY BLOCK"):
        break
    if inside and line and ":" not in line and not line.startswith("="):
        body.append(line.strip())
open(sys.argv[2], "wb").write(base64.b64decode("".join(body)))
PY2
if [[ "$GPG_TOOL" == gpg ]]; then
  export GNUPGHOME="$WORK/gnupg"
  mkdir -m 0700 "$GNUPGHOME"
  gpg --batch --quiet --import "$KEYRING" 2>/dev/null
fi

# gpg_verify <status-out> <signed-out|-> <file...>
gpg_verify() {
  local status="$1" out="$2"; shift 2
  local -a output=()
  [[ "$out" != - ]] && output=(--output "$out")
  if [[ "$GPG_TOOL" == gpgv ]]; then
    gpgv --keyring "$KEYRING" --status-fd 3 "${output[@]}" "$@" 3>"$status" 2>/dev/null
  elif [[ "$out" != - ]]; then
    gpg --batch --status-fd 3 "${output[@]}" --decrypt "$@" 3>"$status" 2>/dev/null
  else
    gpg --batch --status-fd 3 --verify "$@" 3>"$status" 2>/dev/null
  fi
}

# gpg_check <status-file>: accept only a good signature from the pinned key.
gpg_check() {
  awk -v fpr="$KEY_FPR" '$2 == "VALIDSIG" && $NF == fpr { ok = 1 } END { exit !ok }' "$1" ||
    die "signature check failed (expected key ${KEY_FPR})"
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

expect_sha256() {
  local file="$1" want="$2" got
  got="$(sha256_of "$file")"
  [[ -n "$want" && "$got" == "$want" ]] || die "$(basename "$file"): SHA-256 ${got} does not match signed value ${want:-<none>}"
}

verify_deb() {
  local deb="$1"
  fetch "${APT_REPO}/dists/grok-bot/InRelease" "$WORK/InRelease"
  gpg_verify "$WORK/release.status" "$WORK/Release" "$WORK/InRelease" ||
    die "apt InRelease signature is not valid"
  gpg_check "$WORK/release.status"
  local packages_sum
  packages_sum="$(python3 - "$WORK/Release" "$DEB_ARCH" <<'PY'
import sys
text = open(sys.argv[1]).read().split("\nSHA256:", 1)
if len(text) != 2:
    sys.exit("error: Release has no SHA256 section")
want = f"main/binary-{sys.argv[2]}/Packages"
for line in text[1].splitlines()[1:]:
    if not line.startswith(" "):
        break
    parts = line.split()
    if len(parts) == 3 and parts[2] == want:
        print(parts[0]); break
else:
    sys.exit(f"error: Release does not list {want}")
PY
)"
  fetch "${APT_REPO}/dists/grok-bot/main/binary-${DEB_ARCH}/Packages" "$WORK/Packages"
  expect_sha256 "$WORK/Packages" "$packages_sum"
  local want
  want="$(python3 - "$WORK/Packages" "$VERSION" "$DEB_ARCH" <<'PY'
import sys
path, version, arch = sys.argv[1:]
for stanza in open(path).read().split("\n\n"):
    fields = dict(l.split(": ", 1) for l in stanza.splitlines() if ": " in l and not l.startswith(" "))
    if fields.get("Package") == "grok-bot" and fields.get("Version") == version \
            and fields.get("Architecture") == arch:
        print(fields.get("SHA256", "")); break
PY
)"
  expect_sha256 "$deb" "$want"
}

# The dnf repository carries the GPG-signed copy of the .rpm (the rpmUrl in
# the release feed is the same build without the rpm signature header), so
# resolve and download the package from the signed repository metadata.
resolve_rpm() {
  fetch "${YUM_REPO}/repodata/repomd.xml" "$WORK/repomd.xml"
  fetch "${YUM_REPO}/repodata/repomd.xml.asc" "$WORK/repomd.xml.asc"
  gpg_verify "$WORK/repomd.status" - "$WORK/repomd.xml.asc" "$WORK/repomd.xml" ||
    die "dnf repomd.xml signature is not valid"
  gpg_check "$WORK/repomd.status"
  local primary
  primary="$(python3 - "$WORK/repomd.xml" <<'PY2'
import sys, xml.etree.ElementTree as ET
ns = {"r": "http://linux.duke.edu/metadata/repo"}
for data in ET.parse(sys.argv[1]).getroot().findall("r:data", ns):
    if data.get("type") == "primary":
        c = data.find("r:checksum", ns)
        if c is None or c.get("type") != "sha256":
            sys.exit("error: primary metadata has no sha256 checksum")
        print(c.text.strip(), data.find("r:location", ns).get("href")); break
else:
    sys.exit("error: repomd.xml lists no primary metadata")
PY2
)"
  local primary_sum="${primary%% *}" primary_href="${primary#* }"
  [[ "$primary_href" =~ ^repodata/[A-Za-z0-9._-]+$ ]] || die "unexpected primary metadata path"
  fetch "${YUM_REPO}/${primary_href}" "$WORK/primary.xml.gz"
  expect_sha256 "$WORK/primary.xml.gz" "$primary_sum"
  read -r RPM_SHA256 RPM_HREF < <(python3 - "$WORK/primary.xml.gz" "$VERSION" "$RPM_ARCH" <<'PY2'
import gzip, sys, xml.etree.ElementTree as ET
path, version, arch = sys.argv[1:]
ns = {"c": "http://linux.duke.edu/metadata/common"}
for pkg in ET.parse(gzip.open(path)).getroot().findall("c:package", ns):
    if pkg.findtext("c:name", namespaces=ns) == "grok-bot" \
            and pkg.find("c:version", ns).get("ver") == version \
            and pkg.findtext("c:arch", namespaces=ns) == arch:
        c = pkg.find("c:checksum", ns)
        if c is not None and c.get("type") == "sha256":
            print(c.text.strip(), pkg.find("c:location", ns).get("href")); break
PY2
) || true
  [[ -n "${RPM_HREF:-}" && "$RPM_HREF" =~ ^[A-Za-z0-9._/-]+\.rpm$ && "$RPM_HREF" != *..* ]] ||
    die "the signed dnf metadata does not list grok-bot ${VERSION} for ${RPM_ARCH}"
}

verify_rpm() { expect_sha256 "$1" "$RPM_SHA256"; }

verify_appimage() {
  local appimage="$1" machine want
  machine="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  fetch "https://api2.cursor.sh/updates/api/update/${FEED_ARCH}/sand/0.0.0/${machine}/stable" "$WORK/update.json"
  want="$(python3 - "$WORK/update.json" "$VERSION" "$APPIMAGE_URL" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
if data.get("version") != sys.argv[2] or data.get("url") != sys.argv[3]:
    sys.exit("error: update service and release feed disagree about the AppImage")
print(data.get("sha256hash", ""))
PY
)"
  expect_sha256 "$appimage" "$want"
}

# --- download + verify -------------------------------------------------------
case "$FORMAT" in
  deb) URL="$DEB_URL" ;;
  rpm) resolve_rpm; URL="${YUM_REPO}/${RPM_HREF}" ;;
  appimage) URL="$APPIMAGE_URL" ;;
esac
FILE="$WORK/$(basename "$URL")"
echo "Downloading ${URL}"
curl -fL --proto '=https' --tlsv1.2 --retry 3 -o "$FILE" "$URL"
"verify_${FORMAT}" "$FILE"
chmod 0644 "$FILE"
echo "Verified $(basename "$FILE") against Cursor's signed metadata."

if [[ -n "$DOWNLOAD_DIR" ]]; then
  mkdir -p "$DOWNLOAD_DIR"
  cp "$FILE" "$DOWNLOAD_DIR/"
  echo "Saved ${DOWNLOAD_DIR%/}/$(basename "$FILE")"
  exit 0
fi

as_root() {
  if [[ "$EUID" -eq 0 ]]; then
    "$@"
  elif command -v pkexec >/dev/null && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    pkexec "$@"
  elif command -v sudo >/dev/null; then
    sudo "$@"
  else
    die "pkexec or sudo is required to install the package"
  fi
}

# Remove the rebuild updater symlink so it cannot replace the official package.
remove_rebuild_updater() {
  local link="${HOME}/.local/bin/grok-bot-update"
  if [[ -L "$link" && "$(readlink -f "$link")" == */scripts/update.sh ]]; then
    rm -f "$link"
    echo "Removed ${link}; the official package updates through your package manager."
  fi
}

if pgrep -x grok-bot >/dev/null 2>&1; then
  die "Grok Bot is running. Close it, then run this command again."
fi

case "$FORMAT" in
  deb)
    # --reinstall lets the official package replace an unofficial build of the
    # same version; dpkg treats both as package "grok-bot".
    if [[ "$INSTALLED" == *"$UNOFFICIAL_MAINTAINER"* ]]; then
      echo "Replacing the unofficial rebuild with the official package."
    fi
    as_root apt-get install -y --reinstall --allow-downgrades "$FILE"
    dpkg-query -W -f='${Maintainer}' grok-bot | grep -qv "$UNOFFICIAL_MAINTAINER" ||
      die "the official package did not replace the unofficial one"
    remove_rebuild_updater
    echo "Installed official Grok Bot ${VERSION}. Updates arrive through apt (${APT_REPO})."
    ;;
  rpm)
    if command -v dnf >/dev/null; then
      as_root dnf install -y "$FILE"
    else
      as_root zypper --non-interactive install --allow-unsigned-rpm "$FILE"
    fi
    remove_rebuild_updater
    echo "Installed official Grok Bot ${VERSION}. Updates arrive through your package manager."
    ;;
  appimage)
    DEST="${XDG_DATA_HOME:-$HOME/.local/share}/grok-bot"
    BIN_DIR="${HOME}/.local/bin"
    APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons"
    mkdir -p "$DEST" "$BIN_DIR" "$APPS" "$ICONS" "${XDG_CONFIG_HOME:-$HOME/.config}"
    install -m 0755 "$FILE" "$DEST/Grok_Bot.AppImage"
    # The AppImage carries hicolor icons; --appimage-extract works without FUSE.
    if ( cd "$WORK" && "$DEST/Grok_Bot.AppImage" --appimage-extract 'usr/share/icons/*' >/dev/null 2>&1 ) &&
        [[ -d "$WORK/squashfs-root/usr/share/icons/hicolor" ]]; then
      cp -r "$WORK/squashfs-root/usr/share/icons/hicolor" "$ICONS/"
      command -v gtk-update-icon-cache >/dev/null &&
        gtk-update-icon-cache -q -t "$ICONS/hicolor" 2>/dev/null || true
    fi
    ln -sfn "$DEST/Grok_Bot.AppImage" "$BIN_DIR/grok-bot"
    cat > "$APPS/grok-bot.desktop" <<DESKTOP
[Desktop Entry]
Name=Grok Bot
Comment=Grok Bot desktop agent
Exec="$DEST/Grok_Bot.AppImage" %U
Icon=grok-bot
Type=Application
Terminal=false
StartupWMClass=grok-bot
MimeType=x-scheme-handler/grokbot;x-scheme-handler/sand;
Categories=Development;
DESKTOP
    command -v update-desktop-database >/dev/null && update-desktop-database -q "$APPS" || true
    if command -v xdg-mime >/dev/null; then
      xdg-mime default grok-bot.desktop x-scheme-handler/grokbot x-scheme-handler/sand || true
    fi
    remove_rebuild_updater
    echo "Installed official Grok Bot ${VERSION} to ${DEST}/Grok_Bot.AppImage."
    echo "The AppImage updates itself from Settings > Updates."
    ;;
esac
