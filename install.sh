#!/bin/bash
# Installer for GitLab Radar (SwiftBar menu bar plugin).
#
# Run on your Mac host (not inside a sandbox):
#   ./gitlab-radar/install.sh              install / upgrade
#   ./gitlab-radar/install.sh --uninstall  remove plugin + keychain token (keeps config)
#
# Idempotent: safe to re-run after pulling updates to this repo. The token is
# stored in the macOS Keychain (service "gitlab-radar"), never in a file.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF_DIR="$HOME/.config/gitlab-radar"
CONF="$CONF_DIR/config"
PLUGIN="gitlab-radar.3m.sh"
KEYCHAIN_SERVICE="gitlab-radar"

info()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()   { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Run this on your Mac host, not inside a sandbox."
command -v jq >/dev/null 2>&1 || die "jq is required: brew install jq"

plugin_dir() { defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true; }

uninstall() {
  echo "Uninstalling GitLab Radar…"
  local pd; pd=$(plugin_dir)
  [ -n "$pd" ] && rm -f "$pd/$PLUGIN"
  security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
  rm -rf "$HOME/.cache/gitlab-radar"
  info "plugin, keychain token and cache removed"
  warn "kept: $CONF (delete manually if unwanted)"
  exit 0
}

for arg in "$@"; do
  case "$arg" in
    --uninstall) uninstall ;;
    *) die "unknown option: $arg (use --uninstall)" ;;
  esac
done

echo "Installing GitLab Radar…"

# 1. Config (created once; kept on re-install) --------------------------------
mkdir -p "$CONF_DIR"
if [ ! -f "$CONF" ]; then
  printf 'GitLab base URL [https://gitlab.com]: '
  read -r GL_URL
  GL_URL=${GL_URL:-https://gitlab.com}
  cat > "$CONF" <<EOF
# GitLab Radar configuration — plain bash, sourced by the menu bar plugin.

# Your GitLab instance.
GITLAB_URL="$GL_URL"

# Watch the default-branch pipeline of every project you have an open MR in
# (0 = off). Broken ones show up under BROKEN BUILDS.
WATCH_MR_TARGET_MAINS=1

# Extra projects whose default branch to watch, space separated.
# "group/project" watches the default branch, "group/project:branch" a
# specific one. Example:
#   WATCH_MAIN_PROJECTS="platform/api platform/frontend:develop"
WATCH_MAIN_PROJECTS=""

# Max to-do rows (mentions, replies, …) in the dropdown.
MAX_TODOS=8

# Warn this many days before the access token expires (GitLab caps token
# lifetime at 1 year, so this fires roughly yearly). The warning row offers
# one-click rotation via the API.
TOKEN_WARN_DAYS=21

# Escape hatch: set GITLAB_TOKEN here to skip the Keychain (not recommended).
#GITLAB_TOKEN=""
EOF
  info "config created: $CONF"
else
  # Upgrade path: append keys this version introduced, keep everything else.
  if ! grep -q '^TOKEN_WARN_DAYS=' "$CONF"; then
    printf '\n# Warn this many days before the access token expires (one-click rotate).\nTOKEN_WARN_DAYS=21\n' >> "$CONF"
    info "config upgraded: TOKEN_WARN_DAYS added"
  fi
  info "config kept: $CONF"
fi

# 2. Token in the Keychain ------------------------------------------------------
if security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
  info "keychain token found (service: $KEYCHAIN_SERVICE) — kept"
  warn "to replace it: security add-generic-password -U -a \"\$USER\" -s $KEYCHAIN_SERVICE -w"
else
  GL_URL=$(. "$CONF" 2>/dev/null; echo "${GITLAB_URL:-https://gitlab.com}")
  echo
  echo "  Create a personal access token with scope 'api' (needed for 'mark"
  echo "  to-do done' and one-click token rotation; use 'read_api' if you can"
  echo "  live without both). Set the expiry to the maximum (1 year) — the"
  echo "  radar warns before it runs out and can rotate it for you:"
  echo "    ${GL_URL%/}/-/user_settings/personal_access_tokens"
  echo
  printf '  Paste token (input hidden): '
  read -rs GL_TOKEN; echo
  [ -n "$GL_TOKEN" ] || die "no token entered"
  security add-generic-password -U -a "$USER" -s "$KEYCHAIN_SERVICE" -w "$GL_TOKEN"
  unset GL_TOKEN
  info "token stored in Keychain (service: $KEYCHAIN_SERVICE)"
fi

# 3. Verify the token works -----------------------------------------------------
GL_URL=$(. "$CONF" 2>/dev/null; echo "${GITLAB_URL:-https://gitlab.com}")
who=$(curl -sf --max-time 15 \
  -H "PRIVATE-TOKEN: $(security find-generic-password -s "$KEYCHAIN_SERVICE" -w)" \
  "${GL_URL%/}/api/v4/user" | jq -r '.username // empty' || true)
if [ -n "$who" ]; then
  info "token verified — hello @$who"
else
  warn "could not verify the token against ${GL_URL%/} (offline/VPN?) — the plugin will retry"
fi

# 4. SwiftBar plugin --------------------------------------------------------------
PD=$(plugin_dir)
if [ -n "$PD" ] && [ -d "$PD" ]; then
  install -m 0755 "$SCRIPT_DIR/$PLUGIN" "$PD/$PLUGIN"
  open -g "swiftbar://refreshallplugins" 2>/dev/null || true
  info "SwiftBar plugin installed to $PD"
else
  warn "SwiftBar not set up — the radar needs it:"
  warn "  brew install --cask swiftbar   # then launch it and pick a plugin folder"
  warn "  re-run: ./gitlab-radar/install.sh"
fi

echo
echo "Done. A 🦊 appears in the menu bar; counts light up when something needs you."
echo "First Keychain access from SwiftBar may prompt — choose 'Always Allow'."
