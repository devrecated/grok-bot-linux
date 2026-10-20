"use strict";

/**
 * Electron entry for the legacy-macOS rebuild (scripts/build-macos.sh).
 *
 * The in-app updater is turned off: an official update would replace this
 * app with the stock build, whose Electron does not start on this macOS.
 * Rebuild with `make mac` to update instead.
 */

process.env.SAND_DISABLE_UPDATES = "1";

require("./dist/electron-main/main.cjs");
