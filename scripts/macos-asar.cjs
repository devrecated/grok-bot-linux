"use strict";
// Repack the official app.asar with packaging/macos-entry.cjs as its main,
// keeping exactly the same set of unpacked files (native addons and helper
// binaries have to stay real files on disk).
//
// Usage: node macos-asar.cjs <asar-module-dir> <in.asar> <out.asar> <entry.cjs>

const fs = require("fs");
const os = require("os");
const path = require("path");

const [asarDir, input, output, entry] = process.argv.slice(2);
const asar = require(asarDir);

function unpackedFiles(archive) {
  const out = [];
  const walk = (node, prefix) => {
    for (const [name, child] of Object.entries(node.files || {})) {
      const p = prefix ? `${prefix}/${name}` : name;
      if (child.files) walk(child, p);
      else if (child.unpacked) out.push(p);
    }
  };
  walk(asar.getRawHeader(archive).header, "");
  return out.sort();
}

(async () => {
  const before = unpackedFiles(input);
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "grokbot-asar-"));
  asar.extractAll(input, tmp);

  const pkgPath = path.join(tmp, "package.json");
  const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
  if (pkg.main !== "dist/electron-main/main.cjs") {
    throw new Error(`unexpected package.json main: ${pkg.main}`);
  }
  pkg.main = "macos-entry.cjs";
  fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + "\n");
  fs.copyFileSync(entry, path.join(tmp, "macos-entry.cjs"));

  const unpack = before.length ? `{${before.map((f) => path.join(tmp, f)).join(",")}}` : undefined;
  fs.rmSync(output, { force: true });
  fs.rmSync(`${output}.unpacked`, { recursive: true, force: true });
  await asar.createPackageWithOptions(tmp, output, { unpack });
  fs.rmSync(tmp, { recursive: true, force: true });

  const after = unpackedFiles(output);
  if (JSON.stringify(before) !== JSON.stringify(after)) {
    const missing = before.filter((f) => !after.includes(f));
    const extra = after.filter((f) => !before.includes(f));
    throw new Error(`unpacked set changed; missing: ${missing} extra: ${extra}`);
  }
  console.log(`app.asar repacked: main=macos-entry.cjs, ${after.length} unpacked files kept`);
})().catch((err) => {
  console.error(`error: ${err.message}`);
  process.exit(1);
});
