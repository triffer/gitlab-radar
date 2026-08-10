# Shared setup for the GitLab Radar bats suite.
#
# ISOLATION IS THE POINT OF THIS FILE. The suite runs the real plugin and the
# real installer, so every path they touch and every command they call has to
# land inside a throwaway tree — otherwise a test run edits the developer's own
# install, and `install.sh --uninstall` deletes their plugin and Keychain token.
#
# Redirecting HOME covers the config and the cache, but not everything:
#
#   * `defaults read com.ameba.SwiftBar PluginDirectory` resolves the home
#     directory from the password database, so it answers with the REAL plugin
#     folder no matter what HOME says. It is stubbed, and the plugin folder is
#     passed in explicitly via GITLAB_RADAR_PLUGIN_DIR.
#   * `security` would read and write the real login Keychain. It is stubbed with
#     a file-backed fake, so tests can watch a token being stored and rotated.
#   * `curl` would reach the real GitLab and the real GitHub. It is stubbed with
#     a router (see `route` and the per-endpoint helpers below): a test declares
#     the responses it wants, and every call it did not declare fails the way an
#     unreachable endpoint does.
#
# The macOS-only commands (open, afplay, osascript, pbcopy) are stubbed too, both
# because they do not exist on the Linux runner and because a test wants to
# assert they were NOT called.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PLUGIN="$REPO_ROOT/gitlab-radar.3m.sh"
INSTALLER="$REPO_ROOT/install.sh"

# Everything that would otherwise reach the real machine or the real network.
RADAR_STUBBED_COMMANDS=(curl security defaults open afplay osascript pbcopy npx)

radar_setup() {
  # Explicit template: BSD and GNU mktemp disagree about a bare `-d`, and the
  # suite has to run on both. The name also makes a leaked tree obvious.
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gitlab-radar-test.XXXXXX")"

  export HOME="$TEST_ROOT/home"
  export TMPDIR="$TEST_ROOT/tmp"
  # Never let the installer consult the real SwiftBar preferences.
  export GITLAB_RADAR_PLUGIN_DIR="$TEST_ROOT/plugins"

  CONF_DIR="$HOME/.config/gitlab-radar"
  CONF="$CONF_DIR/config"
  STAMP="$CONF_DIR/installed.sh"
  STATE_DIR="$HOME/.cache/gitlab-radar"
  STUB_CALLS="$TEST_ROOT/stub-calls.log"
  ROUTES="$TEST_ROOT/curl-routes"       # "glob<TAB>body-file<TAB>exit" lines

  mkdir -p "$HOME" "$TMPDIR" "$GITLAB_RADAR_PLUGIN_DIR" "$TEST_ROOT/bodies"
  : > "$STUB_CALLS"
  : > "$ROUTES"

  radar_install_stubs
  radar_assert_isolated

  # Every config key the plugin reads is a plain shell variable, so one already
  # in the environment is indistinguishable from one in the config file. That is
  # not hypothetical: GITLAB_TOKEN is exactly what a developer exports to talk to
  # their own GitLab from the shell, and inheriting it would silently move every
  # test off the Keychain path (TOKEN_SRC=config) while handing the plugin a real
  # token. The config file is the only source of settings in here.
  unset GITLAB_TOKEN GITLAB_URL WATCH_MR_TARGET_MAINS WATCH_MAIN_PROJECTS \
        MAX_TODOS TOKEN_WARN_DAYS
  # …and BASH_ENV with them: bash sources that file at the start of every
  # non-interactive shell, which includes the one running the plugin, so an
  # environment file that exports any of the above would put it straight back
  # after the unset. Some CI images and dev sandboxes do exactly that.
  unset BASH_ENV

  # The version row asks GitHub for the newest release once a day, in a detached
  # child whose write to the cache would race the assertions of whichever test
  # happened to trigger it. Off by default; the tests that exercise the check
  # turn it back on (and curl is stubbed regardless).
  export UPDATE_CHECK_HOURS=0
}

radar_teardown() {
  [ -n "${TEST_ROOT:-}" ] && rm -rf "$TEST_ROOT"
  return 0
}

# ---------------------------------------------------------------- the stubs

radar_install_stubs() {
  local bin="$TEST_ROOT/stub" cmd
  mkdir -p "$bin"

  # The plain ones: log the call, succeed, do nothing.
  for cmd in defaults open afplay osascript npx; do
    { printf '#!/bin/sh\n'
      printf 'printf "%%s %%s\\n" "%s" "$*" >> "%s"\n' "$cmd" "$STUB_CALLS"
      printf 'exit 0\n'
    } > "$bin/$cmd"
    chmod +x "$bin/$cmd"
  done

  # pbcopy is the one stub whose stdin is the interesting part.
  { printf '#!/bin/sh\n'
    printf 'printf "pbcopy %%s\\n" "$*" >> "%s"\n' "$STUB_CALLS"
    printf 'cat > "%s/clipboard"\n' "$TEST_ROOT"
  } > "$bin/pbcopy"
  chmod +x "$bin/pbcopy"

  # install.sh refuses to run anywhere but macOS.
  printf '#!/bin/sh\necho Darwin\n' > "$bin/uname"
  chmod +x "$bin/uname"

  radar_write_keychain_stub "$bin"
  radar_write_curl_stub "$bin"
  export PATH="$bin:$PATH"
}

# A file-backed stand-in for the login Keychain: one file per generic-password
# item, named after its service, holding the secret. Only the three invocations
# the radar makes are understood — an unknown one fails loudly rather than
# quietly reporting success, which is how a stub starts lying about the real one.
radar_write_keychain_stub() { # $1: stub dir
  KEYCHAIN="$TEST_ROOT/keychain"
  mkdir -p "$KEYCHAIN"
  cat > "$1/security" <<STUB
#!/bin/bash
printf 'security %s\n' "\$*" >> "$STUB_CALLS"
db="$KEYCHAIN"
verb=\$1; shift
service=""; secret=""; want_secret=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    -s) service=\$2; shift 2 ;;
    # "-w VALUE" sets the password, a trailing "-w" asks for it back.
    -w) if [ \$# -gt 1 ]; then secret=\$2; shift 2; else want_secret=1; shift; fi ;;
    -a) shift 2 ;;
    -U) shift ;;
    *)  shift ;;
  esac
done
item="\$db/\$service"
case "\$verb" in
  find-generic-password)
    [ -f "\$item" ] || exit 44
    [ "\$want_secret" = 1 ] && cat "\$item"
    exit 0 ;;
  add-generic-password)
    printf '%s' "\$secret" > "\$item"; exit 0 ;;
  delete-generic-password)
    [ -f "\$item" ] || exit 44
    rm -f "\$item"; exit 0 ;;
esac
echo "security stub: unhandled \$verb" >&2
exit 1
STUB
  chmod +x "$1/security"
}

# The token currently in the fake Keychain (empty when there is none).
keychain_token() { cat "$KEYCHAIN/gitlab-radar" 2>/dev/null; }

# The curl stub answers from a routing table instead of the network. The most
# recently declared route that matches the URL wins, so a test can lay down a
# whole quiet GitLab up front (radar_quiet_gitlab) and then override the one
# endpoint it is about.
#
# An unmatched URL exits 22 with no output — what `curl -f` does on an HTTP
# error. That is the interesting default: the radar is full of `|| fallback`
# paths for exactly this, and a test that forgets a route should see them.
radar_write_curl_stub() { # $1: stub dir
  cat > "$1/curl" <<STUB
#!/bin/bash
printf 'curl %s\n' "\$*" >> "$STUB_CALLS"
# The URL is the last argument in every call the radar makes.
for arg in "\$@"; do url=\$arg; done
while IFS=\$'\t' read -r glob body code; do
  [ -n "\$glob" ] || continue
  case "\$url" in
    \$glob)
      [ -s "\$body" ] && cat "\$body"
      exit "\${code:-0}" ;;
  esac
done < "$ROUTES"
exit 22
STUB
  chmod +x "$1/curl"
}

# Refuse to run at all unless everything points into the throwaway tree. A bug
# in this file must not be able to reach the developer's machine quietly.
radar_assert_isolated() {
  local var
  for var in HOME TMPDIR GITLAB_RADAR_PLUGIN_DIR; do
    case "${!var}" in
      "$TEST_ROOT"/*) ;;
      *) printf 'gitlab-radar tests: %s=%s is outside the test tree — refusing to run\n' \
           "$var" "${!var}" >&2; return 1 ;;
    esac
  done
  for var in "${RADAR_STUBBED_COMMANDS[@]}"; do
    case "$(command -v "$var" 2>/dev/null)" in
      "$TEST_ROOT"/stub/*) ;;
      "") ;;   # absent on this box (Linux runner) — nothing to reach
      *) printf 'gitlab-radar tests: %s is not stubbed — refusing to run\n' "$var" >&2
         return 1 ;;
    esac
  done
}

# ------------------------------------------------------- asserting on stubs

# Assert a host-touching command was never invoked during this test.
refute_called() { # $1: command name
  ! grep -q "^$1 " "$STUB_CALLS"
}

# Assert one was, with arguments matching a pattern.
assert_called_with() { # $1: command name  $2: grep -E pattern over its arguments
  grep -E "^$1 .*$2" "$STUB_CALLS"
}

# Assert it was never invoked with arguments matching a pattern — for the calls
# a setting is supposed to switch off, where the command itself is still used.
refute_called_with() { # $1: command name  $2: grep -E pattern over its arguments
  ! grep -E "^$1 .*$2" "$STUB_CALLS"
}

# Sounds are played in the background (`afplay … &`), so the call can land in the
# log a moment after the render has already exited. Poll rather than sleep a
# fixed amount: a flaky sound assertion would be worse than a slow one.
wait_for_call() { # $1: command name
  local i=0
  while [ "$i" -lt 50 ]; do
    grep -q "^$1 " "$STUB_CALLS" && return 0
    sleep 0.05; i=$(( i + 1 ))
  done
  return 1
}

clipboard() { cat "$TEST_ROOT/clipboard"; }

# ------------------------------------------------------------ canned answers

# Register a response for every URL matching a glob. Body on stdin. Newest route
# first, so a later declaration overrides an earlier, broader one.
route() { # $1: URL glob  $2: exit status (default 0)  stdin: response body
  local n; n=$(( $(wc -l < "$ROUTES") + 1 ))
  local body="$TEST_ROOT/bodies/$n"
  cat > "$body"
  printf '%s\t%s\t%s\n' "$1" "$body" "${2:-0}" | cat - "$ROUTES" > "$ROUTES.new"
  mv "$ROUTES.new" "$ROUTES"
}

# The endpoints the radar calls, one helper each — the URLs carry query strings
# and ids, and spelling those out in every test would bury what the test is
# actually about. Order matters (first match wins), so a test that wants one
# project to answer differently registers that one first.
whoami_is()      { route "*/api/v4/user" <<<"$(jq -nc --arg u "$1" '{username: $u}')"; }
my_mrs()         { route "*scope=created_by_me*"; }
review_mrs()     { route "*reviewer_username=*"; }
todos_are()      { route "*/api/v4/todos?*"; }
mr_detail()      { route "*/merge_requests/$1"; }            # $1: iid
notes_for()      { route "*/merge_requests/$1/notes*"; }     # $1: iid
approvals_for()  { route "*/merge_requests/$1/approvals"; }  # $1: iid
project_is()     { route "*/api/v4/projects/$1"; }           # $1: id or encoded path
pipelines_for()  { route "*/projects/$1/pipelines?ref=$2*"; } # $1: project  $2: branch
token_expiry()   { route "*/personal_access_tokens/self" <<<"$(jq -nc --arg d "$1" '{expires_at: $d}')"; }
rotate_returns() { route "*/personal_access_tokens/self/rotate*" <<<"$(jq -nc --arg t "$1" '{token: $t}')"; }
github_release() { route "*api.github.com*" <<<"$(jq -nc --arg t "$1" '{tag_name: $t}')"; }

# An ISO date this many days from now, the way GitLab reports a token expiry.
# Computed through jq because `date -d` (GNU) and `date -v` (BSD) disagree and
# the suite runs on both.
in_days() { # $1: days from now, may be negative
  jq -rn --argjson t "$(( $(date +%s) + ${1} * 86400 ))" '$t | todate | split("T")[0]'
}

# The state the radar starts from when nothing interesting is going on: it knows
# who you are, and every list is empty. Tests then override what they care about.
radar_quiet_gitlab() {
  whoami_is me
  my_mrs     <<<'[]'
  review_mrs <<<'[]'
  todos_are  <<<'[]'
}

# ------------------------------------------------------------ JSON fixtures

# One merge request, shaped like the list endpoints return it. Override any field
# with key=value, dotted for nesting: `mr iid=7 author.username=ann`. An
# all-digit value is written as a number, since project_id and iid are compared
# numerically by the to-do matching.
mr() { # key=value...
  local json kv k v
  json=$(jq -nc '{project_id: 1, iid: 1, title: "Teach the parser to count",
    web_url: "https://gitlab.example.com/g/p/-/merge_requests/1",
    references: {full: "g/p!1"}, target_branch: "main",
    updated_at: "2024-01-01T00:00:00Z", target_project_id: 1,
    author: {name: "Ann Other", username: "ann"}}')
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    case "$v" in
      true|false)  json=$(jq -c --arg k "$k" --argjson v "$v" \
                     'setpath($k | split("."); $v)' <<<"$json") ;;
      ''|*[!0-9]*) json=$(jq -c --arg k "$k" --arg v "$v" \
                     'setpath($k | split("."); $v)' <<<"$json") ;;
      *)           json=$(jq -c --arg k "$k" --argjson v "$v" \
                     'setpath($k | split("."); $v)' <<<"$json") ;;
    esac
  done
  printf '%s' "$json"
}

# The per-MR detail call: pipeline status, merge status, thread state.
mr_json() { # key=value... (same rules as mr)
  local json kv k v
  json=$(jq -nc '{head_pipeline: {status: "success",
    web_url: "https://gitlab.example.com/g/p/-/pipelines/9"},
    detailed_merge_status: "mergeable", blocking_discussions_resolved: true}')
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    case "$v" in
      true|false)  json=$(jq -c --arg k "$k" --argjson v "$v" \
                     'setpath($k | split("."); $v)' <<<"$json") ;;
      *)           json=$(jq -c --arg k "$k" --arg v "$v" \
                     'setpath($k | split("."); $v)' <<<"$json") ;;
    esac
  done
  printf '%s' "$json"
}

# A comment, as the notes endpoint returns it (newest first, hence the ids).
note() { # $1: id  $2: author username  $3: body  $4: "system" to make it a system note
  jq -nc --argjson i "$1" --arg u "$2" --arg b "${3:-looks good}" \
     --argjson s "$([ "${4:-}" = system ] && echo true || echo false)" \
     '{id: $i, system: $s, body: $b, author: {name: $u, username: $u}}'
}

# Who has approved, and how many approvals the project wants.
approvals() { # $1: approvals_required  $2: approvals_left  rest: approver usernames
  local req=$1 left=$2; shift 2
  printf '%s\n' "$@" | jq -Rsc --argjson r "$req" --argjson l "$left" \
    '{approvals_required: $r, approvals_left: $l,
      approved_by: [split("\n")[] | select(length > 0) | {user: {name: ., username: .}}]}'
}

todo() { # $1: id  $2: action_name  rest: key=value overrides (dotted, as in mr)
  local json kv k v
  json=$(jq -nc --argjson i "$1" --arg a "$2" \
    '{id: $i, action_name: $a, target_type: "MergeRequest",
      target_url: "https://gitlab.example.com/g/p/-/merge_requests/1",
      created_at: "2024-01-01T00:00:00Z", body: "have a look?",
      project: {id: 1}, target: {iid: 1, references: {full: "g/p!1"}},
      author: {name: "Ann Other", username: "ann"}}')
  shift 2
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    case "$v" in
      ''|*[!0-9]*) json=$(jq -c --arg k "$k" --arg v "$v" \
                     'setpath($k | split("."); $v)' <<<"$json") ;;
      *)           json=$(jq -c --arg k "$k" --argjson v "$v" \
                     'setpath($k | split("."); $v)' <<<"$json") ;;
    esac
  done
  printf '%s' "$json"
}

project() { # $1: default_branch  $2: path_with_namespace
  jq -nc --arg b "$1" --arg p "$2" '{default_branch: $b, path_with_namespace: $p}'
}

pipeline() { # $1: status  $2: age in seconds (default: just now)
  jq -nc --arg s "$1" --argjson t "$(( $(date +%s) - ${2:-0} ))" \
    '[{status: $s, web_url: "https://gitlab.example.com/g/p/-/pipelines/9",
       updated_at: ($t | todate)}]'
}

# Wrap objects into the JSON array a list endpoint returns.
json_array() { # $@: compact JSON objects
  [ $# -gt 0 ] || { printf '[]'; return; }
  printf '%s\n' "$@" | jq -sc .
}

# --------------------------------------------------------- the radar itself

# What the plugin needs before it will render anything: a config, and a token.
# A Keychain token rather than GITLAB_TOKEN in the config, because that is the
# supported setup — it is also what makes the rotate action and the expiry
# warning reachable.
radar_config() { # $@: extra lines for the config file
  mkdir -p "$CONF_DIR"
  { echo 'GITLAB_URL="https://gitlab.example.com"'
    # Off unless a test asks for it: on it turns every MR's target project into
    # two more API calls, which every unrelated test would have to stub.
    echo 'WATCH_MR_TARGET_MAINS=0'
    printf '%s\n' "$@"
  } > "$CONF"
  security add-generic-password -U -a tester -s gitlab-radar -w test-token
}

# Run the plugin the way SwiftBar does. UPDATE_CHECK_HOURS is exported by the
# setup, so it wins over the config unless a test overrides it.
radar() { bash "$PLUGIN" "$@"; }

# Run the plugin on a PATH with no jq on it — the state of a Mac that never got
# `brew install jq`. Only the few commands the plugin reaches before the check
# are linked in; everything else lives next to jq in /usr/bin, and linking that
# whole directory in would bring jq with it.
without_jq() {
  local bin="$TEST_ROOT/nojq" cmd
  mkdir -p "$bin"
  for cmd in bash mkdir dirname basename; do
    ln -sf "$(command -v "$cmd")" "$bin/$cmd"
  done
  PATH="$TEST_ROOT/stub:$bin" bash "$PLUGIN" "$@"
}

# Source the plugin for its functions alone — the GITLAB_RADAR_SOURCE_ONLY guard
# stops before the action modes and the render, so a test can call one function
# with no GitLab to talk to.
load_radar() {
  GITLAB_RADAR_SOURCE_ONLY=1
  # shellcheck disable=SC1090
  . "$PLUGIN"
  unset GITLAB_RADAR_SOURCE_ONLY
}

# A version stamp exactly as install.sh writes one. Anything that renders or
# acts on a version needs this: with no stamp the plugin falls back to a sibling
# package.json, which from a checkout means the repo's own.
stamp_version() { # $1: version  $2: install method  $3: install source
  mkdir -p "$CONF_DIR"
  { printf 'GITLAB_RADAR_VERSION="%s"\n' "$1"
    printf 'GITLAB_RADAR_INSTALL_METHOD="%s"\n' "${2:-npx}"
    printf 'GITLAB_RADAR_INSTALL_SOURCE="%s"\n' "${3:-}"
  } > "$STAMP"
}

# What the last update check found, and when.
put_update_cache() { # $1: latest  $2: checked (unix time)
  mkdir -p "$STATE_DIR"
  jq -n --arg l "$1" --argjson c "${2:-0}" '{latest: $l, checked: $c}' \
    > "$STATE_DIR/update.json"
}

update_cache_field() { # $1: field
  jq -r --arg f "$1" '.[$f]' "$STATE_DIR/update.json"
}

# Turn the sounds on, as the toggle at the bottom of the menu does.
sounds_on() {
  mkdir -p "$STATE_DIR"
  touch "$STATE_DIR/sounds-on"
}

# Mark comments on an MR as read up to a note id — the radar baselines an MR it
# has never seen before, so a test about new comments has to have seen it once.
mark_seen() { # $1: "project:iid"  $2: highest note id considered read
  mkdir -p "$STATE_DIR"
  [ -f "$STATE_DIR/seen-comments.json" ] || echo '{}' > "$STATE_DIR/seen-comments.json"
  jq --arg k "$1" --argjson v "$2" '.[$k] = $v' "$STATE_DIR/seen-comments.json" \
    > "$STATE_DIR/seen.tmp" && mv "$STATE_DIR/seen.tmp" "$STATE_DIR/seen-comments.json"
}

seen_field() { # $1: "project:iid"
  jq -r --arg k "$1" '.[$k] // "none"' "$STATE_DIR/seen-comments.json"
}

# Everything install.sh needs, minus the .git that decides how updates run —
# which is exactly the tree npx unpacks.
copy_source_tree() { # $1: destination
  mkdir -p "$1"
  cp "$REPO_ROOT/install.sh" "$REPO_ROOT/package.json" \
     "$REPO_ROOT/gitlab-radar.3m.sh" "$1/"
}
