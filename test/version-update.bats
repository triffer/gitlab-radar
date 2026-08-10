#!/usr/bin/env bats
# Knowing which version is installed, and noticing when a newer one is out.
#
# The radar never installs itself, and several tests below exist to keep it that
# way: the installer is interactive (it may ask for a token) and a menu bar plugin
# is the wrong place to hide a prompt, so the menu hands you the command instead.
#
# Every test here runs with curl stubbed — a suite that really asked GitHub about
# releases would be both slow and, on a rate-limited runner, flaky.
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup() {
  radar_setup
  radar_config
  radar_quiet_gitlab
}
teardown() { radar_teardown; }

# --------------------------------------------------------- comparing versions

@test "a higher release beats the installed version" {
  load_radar

  run version_newer 1.3.0 1.2.9

  [ "$status" -eq 0 ]
}

@test "the version you already run is not an update" {
  load_radar

  run version_newer 1.2.0 1.2.0

  [ "$status" -ne 0 ]
}

@test "version fields compare as numbers, not as text" {
  load_radar

  # the string comparison every naive version check gets wrong
  run version_newer 1.10.0 1.9.0

  [ "$status" -eq 0 ]
}

@test "a zero-padded field is still read as decimal" {
  # 08 as an octal literal is an arithmetic error, which would abort the compare
  load_radar

  run version_newer 1.08.0 1.7.0

  [ "$status" -eq 0 ]
}

@test "anything that is not a plain version never counts as newer" {
  load_radar

  # the tag name arrives from the network and ends up in menu markup and a URL,
  # so anything unexpected is not treated as a version at all
  for junk in "" "dev" "v1.2.3" "1.2.3; rm -rf /" "1.2" "1.2.3-rc1"; do
    run version_newer "$junk" 0.0.1
    [ "$status" -ne 0 ]
  done
}

@test "a release links to its own notes, and an unknown version to the list" {
  load_radar

  run release_url 1.2.3
  [ "$output" = "https://github.com/triffer/gitlab-radar/releases/tag/v1.2.3" ]

  run release_url ""
  [ "$output" = "https://github.com/triffer/gitlab-radar/releases" ]
}

# ------------------------------------------------------ the update command

@test "a checkout is told to pull rather than to npx" {
  load_radar
  mkdir -p "$TEST_ROOT/checkout/.git"
  GITLAB_RADAR_INSTALL_METHOD=git
  GITLAB_RADAR_INSTALL_SOURCE="$TEST_ROOT/checkout"

  run update_command 2.0.0

  # quoted, because the path is the user's and may hold spaces
  [ "$output" = "cd \"$TEST_ROOT/checkout\" && git pull && ./install.sh" ]
}

@test "an npx install is given the command pinned at the new release" {
  load_radar
  GITLAB_RADAR_INSTALL_METHOD=npx

  run update_command 2.0.0

  [ "$output" = "npx github:triffer/gitlab-radar#v2.0.0 install" ]
}

@test "a checkout that has been moved away falls back to npx" {
  load_radar
  GITLAB_RADAR_INSTALL_METHOD=git
  GITLAB_RADAR_INSTALL_SOURCE="$TEST_ROOT/moved-away"

  run update_command 2.0.0

  [ "$output" = "npx github:triffer/gitlab-radar#v2.0.0 install" ]
}

@test "with no release to pin to, the command installs the newest there is" {
  load_radar
  GITLAB_RADAR_INSTALL_METHOD=npx

  run update_command ""

  [ "$output" = "npx github:triffer/gitlab-radar install" ]
}

# --------------------------------------------------------------- the check

@test "a check records the release GitHub reports" {
  load_radar
  github_release v1.5.0

  update_fetch 1000

  [ "$(update_cache_field latest)" = "1.5.0" ]
  [ "$(update_cache_field checked)" = "1000" ]
}

@test "an unreachable GitHub leaves the last answer standing" {
  load_radar
  put_update_cache 1.4.0 1000

  run update_fetch 2000

  [ "$status" -ne 0 ]
  [ "$(update_cache_field latest)" = "1.4.0" ]
}

@test "a release name that is not a version is not recorded" {
  load_radar
  put_update_cache 1.4.0 1000
  github_release nightly-2024-01-01

  run update_fetch 2000

  [ "$status" -ne 0 ]
  [ "$(update_cache_field latest)" = "1.4.0" ]
}

@test "a corrupt cache reads back as never checked" {
  load_radar
  mkdir -p "$STATE_DIR"
  printf 'not json at all' > "$STATE_DIR/update.json"

  update_cache_read

  [ "$LAST_CHECKED" = "0" ]
  [ -z "$LATEST_VERSION" ]
}

@test "a cache with junk in its fields reads back as never checked" {
  # the file is ours, but a half-written one from a killed refresh is not
  load_radar
  put_update_cache "totally-not-a-version" 0
  jq '.checked = "soon"' "$STATE_DIR/update.json" > "$STATE_DIR/u" && mv "$STATE_DIR/u" "$STATE_DIR/update.json"

  update_cache_read

  [ "$LAST_CHECKED" = "0" ]
  [ -z "$LATEST_VERSION" ]
}

# ------------------------------------------------------ what the menu shows

@test "the last row names the version you are running" {
  stamp_version 1.2.0

  run radar

  [[ "$output" == *"GitLab Radar v1.2.0"* ]]
}

@test "a config that sets the version cannot shadow the real one" {
  # the config is user-edited bash sourced into the plugin's own shell, which is
  # why the stamp is read after it and not before
  radar_config 'GITLAB_RADAR_VERSION="99.0.0"'
  stamp_version 1.2.0

  run radar

  [[ "$output" == *"GitLab Radar v1.2.0"* ]]
  [[ "$output" != *"v99.0.0"* ]]
}

@test "an unstamped checkout reports the version it would install" {
  # no installed.sh: the plugin falls back to the package.json beside it
  run radar

  [[ "$output" == *"GitLab Radar v$(jq -r .version "$REPO_ROOT/package.json")"* ]]
}

@test "a hand-edited stamp that is not a version renders as dev" {
  stamp_version "1.2.0-my-build"

  run radar

  [[ "$output" == *"GitLab Radar vdev"* ]]
}

@test "a newer release links to its notes and offers the command" {
  stamp_version 1.0.0
  put_update_cache 2.0.0 "$(date +%s)"

  run radar

  [[ "$output" == *"⬆ GitLab Radar 2.0.0 available — read the release notes"* ]]
  [[ "$output" == *"href=https://github.com/triffer/gitlab-radar/releases/tag/v2.0.0"* ]]
  [[ "$output" == *"↳ you have v1.0.0 · copy the update command"* ]]
}

@test "an older release on GitHub is not offered as an update" {
  stamp_version 2.0.0
  put_update_cache 1.0.0 "$(date +%s)"

  run radar

  [[ "$output" != *"available"* ]]
  [[ "$output" == *"GitLab Radar v2.0.0"* ]]
}

@test "an unstamped install never claims an update is waiting" {
  # both halves have to be real versions, so "dev" simply never compares
  stamp_version "dev"
  put_update_cache 2.0.0 "$(date +%s)"

  run radar

  [[ "$output" != *"available"* ]]
  [[ "$output" == *"GitLab Radar vdev"* ]]
}

@test "no row in the menu ever runs the installer" {
  # the installer is interactive; opening a terminal from a plugin also costs an
  # Apple Events permission dialog
  stamp_version 1.0.0
  put_update_cache 2.0.0 "$(date +%s)"

  run radar

  [[ "$output" != *"terminal=true"* ]]
  refute_called npx
}

# ------------------------------------------------------- how often it checks

@test "a due check is stamped before the network call, not after" {
  # the fetch is detached; the stamp is what stops the next refresh — three
  # minutes away — from starting another one on a machine that is offline
  radar_config 'UPDATE_CHECK_HOURS=24'
  stamp_version 1.0.0

  radar >/dev/null

  [ "$(update_cache_field checked)" != "0" ]
}

@test "a check that just ran is not repeated" {
  radar_config 'UPDATE_CHECK_HOURS=24'
  stamp_version 1.0.0
  put_update_cache 1.0.0 "$(date +%s)"

  radar >/dev/null

  refute_called_with curl "api.github.com"
}

@test "UPDATE_CHECK_HOURS=0 never asks GitHub anything" {
  stamp_version 1.0.0

  radar >/dev/null

  refute_called_with curl "api.github.com"
  [ ! -f "$STATE_DIR/update.json" ]
}

@test "a nonsense UPDATE_CHECK_HOURS falls back to the default rather than failing" {
  # the config is hand-edited, and "24h" is the obvious thing to type
  radar_config 'UPDATE_CHECK_HOURS="24h"'
  stamp_version 1.0.0

  run radar

  [ "$status" -eq 0 ]
  [ "$(update_cache_field checked)" != "0" ]
}

# --------------------------------------------------------- the two actions

@test "checking on demand asks GitHub right away" {
  # what ⌥-clicking the version row does, and the only check left when the
  # periodic one is switched off
  stamp_version 1.0.0
  github_release v9.9.9

  radar --check-update

  [ "$(update_cache_field latest)" = "9.9.9" ]
}

@test "a failed on-demand check says so instead of failing silently" {
  stamp_version 1.0.0

  radar --check-update

  assert_called_with osascript "Update check failed"
}

@test "copying the update command puts it on the clipboard and nothing else" {
  stamp_version 1.0.0 npx
  put_update_cache 2.0.0 "$(date +%s)"

  radar --copy-update

  [ "$(clipboard)" = "npx github:triffer/gitlab-radar#v2.0.0 install" ]
  refute_called npx
  assert_called_with osascript "copied to the clipboard"
}

@test "a checkout gets the command that updates a checkout" {
  mkdir -p "$TEST_ROOT/my checkout/.git"
  stamp_version 1.0.0 git "$TEST_ROOT/my checkout"
  put_update_cache 2.0.0 "$(date +%s)"

  radar --copy-update

  [ "$(clipboard)" = "cd \"$TEST_ROOT/my checkout\" && git pull && ./install.sh" ]
}
