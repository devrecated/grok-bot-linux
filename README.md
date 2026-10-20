# Grok Bot Linux

Ubuntu/Linux build of the **Grok Bot** desktop app.

Cursor originally shipped Grok Bot for macOS and Windows only. This repo does the same
thing the [Codex Mac-to-Linux port](https://github.com/ilysenko/codex-desktop-linux)
did: take the official Electron app, put it on a Linux Electron runtime,
and replace the Windows-only native addons.

It is **not** an xAI or Cursor product.

Kudos to [@jakob-bu](https://github.com/jakob-bu) for the idea and [original creation](https://github.com/jakob-bu/grok-bot-linux-unofficial) of this codebase. [Devrecated](https://github.com/devrecated) will be taking over maintenance of this repository and its open-source contributions going forward.

## Official Linux builds are now available

Cursor now publishes official Linux builds with every
stable release: `.deb`, `.rpm` and AppImage, for x64 and arm64
([download page](https://cursor.com/download/bot),
[deployment docs](https://cursor.com/docs/grok-bot/deployment)). If you just
want Grok Bot on Linux, the official build is the simplest choice.

To install it from this checkout, with every download verified against
Cursor's signed package metadata before anything is installed:

```bash
make install-official          # .deb on Debian/Ubuntu, .rpm on Fedora/openSUSE, else AppImage
./scripts/install-official.sh --format appimage
./scripts/install-official.sh --check
```

If the rebuilt `grok-bot` package from this repository is installed,
`make install-official` replaces it with the official package (both are
called `grok-bot`), keeps your sign-in in `~/.config/Grok Bot`, and removes
the `grok-bot-update` symlink. `grok-bot-update` also refuses to overwrite an
official install.

The rebuild below still works and is useful when you want to pin or audit a
specific version, build offline from an installer you already have, or
patch the app yourself.

## Quick install

One command clones this repository and runs its install pipeline:

```bash
curl -fsSL https://raw.githubusercontent.com/devrecated/grok-bot-linux/main/scripts/install.sh | bash
```

It installs Cursor's official Linux build when one exists for your machine, verified against Cursor's signed package metadata, and otherwise falls back to the from-source rebuild. It installs the build dependencies it needs along the way. Piping a script to `bash` runs it with your account's privileges, so read [`scripts/install.sh`](scripts/install.sh) first if you want to see what it does.

On Debian/Ubuntu or Fedora/RHEL you can also install through apt or dnf. Those paths ship a tiny helper package (scripts only) and then fetch the official build; see [Debian / Ubuntu (apt)](#debian--ubuntu-apt) and [Fedora / RHEL (dnf)](#fedora--rhel-dnf) below. Arch users can use the [AUR PKGBUILD](#arch-linux-aur).

The checkout stays in `~/.local/share/grok-bot-linux/src`; re-run the command, or `grok-bot-update`, to update. A few environment variables change its behavior:

- `GROK_BOT_LINUX_MODE=official|source|auto` picks the install path (default `auto`).
- `GROK_BOT_LINUX_SRC=DIR` sets the checkout directory.
- `GROK_BOT_LINUX_NO_DEPS=1` skips installing dependencies.

Like every path in this repo, the installer fetches the official app at install time and never bundles or re-hosts it.

## What you get

The official Grok Bot UI — bots, the shared computer, sign-in with your
Cursor account — running as a native Linux app. No Wine.

The latest stable upstream release is resolved dynamically through Cursor's
update service. The current Linux runtime is **Electron 42.1.0** (x86_64).

## Ubuntu / Debian

```bash
sudo apt install p7zip-full curl unzip build-essential python3 \
  libfuse2 fakeroot
# Node.js 20+ (Ubuntu 24.04: sudo apt install nodejs npm  is too old;
# use https://github.com/nvm-sh/nvm or NodeSource)

git clone <this-repo> grok-bot-linux
cd grok-bot-linux
make update

grok-bot
```

`make update` downloads, rebuilds, validates, and installs only when Cursor
has published a newer stable version. The final package installation uses the
normal graphical administrator prompt (or `sudo` when no graphical session is
available). It builds only the `.deb`; `make build` remains the command for all
distribution formats.

Or skip the package and run the tree directly:

```bash
make build
version="$(make -s detect)"
"./dist/Grok_Bot_${version}_linux_x64/grok-bot" --ozone-platform-hint=auto
```

(`make run` does the same. Add `--no-sandbox` only where unprivileged user
namespaces are disabled, as in some containers; see below.)

AppImage (needs FUSE 2):

```bash
chmod +x dist/Grok_Bot_*_x86_64.AppImage
./dist/Grok_Bot_*_x86_64.AppImage
```

Sign in with the same Cursor / SuperGrok account you use on the Mac app.
Bots live on the cloud computer; this build is the remote control.

## Other distros

`make build` works without `dpkg-deb`: it builds every format the machine
has tools for and skips the rest with a note (`FORMATS=tar` or
`./scripts/build.sh --formats tar` to ask for just the tarball). Build
dependencies:

```bash
sudo dnf install nodejs npm gcc gcc-c++ unzip python3 curl p7zip p7zip-plugins   # Fedora
sudo pacman -S nodejs npm gcc unzip python curl 7zip                             # Arch
```

Node.js headers are not needed: if `node_api.h` is not installed, the build
fetches the header-only `node-api-headers` package from npm.

The tarball in `dist/` is a self-contained Electron tree. On Fedora /
Arch, install GTK3, NSS, ALSA, and Mesa, then:

```bash
tar -xzf dist/Grok_Bot_*_linux_x64.tar.gz
./Grok_Bot_*_linux_x64/grok-bot --ozone-platform-hint=auto
```

Or install that tree for your user, with a menu entry and the
`grokbot://` / `sand://` link handlers that the browser sign-in returns to
(no root needed; the setuid sandbox helper is unavailable in a user
install, so the launcher adds `--no-sandbox`):

```bash
make install-user      # ~/.local/share/grok-bot-unofficial + ~/.local/bin/grok-bot
make uninstall-user
```


### Arch Linux (AUR)

A `grok-bot-linux` PKGBUILD lives in [`packaging/aur`](packaging/aur). It downloads the official AppImage and verifies it against Cursor's published SHA-256 during the build on your own machine, then installs it with a menu entry and the `grokbot://` / `sand://` link handlers. It redistributes nothing proprietary; only the verified download happens at build time.

```bash
cd packaging/aur
makepkg -si
```

Once it is published to the AUR, an AUR helper installs it directly, for example `yay -S grok-bot-linux`.

### Debian / Ubuntu (apt)

A small helper package lives on GitHub Pages. It installs only the MIT-licensed scripts from this repo. After that, `grok-bot-linux-setup` downloads Cursor's official build, checks it against Cursor's signed package metadata, and installs it. The `.deb` never contains `app.asar` or any other xAI binary.

```bash
curl -fsSL https://devrecated.github.io/grok-bot-linux/install-apt.sh | sudo bash
```

Or add the repo yourself and run setup when you are ready:

```bash
curl -fsSL https://devrecated.github.io/grok-bot-linux/grok-bot-linux.list \
  | sudo tee /etc/apt/sources.list.d/grok-bot-linux.list
sudo apt-get update
sudo apt-get install grok-bot-linux
sudo grok-bot-linux-setup
```

### Fedora / RHEL (dnf)

Same helper package, packaged as a noarch `.rpm`. The one-liner adds the dnf repo, installs the helper, and runs setup:

```bash
curl -fsSL https://devrecated.github.io/grok-bot-linux/install-dnf.sh | sudo bash
```

Or manually:

```bash
curl -fsSL https://devrecated.github.io/grok-bot-linux/grok-bot-linux.repo \
  | sudo tee /etc/yum.repos.d/grok-bot-linux.repo
sudo dnf install grok-bot-linux
sudo grok-bot-linux-setup
```

The apt and dnf site is published from this repository's `gh-pages` branch by the `publish-linux-repos` workflow. Build the packages locally with `make linux-packages` or the full Pages tree with `make linux-repos`.

## Older Macs (macOS 11 Big Sur)

The official Mac app needs macOS 12 or newer (`LSMinimumSystemVersion`
12.0, Electron 42). `make mac` rebuilds it for **macOS 11 Big Sur** by
moving the official `app.asar` onto Electron 37, the last Electron release
that supports Big Sur. The native addons are the official ones, unchanged:
they are N-API modules built for macOS 11 (Apple silicon) and 10.13 (Intel).
Run this on the Mac itself.

```bash
# 1. MacPorts for your macOS version: https://www.macports.org/install.php
#    (needs the Xcode Command Line Tools: xcode-select --install)
sudo port install nodejs22 npm10 git

git clone <this-repo> grok-bot-linux
cd grok-bot-linux
make mac-install        # or: make mac   (leaves it in dist/macos/)

open "/Applications/Grok Bot.app"
```

`make mac` checks for MacPorts and installs `nodejs22` and `npm10` itself if
Node.js 18+ isn't already available. It downloads the official `.dmg` and
checks that Anysphere signed it, downloads Electron and checks it against
Electron's `SHASUMS256.txt`, then assembles and ad-hoc signs
`dist/macos/Grok Bot.app`.

What to expect:

- The in-app updater is off. An official update would bring back Electron
  42, which doesn't start on Big Sur. To update, run `make mac-install` again.
- Two official helpers ask for a newer macOS and won't load on Big Sur. The
  build prints a warning for each:
  - `sand-op-launcher` (1Password connection) needs macOS 12.
  - Computer Use needs macOS 14, the same as with the official app on 12 and 13.
- macOS 10.15 and older are not supported. Electron 32, the last release for
  Catalina, fails to start this version of Grok Bot.
- Not supported by Cursor, and nobody has tested it on a real Big Sur Mac
  yet. See below.

### Testing on an old Mac

1. Install MacPorts for your macOS version from
   https://www.macports.org/install.php. Follow its steps, including
   `xcode-select --install`, then open a new Terminal window.
2. Get the branch:
   ```bash
   git clone -b macos-legacy https://github.com/devrecated/grok-bot-linux.git
   cd grok-bot-linux
   ```
3. Build and install:
   ```bash
   make mac-install 2>&1 | tee mac-build.log
   ```
   This asks for your password if it needs to install MacPorts packages. If
   MacPorts has no prebuilt Node.js for your macOS, building it can take a
   long time.
4. Run `open "/Applications/Grok Bot.app"` and check:
   - the app opens and the sign-in screen appears;
   - **Sign in** opens your browser, and the `grokbot://` link brings you back
     to the app signed in;
   - you can open a Bot and send it a message;
   - it doesn't offer an update or restart into one.
5. Report back. Send `sw_vers`, `uname -m`, `mac-build.log`, what worked,
   and what didn't. If the app quits, include any crash report from
   Console.app → Crash Reports, or the output of
   `"/Applications/Grok Bot.app/Contents/MacOS/Grok Bot"` run in Terminal.
   Comment on the pull request, or open a pull request against the
   `macos-legacy` branch of devrecated/grok-bot-linux.

## Build options

| Command | Result |
|---|---|
| `make detect` | Newest stable version from Cursor's update API |
| `make build` | Tarball + `.deb` + AppImage in `dist/` (whatever this host can build) |
| `make build FORMATS=tar` | Only the runnable tree and tarball |
| `make test` | Smoke-test the staged build: load every native addon, launch under Xvfb |
| `make update` | Build, validate, and install only when needed |
| `./scripts/update.sh --check` | Compare installed and latest versions |
| `./scripts/build.sh X.Y.Z` | Pin a specific upstream version |
| `./scripts/build.sh --exe ~/Downloads/Grok_Bot_X.Y.Z_Setup.exe` | Use an installer you already downloaded |
| `make install-updater` | Add `grok-bot-update` to `~/.local/bin` |

The `/usr/bin/grok-bot` wrapper and the AppImage keep Chromium's sandbox
on whenever user namespaces, the setuid `chrome-sandbox` helper, or the
bundled AppArmor profile (installed by the `.deb` for Ubuntu 24.04's
userns restriction) make it possible. Only when none of those work, as in
some containers, do they add `--no-sandbox` and say so on stderr. Extra
Electron flags go in `~/.config/grok-bot/electron-flags.conf`, one per
line; each line is passed as a single argument.

NVIDIA + black window: add `--ozone-platform=x11` to that file.

After a build, or when a new upstream release lands, run `make test`
(`scripts/smoke-test.sh [--no-launch] [APP_DIR]`). It loads each addon
listed in the payload's `runtime-deps-manifest.json` in the app's own
Electron, checks that every function the wrapper re-exports exists, and
does a small real call: a process scan, a bash parse, the notification
query. It also fails if a Windows `.node` is still where Node would load
it. If `Xvfb` is installed, it then starts the app and looks for
module-load errors in its log.

## Updates

The in-app updater does not install this unofficial Linux build. Install the
one-command updater once from the repository:

```bash
make install-updater
```

After that, update from any directory with:

```bash
grok-bot-update
```

Close Grok Bot before installing an available update. Routine upstream
updates write only ignored files under `.cache/` and `dist/`; they do not edit
the checkout or require a Git commit. Repository changes are needed only when
Cursor changes the app packaging, Electron ABI, or native dependencies.

If a new release adds a native addon the port doesn't handle yet, the build
stops and names it and its exported functions, instead of producing an app
that fails at startup. Addons are listed in the payload's
`runtime-deps-manifest.json`. Each one needs a Linux implementation in
`native/` and a case in `scripts/fix-natives.py`.

The updater retains the installed `.deb` and at most one previous `.deb` for
rollback, and removes superseded cached upstream installers. Cursor's update
response currently does not provide a checksum, so the installer cannot be
cryptographically pinned: the updater instead requires HTTPS, allow-lists the
exact download host and path, and validates the resulting Debian package's
identity and required contents before installation.

Everything else the build downloads is checked: the Electron zip against
Electron's published `SHASUMS256.txt`, npm tarballs against pinned registry
integrity hashes, and appimagetool, the AppImage runtime and the
better-sqlite3 prebuild against pinned SHA-256 values. Archives are
extracted without allowing absolute paths, `..` or links.

## How this compares to the Mac app

| | Official Mac app | This Linux build |
|---|---|---|
| UI / bots / cloud computer | yes | same `app.asar` |
| Sign-in | Cursor account | same |
| Native addons | Mach-O | rebuilt or replaced for Linux |
| Auto-update | official | rebuild from the new Windows installer |
| Support | Cursor | none (community) |

The Mac `.dmg` is not used here. Extracting it on Linux is awkward, and
its native modules are still the wrong ABI. The Windows NSIS installer
unpacks with `7z` and is the source every working community port uses.
Details: [docs/how-it-works.md](docs/how-it-works.md).

## Requirements

- x86_64 Linux, glibc 2.34+ (Ubuntu 22.04 or newer)
- Eligible Grok Bot plan (same as the official apps)
- Build machine: `p7zip-full`, `curl`, `unzip`, `g++`, `python3`, Node 20+;
  `dpkg-deb` for the `.deb`, `squashfs-tools` and `file` for the AppImage

This repository never commits the official installer, `app.asar`, or
built binaries. Those are produced on your machine.

## License

Scripts and Linux-native sources in this repo: [MIT](LICENSE).

Grok Bot belongs to xAI / Cursor. Electron belongs to the Electron
project. See [NOTICE.md](NOTICE.md).

## Disclaimer

Grok Bot Linux is an unofficial, community project. It is not affiliated with,
endorsed by, or associated with xAI or Grok Bot / Grok. All related names and
marks belong to their respective owners.

Originally written by [@jakob-bu](https://github.com/jakob-bu) — see the [original repository](https://github.com/jakob-bu/grok-bot-linux-unofficial). This is the community-maintained continuation under the [Devrecated](https://github.com/devrecated) org.
