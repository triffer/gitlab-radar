#!/usr/bin/env node
"use strict";

// Thin Node wrapper around the bundled install.sh so GitLab Radar can be
// installed and driven via npm/npx. All the real work lives in ../install.sh —
// this file only maps subcommands to it and keeps the UX friendly.
//
// stdio is inherited on purpose: the installer prompts for the GitLab URL and
// reads the token with `read -rs`, which needs the real terminal.

const { spawnSync } = require("child_process");
const path = require("path");
const fs = require("fs");
const os = require("os");

const ROOT = path.join(__dirname, "..");
const INSTALLER = path.join(ROOT, "install.sh");

const HELP = `gitlab-radar — GitLab pipelines, review requests and MR comments in your macOS menu bar

Usage:
  gitlab-radar install      Install / upgrade (config, Keychain token, SwiftBar plugin)
  gitlab-radar uninstall    Remove plugin, token and cache (keeps your config)
  gitlab-radar version      Show this package's version and the installed one
  gitlab-radar help         Show this help

Prerequisites (npm can't install these):
  brew install jq
  brew install --cask swiftbar   # then launch it and pick a plugin folder

Docs: https://github.com/triffer/gitlab-radar
`;

function run(args) {
  const res = spawnSync("bash", [INSTALLER, ...args], { stdio: "inherit" });
  if (res.error) {
    console.error(`gitlab-radar: failed to run installer: ${res.error.message}`);
    process.exit(1);
  }
  process.exit(res.status == null ? 1 : res.status);
}

function packageVersion() {
  try {
    return require(path.join(ROOT, "package.json")).version || "unknown";
  } catch {
    return "unknown";
  }
}

// The plugin ends up in SwiftBar's plugin folder, nowhere near a package.json;
// install.sh stamps the version it installed into the config directory instead.
function installedVersion() {
  try {
    const stamp = fs.readFileSync(
      path.join(os.homedir(), ".config/gitlab-radar/installed.sh"),
      "utf8",
    );
    const m = stamp.match(/^GITLAB_RADAR_VERSION="(.*)"$/m);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

function printVersion() {
  const pkg = packageVersion();
  const installed = installedVersion();
  console.log(`gitlab-radar ${pkg}`);
  if (installed === null) {
    console.log("not installed yet — run: gitlab-radar install");
  } else if (installed !== pkg) {
    console.log(`installed: ${installed} — run \`gitlab-radar install\` to upgrade to ${pkg}`);
  } else {
    console.log("installed: up to date");
  }
}

function main() {
  const cmd = (process.argv[2] || "").toLowerCase();

  if (cmd === "help" || cmd === "--help" || cmd === "-h" || cmd === "") {
    process.stdout.write(HELP);
    process.exit(cmd === "" ? 1 : 0);
  }

  // Above the macOS guard on purpose: which version you have is worth answering anywhere.
  if (cmd === "version" || cmd === "--version" || cmd === "-v") {
    printVersion();
    process.exit(0);
  }

  if (process.platform !== "darwin") {
    console.error("gitlab-radar only runs on macOS (it needs SwiftBar and the Keychain).");
    process.exit(1);
  }

  if (!fs.existsSync(INSTALLER)) {
    console.error(`gitlab-radar: installer not found at ${INSTALLER}`);
    process.exit(1);
  }

  switch (cmd) {
    case "install":
    case "upgrade":
    case "update":
      run([]);
      break;
    case "uninstall":
    case "remove":
      run(["--uninstall"]);
      break;
    default:
      console.error(`gitlab-radar: unknown command "${cmd}"\n`);
      process.stdout.write(HELP);
      process.exit(1);
  }
}

main();
