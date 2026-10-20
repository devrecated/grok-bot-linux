# Grok Bot Linux

A Linux build of the Grok Bot desktop app. It takes the official Electron app, runs it on a Linux Electron runtime, and replaces the native addons that only ship for Windows. No Wine. Sign in with the same account you use on the Mac app.

This is a community project and not an xAI or Grok Bot product.

## Install

### Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/devrecated/grok-bot-linux/main/scripts/install.sh | bash
```

Piping a script to `bash` runs it with your account's privileges, so read [`scripts/install.sh`](scripts/install.sh) first if you want to see what it does. The checkout stays in `~/.local/share/grok-bot-linux/src`; re-run the command or `grok-bot-update` to update.

Environment variables that change its behavior:

- `GROK_BOT_LINUX_MODE=official|source|auto` picks the install path (default `auto`).
- `GROK_BOT_LINUX_SRC=DIR` sets the checkout directory.
- `GROK_BOT_LINUX_NO_DEPS=1` skips installing dependencies.

### Debian / Ubuntu (apt)

```bash
curl -fsSL https://devrecated.github.io/grok-bot-linux/install-apt.sh | sudo bash
```

Or add the repo yourself:

```bash
curl -fsSL https://devrecated.github.io/grok-bot-linux/grok-bot-linux.list \
  | sudo tee /etc/apt/sources.list.d/grok-bot-linux.list
sudo apt-get update
sudo apt-get install grok-bot-linux
sudo grok-bot-linux-setup
```

### Fedora / RHEL (dnf)

```bash
curl -fsSL https://devrecated.github.io/grok-bot-linux/install-dnf.sh | sudo bash
```

Or add the repo yourself:

```bash
curl -fsSL https://devrecated.github.io/grok-bot-linux/grok-bot-linux.repo \
  | sudo tee /etc/yum.repos.d/grok-bot-linux.repo
sudo dnf install grok-bot-linux
sudo grok-bot-linux-setup
```

### Arch (AUR)

A `grok-bot-linux` PKGBUILD lives in [`packaging/aur`](packaging/aur):

```bash
cd packaging/aur
makepkg -si
```

Once it is published to the AUR, an AUR helper installs it directly:

```bash
yay -S grok-bot-linux
```

### From source

```bash
git clone https://github.com/devrecated/grok-bot-linux.git
cd grok-bot-linux
make update
```

The apt and dnf one-liners install a small helper package that contains only this repo's MIT-licensed scripts. The official build is downloaded and verified at setup time, so no xAI binary is hosted or redistributed by this project. Every path here fetches the official app at install time and never bundles it.

## What it does

You get the official Grok Bot UI, the bots, the shared computer, and sign-in with your account, running as a native Linux app. Bots live on the cloud computer and this build is the remote control.

The latest stable upstream release is resolved through Cursor's update service. The current Linux runtime is Electron 42.1.0 (x86_64). Details on the port are in [docs/how-it-works.md](docs/how-it-works.md).

## Build options

| Command | Result |
|---|---|
| `make detect` | Newest stable version from Cursor's update API |
| `make build` | Tarball, `.deb`, and AppImage in `dist/` (whatever this host can build) |
| `make build FORMATS=tar` | Only the runnable tree and tarball |
| `make update` | Build, validate, and install only when needed |
| `make test` | Smoke-test the staged build: load every native addon, launch under Xvfb |
| `make install-user` | Install the tree under `~/.local/share/grok-bot-unofficial` with a menu entry |
| `make install-updater` | Add `grok-bot-update` to `~/.local/bin` |
| `make install-official` | Install Cursor's official package, verified against its signed metadata |
| `./scripts/build.sh X.Y.Z` | Pin a specific upstream version |
| `./scripts/build.sh --exe ~/Downloads/Grok_Bot_X.Y.Z_Setup.exe` | Use an installer you already downloaded |
| `./scripts/install-official.sh --check` | Check the official package without installing |

`make build` works without `dpkg-deb`: it builds every format the machine has tools for and skips the rest with a note. Node.js headers are not required; if `node_api.h` is missing, the build fetches the header-only `node-api-headers` package from npm.

The `grok-bot` wrapper and the AppImage keep Chromium's sandbox on whenever user namespaces, the setuid `chrome-sandbox` helper, or the bundled AppArmor profile make it possible. They add `--no-sandbox` only when none of those work, as in some containers, and say so on stderr. Extra Electron flags go in `~/.config/grok-bot/electron-flags.conf`, one argument per line. For an NVIDIA black window, add `--ozone-platform=x11` there.

## Older Macs (macOS 11 Big Sur)

The official Mac app needs macOS 12 or newer. `make mac-install` rebuilds it for macOS 11 Big Sur by moving the official `app.asar` onto Electron 37, the last Electron release that supports Big Sur. It needs MacPorts with `nodejs22` and `npm10`, and it runs on the Mac itself. The native addons are the official ones, unchanged.

```bash
git clone -b macos-legacy https://github.com/devrecated/grok-bot-linux.git
cd grok-bot-linux
make mac-install
```

Caveats: the in-app updater is off (run `make mac-install` again to update), `sand-op-launcher` (1Password connection) needs macOS 12, and Computer Use needs macOS 14. macOS 10.15 and older are not supported. This path has not been tested on a real Big Sur Mac yet; testing notes and how to report results are on the `macos-legacy` branch.

## Updates

The in-app updater does not install this Linux build. Install the one-command updater once, then update from any directory:

```bash
make install-updater
grok-bot-update
```

Close Grok Bot before installing an available update. Routine updates write only ignored files under `.cache/` and `dist/` and do not touch the checkout. Repository changes are needed only when Cursor changes the app packaging, Electron ABI, or native dependencies. If a new release adds a native addon the port doesn't handle, the build stops and names it instead of producing an app that fails at startup.

Downloads are verified: the Electron zip against Electron's published `SHASUMS256.txt`, npm tarballs against pinned registry integrity hashes, and appimagetool, the AppImage runtime, and the better-sqlite3 prebuild against pinned SHA-256 values. Cursor's update response carries no checksum, so the updater requires HTTPS, allow-lists the exact download host and path, and validates the Debian package's identity and contents before installing.

## Requirements

- x86_64 Linux, glibc 2.34+ (Ubuntu 22.04 or newer)
- An eligible Grok Bot plan, same as the official apps
- Build machine: `p7zip-full`, `curl`, `unzip`, `g++`, `python3`, Node 20+; `dpkg-deb` for the `.deb`, `squashfs-tools` and `file` for the AppImage

This repository never commits the official installer, `app.asar`, or built binaries. Those are produced on your machine.

## License

Scripts and Linux-native sources in this repo are [MIT](LICENSE). Grok Bot belongs to xAI. Electron belongs to the Electron project. See [NOTICE.md](NOTICE.md).

## Disclaimer

Grok Bot Linux is an unofficial, community project. It is not affiliated with, endorsed by, or associated with xAI or Grok Bot. All related names and marks belong to their respective owners.

Originally written by [@jakob-bu](https://github.com/jakob-bu) — see the [original repository](https://github.com/jakob-bu/grok-bot-linux-unofficial). This is the community-maintained continuation under the [Devrecated](https://github.com/devrecated) org.
