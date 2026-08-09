#!/usr/bin/env bats
# /bin/bash on macOS is bash 3.2, and that is what runs the radar on the machines
# it targets. A Linux runner has bash 5, which accepts plenty that 3.2 does not —
# so the rules 3.2 imposes are checked here by scanning the sources instead, and
# the macOS job in CI runs the whole suite under the real thing.
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup()    { radar_setup; }
teardown() { radar_teardown; }

# Every shell source in the repo. Whole-line comments are dropped from the
# result: this file and the sources both spell the hazards out in prose, and a
# rule you cannot describe without tripping it is a rule nobody will document.
scan() { # $1: extended regex
  bash -c 'find "$1" \( -name "*.sh" -o -name "*.bash" \) \
             -not -path "*/node_modules/*" -not -path "*/.git/*" -print0 \
             | LC_ALL=C xargs -0 grep -nHE "$2" \
             | grep -vE "^[^:]+:[0-9]+:[[:space:]]*#"' _ "$REPO_ROOT" "$1"
}

@test "no variable is expanded straight into a non-ASCII character" {
  # bash 3.2 counts a UTF-8 lead byte as a name character, so "$VERSION…"
  # expands the variable "VERSION…" — unbound, and under set -u that aborts the
  # script. This shipped once, in the installer's own banner. ${VERSION}… is the
  # fix, and the ellipses, arrows and emoji all over these files mean the hazard
  # is one edit away at all times.
  run scan "$(printf '\\$[A-Za-z_][A-Za-z0-9_]*[^\t -~]')"

  [ -z "$output" ] || { echo "brace these expansions:"; echo "$output"; false; }
}

@test "no associative arrays" {
  # bash 3.2 has none; `declare -A` is a syntax error there, not a warning
  run scan '(declare|local|typeset) +-[a-zA-Z]*A'

  [ -z "$output" ] || { echo "bash 3.2 has no associative arrays:"; echo "$output"; false; }
}

@test "no case-changing parameter expansions" {
  # ${var,,} and ${var^^} arrived in bash 4; in 3.2 they are a bad substitution
  run scan '\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^|,|\^)\}'

  [ -z "$output" ] || { echo "bash 3.2 cannot change case in an expansion:"; echo "$output"; false; }
}

@test "every script parses under the bash running this suite" {
  # the last line of defence: on the macOS job in CI this bash IS 3.2
  for f in "$PLUGIN" "$INSTALLER"; do
    run bash -n "$f"
    [ "$status" -eq 0 ]
  done
}
