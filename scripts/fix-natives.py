#!/usr/bin/env python3
"""Replace Windows PE native addons with Linux ELF binaries.

Public modules are taken from npm / GitHub prebuilds that match the
versions vendored in the official Windows payload. Private Cursor
modules are compiled from native/ in this repository.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEPS: Path | None = None


def is_pe(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(2) == b"MZ"
    except OSError:
        return False


def run(cmd: list[str], cwd: Path | None = None) -> None:
    subprocess.check_call(cmd, cwd=cwd)


# Registry integrity (npm view <spec> dist.integrity) for every package
# this script downloads, so a changed tarball fails the build.
NPM_INTEGRITY = {
    "tree-sitter@0.21.1": "sha512-7dxoA6kYvtgWw80265MyqJlkRl4yawIjO7S5MigytjELkX43fV2WsAXzsNfO7sBpPPCF5Gp0+XzHk0DwLCq3xQ==",
    "tree-sitter-bash@0.21.0": "sha512-UuXf+wliu1mmS/O2Iz7OQghExM4a+lk+GaVPndZVpAJnFuzanaN33UcHOsrmngHxaOXHz5JSZrwp6i2qM/PKag==",
    "whichlang-node-linux-x64-gnu@0.2.1": "sha512-jCU2jVYew0Q42kbaDlYNGUNb4Tsh3m8/AajXIge+bT4XlKZ5zIQxSnirRViQ6VQ9h59KieYzV2IyVbjBiK7X2g==",
}

BETTER_SQLITE3_URL = (
    "https://github.com/WiseLibs/better-sqlite3/releases/download/"
    "v12.11.1/better-sqlite3-v12.11.1-electron-v146-linux-x64.tar.gz"
)
BETTER_SQLITE3_SHA256 = "e2021aeed80de4f15212525e30565756aaae790e68e3229df6d1345f43803221"


def safe_extract(tgz: Path, dest: Path) -> None:
    """Extract a .tar.gz without following absolute paths, .. or links out."""
    with tarfile.open(tgz, "r:gz") as archive:
        if hasattr(tarfile, "data_filter"):
            archive.extractall(dest, filter="data")
            return
        root = dest.resolve()
        for member in archive.getmembers():
            target = (dest / member.name).resolve()
            if root not in target.parents and target != root:
                raise RuntimeError(f"{tgz.name}: unsafe path {member.name}")
            if member.issym() or member.islnk() or member.isdev():
                raise RuntimeError(f"{tgz.name}: refusing link/device {member.name}")
        archive.extractall(dest)


def npm_pack_extract(spec: str, dest: Path) -> Path:
    dest.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="gb-npm-"))
    run(["npm", "pack", "--ignore-scripts", "--silent", spec], cwd=tmp)
    tgz = next(tmp.glob("*.tgz"))
    want = NPM_INTEGRITY.get(spec)
    got = "sha512-" + base64.b64encode(hashlib.sha512(tgz.read_bytes()).digest()).decode()
    if want is None or got != want:
        raise SystemExit(f"{spec}: tarball integrity {got} does not match pinned {want}")
    safe_extract(tgz, tmp / "ex")
    pkg = tmp / "ex" / "package"
    if not pkg.is_dir():
        raise RuntimeError(f"npm pack {spec} did not contain package/")
    return pkg


def download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    run(["curl", "-fL", "--retry", "3", "-A", "grok-bot-linux", "-o", str(dest), url])


def compile_native(src: Path, dest: Path, name: str) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    include = os.environ.get("GROKBOT_NODE_INCLUDE", "")
    if not include or not Path(include, "node_api.h").is_file():
        raise RuntimeError("GROKBOT_NODE_INCLUDE must point at node_api.h")
    compiler = "g++" if src.suffix in {".cc", ".cpp", ".cxx"} else "gcc"
    run(
        [
            compiler,
            "-shared",
            "-fPIC",
            "-O2",
            "-s",
            f"-I{include}",
            str(src),
            "-o",
            str(dest),
            f"-DNODE_GYP_MODULE_NAME={name}",
        ]
    )


def copy_linux_prebuild(extracted_pkg: Path, dest_dir: Path) -> Path:
    candidates = list(extracted_pkg.glob("prebuilds/linux-x64/*.node"))
    candidates += list(extracted_pkg.glob("**/*.linux-x64-gnu.node"))
    if not candidates:
        raise RuntimeError(f"no linux-x64 .node in {extracted_pkg}")
    src = candidates[0]
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / src.name
    shutil.copy2(src, dest)
    return dest


def present(rel: str) -> bool:
    assert DEPS is not None
    return (DEPS / rel).exists()


# Addons this script knows how to replace. Anything else listed as required
# in the payload's runtime-deps-manifest.json is a new private addon that
# needs a Linux implementation before the build can be trusted.
HANDLED = {
    "better-sqlite3",
    "tree-sitter",
    "tree-sitter-bash",
    "whichlang-node",
    "cursor-proclist",
    "@anysphere/tree-chunk-napi",
    "sand-notification-settings",
}


def exported_names(index_js: Path) -> list[str]:
    """Best-effort list of binding functions a wrapper index.js re-exports."""
    try:
        text = index_js.read_text(errors="replace")
    except OSError:
        return []
    return sorted(set(re.findall(r"binding\.([A-Za-z_][A-Za-z0-9_]*)", text)))


def check_manifest() -> None:
    assert DEPS is not None
    manifest = DEPS / "runtime-deps-manifest.json"
    if not manifest.is_file():
        return
    try:
        required = json.loads(manifest.read_text()).get("required", [])
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"cannot read {manifest}: {exc}")
    unknown = [name for name in required if name not in HANDLED]
    if not unknown:
        return
    lines = [
        "This Grok Bot release needs native addons the Linux port does not know yet:",
    ]
    for name in unknown:
        names = exported_names(DEPS / name / "index.js")
        api = ", ".join(names) if names else "see its index.js"
        lines.append(f"  - {name} (exports: {api})")
    lines.append(
        "Add a Linux implementation in native/ and a case in scripts/fix-natives.py."
    )
    raise SystemExit("\n".join(lines))


def main() -> None:
    global DEPS
    unpacked = Path(os.environ["GROKBOT_UNPACKED"])
    DEPS = unpacked / "dist" / "deps"
    if not DEPS.is_dir():
        raise SystemExit(f"missing {DEPS}")

    tmp = Path(tempfile.mkdtemp(prefix="gb-native-"))
    native = ROOT / "native"

    if present("better-sqlite3"):
        tgz = tmp / "bs.tar.gz"
        download(BETTER_SQLITE3_URL, tgz)
        got = hashlib.sha256(tgz.read_bytes()).hexdigest()
        if got != BETTER_SQLITE3_SHA256:
            raise SystemExit(f"better-sqlite3 prebuild SHA-256 {got} does not match pinned value")
        safe_extract(tgz, tmp / "ex")
        node = next((tmp / "ex").rglob("better_sqlite3.node"))
        dest = DEPS / "better-sqlite3" / "build" / "Release" / "better_sqlite3.node"
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(node, dest)
        print("better-sqlite3:", dest)
    else:
        print("skip better-sqlite3 (not in payload)")

    if present("tree-sitter"):
        ts_pkg = npm_pack_extract("tree-sitter@0.21.1", tmp / "tree-sitter")
        ts_dir = DEPS / "tree-sitter"
        shutil.rmtree(ts_dir / "build", ignore_errors=True)
        copy_linux_prebuild(ts_pkg, ts_dir / "prebuilds" / "linux-x64")
        print("tree-sitter linux prebuild installed")
    else:
        print("skip tree-sitter (not in payload)")

    if present("tree-sitter-bash"):
        tsb_pkg = npm_pack_extract("tree-sitter-bash@0.21.0", tmp / "tree-sitter-bash")
        tsb_dir = DEPS / "tree-sitter-bash"
        shutil.rmtree(tsb_dir / "build", ignore_errors=True)
        copy_linux_prebuild(tsb_pkg, tsb_dir / "prebuilds" / "linux-x64")
        print("tree-sitter-bash linux prebuild installed")
    else:
        print("skip tree-sitter-bash (not in payload)")

    if present("whichlang-node"):
        wl_pkg = npm_pack_extract(
            "whichlang-node-linux-x64-gnu@0.2.1", tmp / "whichlang"
        )
        wl_node = next(wl_pkg.glob("*.linux-x64-gnu.node"))
        dest_dir = DEPS / "whichlang-node"
        dest_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(wl_node, dest_dir / wl_node.name)
        print("whichlang-node:", wl_node.name)
    else:
        print("skip whichlang-node (not in payload)")

    if present("cursor-proclist"):
        compile_native(
            native / "cursor_proclist.c",
            DEPS / "cursor-proclist" / "build" / "Release" / "cursor_proclist.node",
            "cursor_proclist",
        )
        print("cursor_proclist linux /proc addon")
    else:
        print("skip cursor-proclist (not in payload)")

    if present("@anysphere/tree-chunk-napi"):
        compile_native(
            native / "napi_stub.c",
            DEPS / "@anysphere" / "tree-chunk-napi" / "tree-chunk-napi.linux-x64-gnu.node",
            "tree_chunk_napi",
        )
        print("tree-chunk-napi stub")
    else:
        print("skip tree-chunk-napi (not in payload)")

    if present("sand-notification-settings"):
        compile_native(
            native / "sand_notification_settings.c",
            DEPS
            / "sand-notification-settings"
            / "build"
            / "Release"
            / "sand_notification_settings.node",
            "sand_notification_settings",
        )
        print("sand-notification-settings linux addon (resolves null)")
    else:
        print("skip sand-notification-settings (not in payload)")

    check_manifest()

    live_pe: list[str] = []
    for path in DEPS.rglob("*.node"):
        if not is_pe(path):
            continue
        rel = str(path.relative_to(DEPS))
        if "/prebuilds/win32-" in f"/{rel}" or ".win32-" in path.name:
            continue
        live_pe.append(rel)
    if live_pe:
        raise SystemExit("Windows .node still loadable on Linux:\n" + "\n".join(live_pe))
    print("native fix ok")


if __name__ == "__main__":
    main()
