#!/usr/bin/env bats
# install.sh writes the user's real config, stores a token in the real Keychain
# and copies the plugin into SwiftBar's real plugin folder — so it gets run for
# real here, against a throwaway HOME with the host-touching commands stubbed
# (see helper.bash for why redirecting HOME alone is not enough).
#
# The installer is also interactive: with no config it asks for the GitLab URL,
# and with no stored token it reads one with `read -rs`. Both come from stdin
# below, which is exactly how the npx wrapper feeds it a terminal.
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup() {
  radar_setup
  PLUGIN_FILE="$GITLAB_RADAR_PLUGIN_DIR/gitlab-radar.3m.sh"
}
teardown() { radar_teardown; }

# A first install: nothing on disk, so both prompts are answered.
install_fresh() {
  printf '%s\n%s\n' "https://gitlab.example.com" "typed-token" | bash "$INSTALLER" "$@"
}

# A re-run, which asks nothing as long as the config and the token are there.
install_again() { bash "$INSTALLER" "$@"; }

# One field of the version stamp install.sh generated. A helper rather than a
# multi-line `( . installed.sh; [ … ] )` inside each test, because bats blames a
# failing multi-line compound command on an earlier line of the test.
stamp() { # $1: variable name
  ( . "$STAMP"; printf '%s' "${!1-}" )
}

# ------------------------------------------------------------- a fresh install

@test "a fresh install writes the config, stores the token and installs the plugin" {
  run install_fresh

  [ "$status" -eq 0 ]
  [ -f "$CONF" ]
  [ "$(keychain_token)" = "typed-token" ]
  [ -x "$PLUGIN_FILE" ]
  [ -f "$STAMP" ]
}

@test "the generated config carries every key the plugin reads, and is valid bash" {
  install_fresh

  bash -n "$CONF"

  for key in GITLAB_URL WATCH_MR_TARGET_MAINS WATCH_MAIN_PROJECTS MAX_TODOS \
             TOKEN_WARN_DAYS UPDATE_CHECK_HOURS; do
    grep -q "^$key=" "$CONF"
  done
  ( . "$CONF"
    [ "$WATCH_MR_TARGET_MAINS" = "1" ] && [ "$MAX_TODOS" = "8" ] \
      && [ "$TOKEN_WARN_DAYS" = "21" ] && [ "$UPDATE_CHECK_HOURS" = "24" ] )
}

@test "the GitLab URL you type is the one the config gets" {
  printf '%s\n%s\n' "https://gitlab.internal.example/" "typed-token" | bash "$INSTALLER"

  ( . "$CONF"; [ "$GITLAB_URL" = "https://gitlab.internal.example/" ] )
}

@test "answering nothing means gitlab.com" {
  printf '\n%s\n' "typed-token" | bash "$INSTALLER"

  ( . "$CONF"; [ "$GITLAB_URL" = "https://gitlab.com" ] )
}

@test "the token goes into the Keychain and never into the config" {
  install_fresh

  ! grep -q "typed-token" "$CONF"
  [ "$(keychain_token)" = "typed-token" ]
}

@test "an install with no token entered is refused rather than half-done" {
  # a config and a plugin with no token behind them would just render the
  # "not set up" menu, and the stamp would claim the install worked
  run bash "$INSTALLER" <<<$'https://gitlab.example.com\n\n'

  [ "$status" -ne 0 ]
  [ ! -f "$STAMP" ]
}

@test "the token is verified, and you are told whose it is" {
  whoami_is tester

  run install_fresh

  [[ "$output" == *"token verified — hello @tester"* ]]
}

@test "a token that cannot be verified is a warning, not a failed install" {
  # offline, or behind a VPN that is not up yet — the plugin retries every three
  # minutes anyway, so refusing to finish here would help nobody
  run install_fresh

  [ "$status" -eq 0 ]
  [[ "$output" == *"could not verify the token"* ]]
  [ -x "$PLUGIN_FILE" ]
}

# ------------------------------------------------------------- the version stamp

@test "the install stamps what it put down, and how to update it later" {
  install_fresh

  # nothing on the installed side sits next to a package.json, so this stamp is
  # the only place the running version exists
  [ "$(stamp GITLAB_RADAR_VERSION)" = "$(jq -r .version "$REPO_ROOT/package.json")" ]
  [ "$(stamp GITLAB_RADAR_INSTALL_METHOD)" = "git" ]     # this repo is a checkout
  [ "$(stamp GITLAB_RADAR_INSTALL_SOURCE)" = "$REPO_ROOT" ]
}

@test "an install without git history updates through npx instead" {
  # what npx leaves behind: the files, and no .git to pull
  copy_source_tree "$TEST_ROOT/npx-cache"

  printf '%s\n%s\n' "https://gitlab.example.com" "typed-token" \
    | bash "$TEST_ROOT/npx-cache/install.sh"

  [ "$(stamp GITLAB_RADAR_INSTALL_METHOD)" = "npx" ]
}

@test "the stamp survives a source path made of shell syntax" {
  # it is sourced as bash, and nobody's directory names are our business
  local weird="$TEST_ROOT/it's \$HOME \`now\`"
  copy_source_tree "$weird"

  printf '%s\n%s\n' "https://gitlab.example.com" "typed-token" \
    | bash "$weird/install.sh"

  [ "$(stamp GITLAB_RADAR_INSTALL_SOURCE)" = "$weird" ]
}

@test "the stamp is written last, so an aborted install never claims success" {
  run bash "$INSTALLER" <<<$'https://gitlab.example.com\n\n'

  [ "$status" -ne 0 ]
  [ -f "$CONF" ]          # the config was already written
  [ ! -f "$STAMP" ]       # but nothing says a version is installed
}

# -------------------------------------------------------------- running it again

@test "a second install keeps the config and the token it already found" {
  install_fresh

  run install_again

  [ "$status" -eq 0 ]
  [ "$(keychain_token)" = "typed-token" ]
  [[ "$output" == *"keychain token found"* ]]
}

@test "upgrading appends only the keys this version added, keeping your edits" {
  mkdir -p "$CONF_DIR"
  cat > "$CONF" <<'EOF'
# my own notes
GITLAB_URL="https://gitlab.internal.example"
MAX_TODOS=42
EOF

  printf '%s\n' "typed-token" | bash "$INSTALLER"

  ( . "$CONF"
    [ "$GITLAB_URL" = "https://gitlab.internal.example" ]   # untouched
    [ "$MAX_TODOS" = "42" ]                                 # untouched
    [ "$TOKEN_WARN_DAYS" = "21" ]                           # appended
    [ "$UPDATE_CHECK_HOURS" = "24" ] )                      # appended
  [ "$(grep -c '^GITLAB_URL=' "$CONF")" -eq 1 ]
  grep -q 'my own notes' "$CONF"
}

@test "upgrading twice is a no-op the second time" {
  install_fresh
  local before; before=$(cksum < "$CONF")

  install_again

  [ "$(cksum < "$CONF")" = "$before" ]
}

@test "a re-install replaces the plugin with the current one" {
  install_fresh
  printf 'stale\n' > "$PLUGIN_FILE"

  install_again

  cmp -s "$REPO_ROOT/gitlab-radar.3m.sh" "$PLUGIN_FILE"
}

# ------------------------------------------------------------------- SwiftBar

@test "install never consults the real SwiftBar preferences" {
  run install_fresh

  # `defaults` ignores $HOME — it resolves the home from the password database —
  # so consulting it at all would return the developer's real plugin folder, and
  # the next line would install into it
  [ "$status" -eq 0 ]
  refute_called defaults
}

@test "installing the plugin repaints the menu bar right away" {
  install_fresh

  assert_called_with open "swiftbar://refreshallplugins"
}

@test "SwiftBar not being set up is explained rather than ignored" {
  # the one prerequisite npm cannot install for you
  export GITLAB_RADAR_PLUGIN_DIR="$TEST_ROOT/no-such-folder"

  run install_fresh

  [ "$status" -eq 0 ]
  [[ "$output" == *"SwiftBar not set up"* ]]
  [[ "$output" == *"brew install --cask swiftbar"* ]]
}

@test "the installed plugin renders from SwiftBar's folder with no checkout nearby" {
  # the whole point of the stamp: the plugin ends up somewhere with no
  # package.json and no repo next to it
  install_fresh
  radar_quiet_gitlab

  run bash "$PLUGIN_FILE"

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "🦊 | color=#6e6e73" ]
  [[ "$output" == *"GitLab Radar v$(jq -r .version "$REPO_ROOT/package.json")"* ]]
}

# ------------------------------------------------------------------- uninstall

@test "uninstall removes the plugin, the token, the cache and the stamp" {
  install_fresh
  mkdir -p "$STATE_DIR"; touch "$STATE_DIR/seen-comments.json"

  run install_again --uninstall

  [ "$status" -eq 0 ]
  [ ! -e "$PLUGIN_FILE" ]
  [ -z "$(keychain_token)" ]
  [ ! -d "$STATE_DIR" ]
  [ ! -f "$STAMP" ]
}

@test "uninstall keeps the config, and says that it did" {
  # it holds the instance URL and whatever the user tuned; re-installing later
  # should not mean answering the prompts again
  install_fresh

  run install_again --uninstall

  [ -f "$CONF" ]
  [[ "$output" == *"kept: $CONF"* ]]
}

@test "uninstall never consults the real SwiftBar preferences" {
  install_fresh
  : > "$STUB_CALLS"

  run install_again --uninstall

  # this is the path that would delete a developer's installed plugin
  [ "$status" -eq 0 ]
  refute_called defaults
}

@test "uninstalling what was never installed is not an error" {
  run install_again --uninstall

  [ "$status" -eq 0 ]
}

# ----------------------------------------------------------------- refusals

@test "an unknown option is refused rather than guessed at" {
  run install_again --reinstall-everything

  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "the installer refuses to run anywhere but macOS" {
  # it writes to the Keychain and to SwiftBar's folder; neither exists elsewhere,
  # and a sandbox is where you would most easily run it by mistake
  printf '#!/bin/sh\necho Linux\n' > "$TEST_ROOT/stub/uname"

  run install_fresh

  [ "$status" -ne 0 ]
  [[ "$output" == *"Run this on your Mac host"* ]]
  [ ! -f "$CONF" ]
}
