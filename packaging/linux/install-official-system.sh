#!/usr/bin/env bash
# Root-aware wrapper that runs the repo's install-official.sh from a system
# package install under /usr/lib/grok-bot-linux.
#
# The .deb / .rpm that ships this script contains only MIT-licensed helpers.
# Cursor's official Grok Bot build is downloaded and verified here, on the
# user's machine, the same way the AUR PKGBUILD does at build time.
#
# Usage:
#   grok-bot-linux-setup                 # install / refresh official build
#   grok-bot-linux-setup --check         # show installed vs available
#   grok-bot-linux-setup --format appimage
#   grok-bot-linux-setup --help
set -euo pipefail

LIB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
# When installed as a package, this file lives at
# /usr/lib/grok-bot-linux/packaging/linux/install-official-system.sh, so LIB
# resolves to /usr/lib/grok-bot-linux. When run from a git checkout,
# dirname/.../../.. still lands on the repo root.
SCRIPT="${LIB}/scripts/install-official.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "grok-bot-linux: missing ${SCRIPT}" >&2
  exit 1
fi

exec "$SCRIPT" "$@"
