// Run by scripts/smoke-test.sh with the staged app's own Electron in
// ELECTRON_RUN_AS_NODE mode, so native addons load against the exact
// Node ABI the app ships with.
"use strict";

const fs = require("fs");
const path = require("path");

const resources = process.argv[2];
const asar = path.join(resources, "app.asar");
const deps = path.join(resources, "app.asar.unpacked", "dist", "deps");
let failures = 0;

function ok(msg) {
  console.log(`ok    ${msg}`);
}
function fail(msg) {
  failures++;
  console.log(`FAIL  ${msg}`);
}

async function check(name, fn) {
  try {
    const detail = await fn();
    ok(detail ? `${name}: ${detail}` : name);
  } catch (err) {
    fail(`${name}: ${err && err.message ? err.message.split("\n")[0] : err}`);
  }
}

// Native addons that get executed directly rather than through the
// package's JS, with a small functional check for each.
const functional = {
  "cursor-proclist": async (m) => {
    const rows = await m.cursor_proclist_scan_async([process.pid]);
    if (!rows.some((r) => r[0] === process.pid)) throw new Error("own pid not in scan");
    return `${rows.length} row(s)`;
  },
  "sand-notification-settings": async (m) => {
    const v = await m.notification_settings_async();
    return `resolved ${JSON.stringify(v)}`;
  },
  "tree-sitter": async (m) => {
    const bash = require(path.join(deps, "tree-sitter-bash"));
    const parser = new m();
    parser.setLanguage(bash);
    const type = parser.parse("echo hi | wc -l").rootNode.type;
    if (type !== "program") throw new Error(`unexpected root node ${type}`);
    return "parsed bash";
  },
};

(async () => {
  await check("asar package.json", () => {
    const pkg = JSON.parse(fs.readFileSync(path.join(asar, "package.json"), "utf8"));
    if (!fs.existsSync(path.join(asar, pkg.main))) throw new Error(`main ${pkg.main} missing`);
    if (pkg.desktopName !== "grok-bot.desktop") throw new Error(`desktopName is ${pkg.desktopName}`);
    return `version ${pkg.version}, main ${pkg.main}`;
  });

  let manifest = { required: [] };
  await check("runtime-deps-manifest.json", () => {
    manifest = JSON.parse(fs.readFileSync(path.join(deps, "runtime-deps-manifest.json"), "utf8"));
    return manifest.required.join(", ");
  });

  for (const name of manifest.required) {
    const dir = path.join(deps, name);
    await check(`require ${name}`, async () => {
      const mod = require(dir);
      // Every binding.X the wrapper re-exports must be a real function;
      // a stub that forgets one only fails later, inside the app.
      const index = path.join(dir, "index.js");
      if (fs.existsSync(index)) {
        const src = fs.readFileSync(index, "utf8");
        const rel = (src.match(/require\(\s*['"](\.\/[^'"]+\.node)['"]\s*\)/) || [])[1];
        if (rel) {
          const binding = require(path.join(dir, rel));
          const names = [...new Set([...src.matchAll(/binding\.([A-Za-z_]\w*)/g)].map((m) => m[1]))];
          const missing = names.filter((n) => typeof binding[n] !== "function");
          if (missing.length) throw new Error(`binding is missing ${missing.join(", ")}`);
        }
      }
      return functional[name] ? await functional[name](mod) : "";
    });
  }

  // No Windows binaries left where Node would load them.
  await check("no PE .node files outside win32 prebuilds", () => {
    const bad = [];
    const walk = (d) => {
      for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const p = path.join(d, e.name);
        if (e.isDirectory()) walk(p);
        else if (e.name.endsWith(".node") && !/[\\/]prebuilds[\\/]win32-/.test(p)) {
          const fd = fs.openSync(p, "r");
          const head = Buffer.alloc(2);
          fs.readSync(fd, head, 0, 2, 0);
          fs.closeSync(fd);
          if (head.toString("latin1") === "MZ") bad.push(path.relative(resources, p));
        }
      }
    };
    walk(path.join(resources, "app.asar.unpacked"));
    if (bad.length) throw new Error(bad.join(", "));
  });

  process.exit(failures ? 1 : 0);
})();
