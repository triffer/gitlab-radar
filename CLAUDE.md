# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this is

**GitLab Radar** — a single-file [SwiftBar](https://swiftbar.app) menu bar plugin
(macOS) that surfaces GitLab events that otherwise only reach you by email:
broken pipelines, (re-)review requests, and new comments on your MRs. It polls
the GitLab REST API directly — no server, no webhooks. Works with gitlab.com and
self-hosted instances.

Menu bar shows: `🦊 ❌1 👀2 💬1` (dim `🦊` when all quiet).

## Layout

| File                  | Purpose                                                        |
|-----------------------|---------------------------------------------------------------|
| `gitlab-radar.3m.sh`  | **The whole plugin.** All logic lives here. The `.3m.` in the name is the SwiftBar refresh interval (every 3 min). |
| `install.sh`          | Host-side installer/uninstaller — writes config, stores the token in the macOS Keychain, copies the plugin into SwiftBar's plugin folder. |
| `README.md`           | User-facing docs (features, config table, how it works).      |

## Runtime facts

- **Language:** Bash, targeting the stock macOS **bash 3.2** — no associative
  arrays, no `${var,,}`. Keep changes 3.2-compatible.
- **Dependencies:** `bash`, `jq`, `curl` (and `security`/`open`/`afplay` from macOS).
- **Config:** `~/.config/gitlab-radar/config` (plain bash, sourced by the plugin).
- **Token:** macOS Keychain, service `gitlab-radar` (or `GITLAB_TOKEN` in config).
- **State/cache:** `~/.cache/gitlab-radar/` (read-markers, project cache, token
  info, sound snapshot).
- **Menu actions** (mark read, mark to-do done, rotate token) are the script
  **re-invoking itself** with a flag — see the `case "${1:-}"` block near the top
  (`--seen`, `--seen-all`, `--open-seen`, `--todo-done`, `--rotate`).

## How the plugin runs

SwiftBar executes `gitlab-radar.3m.sh` every 3 minutes. Each run:
1. Prints the menu-bar title line (first line of stdout).
2. Prints `---`, then dropdown rows in SwiftBar's format
   (`text | key=value key=value`), grouped into sections.

Data comes from a few API calls per refresh: `merge_requests` (yours + as
reviewer), `todos`, plus per-MR `notes`/`approvals`/`pipelines`. See the
"How it works" table in `README.md` for the exact endpoints.

## Working here

- This is macOS/SwiftBar tooling — it can't be run meaningfully inside the Linux
  sandbox (no menu bar, no Keychain). Validate changes by reading, `bash -n`
  syntax-checking, and `jq` snippet testing rather than a full run.
- Preserve the SwiftBar output format: the first stdout line is the title; `|`
  separates the label from parameters, so user text is passed through
  `sanitize()`. `--` prefixes create submenu rows.
- Match the existing style: heavy inline comments explaining *why*, `jq -r @sh`
  + `eval` to unpack JSON into shell vars, defensive `|| default` fallbacks.
