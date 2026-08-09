#!/usr/bin/env bats
# The token, and what the radar does when it cannot use it. A personal access
# token is the only credential involved and GitLab caps its lifetime at a year,
# so noticing that it is about to run out — and being able to replace it from the
# menu — is a feature rather than an error path.
#
# Rotation deserves the care it gets here: GitLab revokes the old token the
# instant the new one is issued, so a rotation whose result is dropped locks you
# out of your own GitLab until you visit the web UI.
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup() {
  radar_setup
  radar_config
  radar_quiet_gitlab
}
teardown() { radar_teardown; }

# ------------------------------------------------------- nothing to work with

@test "no token at all explains how to get one, without calling GitLab" {
  security delete-generic-password -s gitlab-radar

  run radar

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "🦊 | color=#6e6e73" ]
  [[ "$output" == *"GitLab Radar is not set up"* ]]
  [[ "$output" == *"npx github:triffer/gitlab-radar install"* ]]
  refute_called curl
}

@test "a missing jq says which one command fixes it" {
  # the plugin is one bash script and jq does all of its JSON work, so this is
  # the one dependency a user has to install by hand
  run without_jq

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "🦊 | color=#6e6e73" ]
  [[ "$output" == *"jq is required — brew install jq"* ]]
}

@test "a GitLab that cannot be reached says so instead of going blank" {
  # offline, on the wrong side of a VPN, or a token that was revoked — from here
  # they look the same, and the answer to all three is the same too
  route "*/api/v4/user" 22 </dev/null

  run radar

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "🦊 ⚠️ | color=#ff9f0a" ]
  [[ "$output" == *"Cannot reach https://gitlab.example.com"* ]]
  [[ "$output" == *"Test token"* ]]
}

@test "the token itself never reaches a menu row" {
  # the "Test token" row runs a command that fetches the token at click time
  # rather than carrying it, because a menu row is not a secret
  run radar

  [[ "$output" != *"test-token"* ]]
}

@test "who you are is remembered rather than asked on every refresh" {
  radar >/dev/null

  radar >/dev/null

  [ "$(grep -c '/api/v4/user$' "$STUB_CALLS")" -eq 1 ]
}

# --------------------------------------------------------------- expiry warning

@test "a token that is about to run out is flagged, with one click to replace it" {
  token_expiry "$(in_days 10)"

  run radar

  # not pinned to a day count: GitLab reports the date the token dies, not the
  # moment, so "10 days from now" is nine-and-a-bit whole days away
  [[ "$output" == *"⚠️ Token expires in "* ]]
  [[ "$output" == *"click to rotate (1 year) | color=#ff9f0a bash="*"param1=--rotate"* ]]
}

@test "a token with most of its year left is not mentioned at all" {
  token_expiry "$(in_days 300)"

  run radar

  [[ "$output" != *"Token expires"* ]]
}

@test "an expired token says how long ago it went" {
  token_expiry "$(in_days -3)"

  run radar

  [[ "$output" == *"⚠️ Token EXPIRED 3d ago"* ]]
}

@test "TOKEN_WARN_DAYS decides how much notice you get" {
  # the same token, once with the default 21 days of notice and once with 60
  token_expiry "$(in_days 30)"
  run radar
  [[ "$output" != *"Token expires"* ]]

  radar_config 'TOKEN_WARN_DAYS=60'

  run radar
  [[ "$output" == *"⚠️ Token expires in "* ]]
}

@test "a token kept in the config file is never offered for rotation" {
  # rotation stores the new token in the Keychain; doing that to someone who
  # deliberately put theirs in a file would leave two tokens and no clarity
  radar_config 'GITLAB_TOKEN="config-token"'
  token_expiry "$(in_days 10)"

  run radar

  [[ "$output" == *"token is in the config file, rotate manually"* ]]
  [[ "$output" != *"param1=--rotate"* ]]
}

@test "the expiry is looked up once a day, not on every refresh" {
  token_expiry "$(in_days 300)"
  radar >/dev/null

  radar >/dev/null

  [ "$(grep -c 'personal_access_tokens/self$' "$STUB_CALLS")" -eq 1 ]
}

@test "an instance that does not report expiries simply never warns" {
  # the endpoint is missing on old GitLab and on tokens without the scope for it
  run radar

  [ "$status" -eq 0 ]
  [[ "$output" != *"Token expires"* ]]
  [[ "$output" != *"Token EXPIRED"* ]]
}

# --------------------------------------------------------------------- rotating

@test "rotating puts the new token in the Keychain" {
  token_expiry "$(in_days 10)"
  radar >/dev/null                       # caches the expiry it is about to void
  rotate_returns brand-new-token

  radar --rotate

  [ "$(keychain_token)" = "brand-new-token" ]
  # the cached expiry describes the old token, so it has to go with it
  [ ! -f "$STATE_DIR/token-info" ]
  assert_called_with osascript "Token rotated"
}

@test "a rotation GitLab refuses leaves the old token working" {
  # no rotate route: the request failed, so the old token was never revoked
  run radar --rotate

  [ "$(keychain_token)" = "test-token" ]
  assert_called_with open "personal_access_tokens"
  assert_called_with osascript "Rotation failed"
}

@test "a token in the config file is never rotated behind your back" {
  # rotation revokes the old token instantly, and the config is not ours to edit
  radar_config 'GITLAB_TOKEN="config-token"'

  run radar --rotate

  refute_called_with curl "rotate"
  assert_called_with open "personal_access_tokens"
}
