#!/usr/bin/env bash
# <xbar.title>GitLab Radar</xbar.title>
# <xbar.desc>Broken pipelines, review requests and new MR comments from GitLab in the menu bar.</xbar.desc>
# <xbar.dependencies>bash, jq, curl</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>false</swiftbar.hideLastUpdated>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# Menu bar title: 🔴 broken pipelines · 👀 MRs awaiting your review · 💬 unread
# comments on your MRs or ones you're reviewing (zero counts hidden; a dim 🦊
# when all quiet).
#
# Config: ~/.config/gitlab-radar/config (plain bash, see install.sh).
# Token:  macOS Keychain item "gitlab-radar" (or GITLAB_TOKEN in the config).
#
# Written for the stock macOS bash 3.2 — no associative arrays, no ${var,,}.

CONF="$HOME/.config/gitlab-radar/config"
STATE_DIR="$HOME/.cache/gitlab-radar"
mkdir -p "$STATE_DIR"
[ -f "$CONF" ] && . "$CONF" 2>/dev/null

GITLAB_URL="${GITLAB_URL:-https://gitlab.com}"
GITLAB_URL="${GITLAB_URL%/}"
API="$GITLAB_URL/api/v4"
WATCH_MR_TARGET_MAINS="${WATCH_MR_TARGET_MAINS:-1}"
WATCH_MAIN_PROJECTS="${WATCH_MAIN_PROJECTS:-}"
MAX_TODOS="${MAX_TODOS:-8}"
TOKEN_WARN_DAYS="${TOKEN_WARN_DAYS:-21}"

RED="#ff453a"; ORANGE="#ff9f0a"; GREEN="#32d74b"; BLUE="#0a84ff"; GRAY="#8e8e93"; DIM="#6e6e73"
TAB=$'\t'

SEEN="$STATE_DIR/seen-comments.json"
PENDING_MAX="$STATE_DIR/pending-max.json"
SNAPSHOT="$STATE_DIR/last-state"
SOUNDS_FLAG="$STATE_DIR/sounds-on"
PROJ_CACHE="$STATE_DIR/projects.json"
ME_CACHE="$STATE_DIR/me"
[ -f "$SEEN" ] || echo '{}' > "$SEEN"
[ -f "$PROJ_CACHE" ] || echo '{}' > "$PROJ_CACHE"

# Absolute path to this script, for self-invoking menu actions (mark read, …).
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

if [ -n "${GITLAB_TOKEN:-}" ]; then
  TOKEN="$GITLAB_TOKEN"; TOKEN_SRC="config"
else
  TOKEN="$(security find-generic-password -s gitlab-radar -w 2>/dev/null || true)"
  TOKEN_SRC="keychain"
fi

api()      { curl -sf --max-time 15 -H "PRIVATE-TOKEN: $TOKEN" "$API/$1"; }
api_post() { curl -sf --max-time 15 -X POST -H "PRIVATE-TOKEN: $TOKEN" "$API/$1" >/dev/null; }

seen_set() { # $1 key ("pid:iid"), $2 highest note id considered read
  local tmp; tmp=$(mktemp)
  jq --arg k "$1" --argjson v "$2" '.[$k] = $v' "$SEEN" > "$tmp" && mv "$tmp" "$SEEN"
}

diff_new_comments() { # $1 = notes json; uses global $key; sets cur_max/new_n/new_author/new_body/new_note_id
  local notes="$1" last_seen
  last_seen=$(jq -r --arg k "$key" '.[$k] // "none"' "$SEEN")
  cur_max=$(jq -r --arg me "$me" \
    '[.[] | select(.system == false and .author.username != $me) | .id] | max // 0' <<<"$notes")
  new_n=0; new_author=""; new_body=""; new_note_id=0
  if [ "$last_seen" = "none" ]; then
    seen_set "$key" "$cur_max"
  else
    eval "$(jq -r --arg me "$me" --argjson last "$last_seen" '
      [ .[] | select(.system == false and .author.username != $me and .id > $last) ]
      | sort_by(.id)
      | @sh "new_n=\(length)
        new_author=\(if length > 0 then .[-1].author.name else "" end)
        new_body=\(if length > 0 then (.[-1].body | .[0:90]) else "" end)
        new_note_id=\(if length > 0 then .[-1].id else 0 end)"' <<<"$notes")"
  fi
}

notify() { # macOS notification for feedback from menu actions
  command -v osascript >/dev/null 2>&1 && \
    osascript -e "display notification \"$1\" with title \"GitLab Radar\"" 2>/dev/null
}

# ---- menu action mode (SwiftBar invokes us with arguments, refresh=true) ----
case "${1:-}" in
  --seen)       seen_set "$2" "${3:-0}"; exit 0 ;;
  --rotate)     # rotate the token via the API and store the new one in the Keychain.
                # Rotation revokes the old token instantly, so never rotate unless
                # the new one has a safe place to go.
                if [ "$TOKEN_SRC" != "keychain" ] || ! command -v security >/dev/null 2>&1; then
                  notify "Token comes from the config file — rotate it manually"
                  open "$GITLAB_URL/-/user_settings/personal_access_tokens" 2>/dev/null || true
                  exit 0
                fi
                exp=$(date -v+364d +%Y-%m-%d 2>/dev/null || date -d "+364 days" +%Y-%m-%d)
                new=$(curl -sf --max-time 15 -X POST -H "PRIVATE-TOKEN: $TOKEN" \
                  "$API/personal_access_tokens/self/rotate?expires_at=$exp" \
                  | jq -r '.token // empty')
                if [ -n "$new" ]; then
                  security add-generic-password -U -a "$USER" -s gitlab-radar -w "$new"
                  rm -f "$STATE_DIR/token-info"
                  notify "Token rotated — valid until $exp"
                else
                  notify "Rotation failed (needs 'api' scope + GitLab ≥ 16.10) — opening token settings"
                  open "$GITLAB_URL/-/user_settings/personal_access_tokens" 2>/dev/null || true
                fi
                exit 0 ;;
  --open-seen)  seen_set "$3" "${4:-0}"; open "$2"; exit 0 ;;
  --seen-all)   # merge the per-MR maxima recorded on the last render
                if [ -s "$PENDING_MAX" ]; then
                  tmp=$(mktemp)
                  jq -s '.[0] * .[1]' "$SEEN" "$PENDING_MAX" > "$tmp" && mv "$tmp" "$SEEN"
                fi
                exit 0 ;;
  --todo-done)  api_post "todos/$2/mark_as_done" || true; exit 0 ;;
esac

# ---- preconditions -----------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "🦊 | color=$DIM"; echo "---"; echo "jq is required — brew install jq"
  exit 0
fi
if [ -z "$TOKEN" ]; then
  echo "🦊 | color=$DIM"
  echo "---"
  echo "GitLab Radar is not set up | color=$ORANGE"
  echo "Run gitlab-radar/install.sh from the workbench repo | color=$GRAY"
  echo "It stores your token in the Keychain (service: gitlab-radar) | size=11 color=$GRAY"
  exit 0
fi

now=$(date +%s)

age_str() {
  local s=$1
  (( s < 0 )) && s=0
  if   (( s < 60 ));    then echo "${s}s"
  elif (( s < 3600 ));  then echo "$(( s / 60 ))m"
  elif (( s < 86400 )); then echo "$(( s / 3600 ))h"
  else                       echo "$(( s / 86400 ))d"
  fi
}

sanitize() { # keep SwiftBar markup safe: "|" is the parameter separator
  local t=${1//|/¦}; printf '%s' "${t//$'\n'/ }"
}

pipe_icon() {
  case "$1" in
    success)            echo "🟢" ;;
    failed)             echo "❌" ;;
    running|preparing)  echo "🔵" ;;
    pending|created|waiting_for_resource|scheduled) echo "⏳" ;;
    canceled|canceling|skipped) echo "⚪️" ;;
    *)                  echo "▫️" ;;
  esac
}

# ---- who am I (cached for a day) ---------------------------------------------
me=""
if [ -f "$ME_CACHE" ]; then
  me_ts=$(head -1 "$ME_CACHE" 2>/dev/null); me=$(tail -1 "$ME_CACHE" 2>/dev/null)
  [ -n "$me_ts" ] && (( now - me_ts > 86400 )) && me=""
fi
if [ -z "$me" ]; then
  me=$(api "user" | jq -r '.username // empty' 2>/dev/null)
  if [ -z "$me" ]; then
    echo "🦊 ⚠️ | color=$ORANGE"
    echo "---"
    echo "Cannot reach $GITLAB_URL (offline, VPN, or token expired?) | color=$ORANGE"
    echo "Test token | bash=/bin/sh param1=-c param2=\"curl -sf -H \\\"PRIVATE-TOKEN: \$(security find-generic-password -s gitlab-radar -w)\\\" $API/user | jq .username\" terminal=true"
    exit 0
  fi
  printf '%s\n%s\n' "$now" "$me" > "$ME_CACHE"
fi

# ---- token expiry (PATs must be rotated at least yearly; checked once a day) --
TOKEN_INFO="$STATE_DIR/token-info"   # "checked_epoch expires_at"
expires_at=""; ti_ts=0
[ -f "$TOKEN_INFO" ] && read -r ti_ts expires_at < "$TOKEN_INFO"
if [ -z "$ti_ts" ] || (( now - ti_ts > 86400 )); then
  # endpoint missing on old GitLab / read-only tokens without it → cache "" for a day
  expires_at=$(api "personal_access_tokens/self" | jq -r '.expires_at // empty' 2>/dev/null)
  printf '%s %s\n' "$now" "$expires_at" > "$TOKEN_INFO"
fi
token_days_left=""
if [ -n "$expires_at" ]; then
  exp_epoch=$(jq -rn --arg d "$expires_at" '($d + "T00:00:00Z") | try fromdateiso8601 catch 0')
  (( exp_epoch > 0 )) && token_days_left=$(( (exp_epoch - now) / 86400 ))
fi

# ---- fetch -------------------------------------------------------------------
mrs=$(api "merge_requests?scope=created_by_me&state=opened&per_page=50")   || mrs="[]"
reviews=$(api "merge_requests?scope=all&state=opened&reviewer_username=$me&per_page=50") || reviews="[]"
todos=$(api "todos?state=pending&per_page=100")                            || todos="[]"

n_fail=0; n_review=0; n_review_approved=0; n_comment_mrs=0
rows_fail=(); rows_review=(); rows_comment=(); rows_mymr=(); rows_todo=()
state_keys=""     # snapshot lines "F key" / "R key" / "C key" for sound diffing
pending_pairs=""  # "key<TAB>maxid" lines -> pending-max.json for --seen-all

# ---- my open MRs: pipeline status + new comments -----------------------------
while IFS= read -r mr; do
  [ -n "$mr" ] || continue
  eval "$(jq -r '@sh "pid=\(.project_id) iid=\(.iid)
    title=\(.title // "?")
    url=\(.web_url // "")
    full=\(.references.full // "")
    target=\(.target_branch // "")
    upd=\((.updated_at // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+";"") | (try fromdateiso8601 catch 0))"' <<<"$mr")" || continue

  ref="${full##*/}"; [ -n "$ref" ] || ref="!$iid"
  title=$(sanitize "$title"); ref=$(sanitize "$ref")
  key="$pid:$iid"

  detail=$(api "projects/$pid/merge_requests/$iid") || detail=""
  p_status="none"; p_url=""; threads_ok="true"
  if [ -n "$detail" ]; then
    eval "$(jq -r '@sh "p_status=\(.head_pipeline.status // "none")
      p_url=\(.head_pipeline.web_url // "")
      threads_ok=\(if .blocking_discussions_resolved == false then "false" else "true" end)"' <<<"$detail")"
  fi

  # new comments from others since last seen (baseline silently on first sight)
  notes=$(api "projects/$pid/merge_requests/$iid/notes?per_page=100&sort=desc") || notes="[]"
  diff_new_comments "$notes"

  picon=$(pipe_icon "$p_status")
  row="$picon $ref $title | href=$url size=13"
  row+=$'\n'"-- → $target · updated $(age_str $(( now - upd ))) ago | size=11 color=$GRAY"
  [ -n "$p_url" ] && row+=$'\n'"-- pipeline: $p_status | href=$p_url size=11 color=$GRAY"
  [ "$threads_ok" != "true" ] && row+=$'\n'"-- ⚠️ unresolved threads block merging | size=11 color=$ORANGE"

  if (( new_n > 0 )); then
    (( n_comment_mrs++ ))
    new_author=$(sanitize "$new_author"); new_body=$(sanitize "$new_body")
    more=""; (( new_n > 1 )) && more=" (+$(( new_n - 1 )) more)"
    crow="💬 $ref — $new_author: “${new_body}”$more | size=13"
    crow+=" bash=\"$SELF\" param1=--open-seen param2=\"$url#note_$new_note_id\" param3=\"$key\" param4=\"$cur_max\" terminal=false refresh=true"
    crow+=$'\n'"💬 $ref — mark read without opening | alternate=true size=13 bash=\"$SELF\" param1=--seen param2=\"$key\" param3=\"$cur_max\" terminal=false refresh=true"
    crow+=$'\n'"-- on: $title | size=11 color=$GRAY"
    rows_comment+=("$crow")
    row+=$'\n'"-- 💬 $new_n new comment(s) | size=11 color=$BLUE"
    pending_pairs+="$key${TAB}$cur_max"$'\n'
    state_keys+="C $key:$cur_max"$'\n'
  fi

  if [ "$p_status" = "failed" ]; then
    (( n_fail++ ))
    frow="❌ $ref — pipeline failed | href=${p_url:-$url} size=13"
    frow+=$'\n'"-- $title | size=11 color=$GRAY"
    frow+=$'\n'"-- open MR instead | alternate=true size=11 href=$url"
    rows_fail+=("$frow")
    state_keys+="F mr:$key"$'\n'
  fi

  rows_mymr+=("$row")
done < <(jq -c '.[]' <<<"$mrs" 2>/dev/null)

# ---- MRs awaiting my review ---------------------------------------------------
while IFS= read -r mr; do
  [ -n "$mr" ] || continue
  eval "$(jq -r '@sh "pid=\(.project_id) iid=\(.iid)
    title=\(.title // "?")
    url=\(.web_url // "")
    full=\(.references.full // "")
    author=\(.author.name // "?")
    author_user=\(.author.username // "")"' <<<"$mr")" || continue
  [ "$author_user" = "$me" ] && continue

  ref="${full##*/}"; [ -n "$ref" ] || ref="!$iid"
  title=$(sanitize "$title"); ref=$(sanitize "$ref"); author=$(sanitize "$author")

  # a pending review_requested todo == someone (re-)requested your review
  eval "$(jq -r --argjson p "$pid" --argjson i "$iid" '
    [ .[] | select(.action_name == "review_requested" and .target_type == "MergeRequest"
                   and .project.id == $p and .target.iid == $i) ]
    | @sh "todo_id=\(if length > 0 then .[0].id else "" end)
      todo_ts=\(if length > 0 then (.[0].created_at | sub("\\.[0-9]+";"") | (try fromdateiso8601 catch 0)) else 0 end)"' <<<"$todos")"

  # already reviewed (approved, commented, or requested changes) and no fresh
  # re-request → this MR isn't waiting for you.
  # (The list API can't filter on this outside Premium, hence the extra calls.
  # If an endpoint fails, fail open and keep the row.)
  notes=$(api "projects/$pid/merge_requests/$iid/notes?per_page=100&sort=desc") || notes="[]"
  approved=$(api "projects/$pid/merge_requests/$iid/approvals" \
    | jq -r --arg me "$me" '[.approved_by[]?.user.username] | (index($me) != null)' 2>/dev/null)
  reviewed="$approved"
  if [ "$reviewed" != "true" ] && [ -z "$todo_id" ]; then
    my_notes=$(jq -r --arg me "$me" '[.[] | select(.system == false and .author.username == $me)] | length' <<<"$notes")
    [ "${my_notes:-0}" -gt 0 ] && reviewed="true"
  fi

  # new comments from others since last seen — checked even once approved, since
  # replies to your review comments keep coming after you've signed off.
  key="$pid:$iid"
  diff_new_comments "$notes"
  if (( new_n > 0 )); then
    (( n_comment_mrs++ ))
    new_author=$(sanitize "$new_author"); new_body=$(sanitize "$new_body")
    more=""; (( new_n > 1 )) && more=" (+$(( new_n - 1 )) more)"
    crow="💬 $ref — $new_author: “${new_body}”$more | size=13"
    crow+=" bash=\"$SELF\" param1=--open-seen param2=\"$url#note_$new_note_id\" param3=\"$key\" param4=\"$cur_max\" terminal=false refresh=true"
    crow+=$'\n'"💬 $ref — mark read without opening | alternate=true size=13 bash=\"$SELF\" param1=--seen param2=\"$key\" param3=\"$cur_max\" terminal=false refresh=true"
    crow+=$'\n'"-- on: $title (reviewing) | size=11 color=$GRAY"
    rows_comment+=("$crow")
    pending_pairs+="$key${TAB}$cur_max"$'\n'
    state_keys+="C $key:$cur_max"$'\n'
  fi

  if [ "$reviewed" = "true" ] && [ -z "$todo_id" ]; then
    (( n_review_approved++ ))
    continue
  fi

  (( n_review++ ))
  badge=""; [ -n "$todo_id" ] && badge="🔁 "
  [ "$approved" = "true" ] && [ -n "$todo_id" ] && badge="🔁 ✓→ "   # you approved, but review was re-requested
  rrow="👀 $badge$ref $author — $title | href=$url size=13"
  if [ -n "$todo_id" ]; then
    rrow+=$'\n'"-- review (re-)requested $(age_str $(( now - todo_ts ))) ago | size=11 color=$ORANGE"
    rrow+=$'\n'"-- ✓ mark to-do done | size=11 bash=\"$SELF\" param1=--todo-done param2=\"$todo_id\" terminal=false refresh=true"
    state_keys+="R todo:$todo_id"$'\n'
  else
    state_keys+="R mr:$pid:$iid"$'\n'
  fi
  rows_review+=("$rrow")
done < <(jq -c '.[]' <<<"$reviews" 2>/dev/null)

# ---- remaining to-dos (mentions, direct replies, unmergeable, …) --------------
while IFS= read -r td; do
  [ -n "$td" ] || continue
  eval "$(jq -r '@sh "tid=\(.id) action=\(.action_name // "")
    turl=\(.target_url // "")
    tref=\(.target.references.full // .target.title // "?")
    tauthor=\(.author.name // "?")
    tbody=\(.body // "" | .[0:80])"' <<<"$td")" || continue
  tref=$(sanitize "${tref##*/}"); tbody=$(sanitize "$tbody"); tauthor=$(sanitize "$tauthor")
  case "$action" in
    mentioned)          lbl="🏷 $tauthor mentioned you" ;;
    directly_addressed) lbl="🗣 $tauthor replied to you" ;;
    unmergeable)        lbl="⚠️ cannot be merged" ;;
    approval_required)  lbl="✅ approval required" ;;
    assigned)           lbl="📌 assigned to you" ;;
    *)                  lbl="• $action" ;;
  esac
  trow="$lbl · $tref | href=$turl size=13"
  [ -n "$tbody" ] && trow+=$'\n'"-- “$tbody” | size=11 color=$GRAY"
  trow+=$'\n'"-- ✓ mark done | size=11 bash=\"$SELF\" param1=--todo-done param2=\"$tid\" terminal=false refresh=true"
  rows_todo+=("$trow")
done < <(jq -c --arg me "$me" '
  [ .[] | select(.action_name as $a
      | ["mentioned","directly_addressed","unmergeable","approval_required","assigned","marked"]
      | index($a))
    | select(.author.username != $me) ]
  | .[0:'"$MAX_TODOS"'] | .[]' <<<"$todos" 2>/dev/null)

# ---- default-branch pipelines (watched + MR target projects) ------------------
proj_meta() { # $1 = key (numeric id or url-encoded path) -> "branch<TAB>name", cached 1 day
  local key="$1" meta branch name ts tmp proj
  meta=$(jq -r --arg k "$key" '.[$k] // empty | "\(.branch)\t\(.name)\t\(.ts)"' "$PROJ_CACHE")
  if [ -n "$meta" ]; then
    ts=${meta##*$TAB}
    if [ -n "$ts" ] && (( now - ts < 86400 )); then printf '%s' "${meta%$TAB*}"; return 0; fi
  fi
  proj=$(api "projects/$key") || return 1
  branch=$(jq -r '.default_branch // "main"' <<<"$proj")
  name=$(jq -r '.path_with_namespace // .name // "?"' <<<"$proj")
  tmp=$(mktemp)
  jq --arg k "$key" --arg b "$branch" --arg n "$name" --argjson t "$now" \
    '.[$k] = {branch: $b, name: $n, ts: $t}' "$PROJ_CACHE" > "$tmp" && mv "$tmp" "$PROJ_CACHE"
  printf '%s\t%s' "$branch" "$name"
}

main_targets=""   # lines "key<TAB>branch-override(optional)"
for entry in $WATCH_MAIN_PROJECTS; do
  path="$entry"; override=""
  case "$entry" in */*:*) path="${entry%:*}"; override="${entry##*:}" ;; esac
  enc=$(jq -rn --arg s "$path" '$s | @uri')
  main_targets+="$enc${TAB}$override"$'\n'
done
if [ "$WATCH_MR_TARGET_MAINS" = "1" ]; then
  while IFS= read -r pid; do
    [ -n "$pid" ] && main_targets+="$pid${TAB}"$'\n'
  done < <(jq -r '[.[].target_project_id] | unique | .[]' <<<"$mrs" 2>/dev/null)
fi

n_main_ok=0; mains_seen=" "
while IFS=$TAB read -r key override; do
  [ -n "$key" ] || continue
  case "$mains_seen" in *" $key "*) continue ;; esac
  mains_seen+="$key "
  meta=$(proj_meta "$key") || continue
  branch="${override:-${meta%$TAB*}}"; name="${meta#*$TAB}"
  pl=$(api "projects/$key/pipelines?ref=$branch&per_page=1") || continue
  eval "$(jq -r '@sh "pl_status=\(.[0].status // "none") pl_url=\(.[0].web_url // "")
    pl_ts=\((.[0].updated_at // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+";"") | (try fromdateiso8601 catch 0))"' <<<"$pl")"
  if [ "$pl_status" = "failed" ]; then
    (( n_fail++ ))
    frow="❌ $(sanitize "${name##*/}") · $branch — pipeline failed $(age_str $(( now - pl_ts ))) ago | href=$pl_url size=13"
    frow+=$'\n'"-- $(sanitize "$name") | size=11 color=$GRAY"
    rows_fail+=("$frow")
    state_keys+="F main:$key:$branch"$'\n'
  elif [ "$pl_status" != "none" ]; then
    (( n_main_ok++ ))
  fi
done <<<"$main_targets"

# ---- persist the maxima so "Mark all read" knows what to record ---------------
if [ -n "$pending_pairs" ]; then
  printf '%s' "$pending_pairs" | jq -Rn \
    '[inputs | select(length > 0) | split("\t") | {(.[0]): (.[1] | tonumber)}] | add // {}' \
    > "$PENDING_MAX"
else
  echo '{}' > "$PENDING_MAX"
fi

# ---- sounds on NEW events (🔕 by default; toggle at the bottom) ----------------
if [ -f "$SOUNDS_FLAG" ] && [ -f "$SNAPSHOT" ] && command -v afplay >/dev/null 2>&1; then
  new_f=0; new_r=0; new_c=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qxF "$line" "$SNAPSHOT" 2>/dev/null && continue
    case "$line" in
      F\ *) new_f=1 ;;
      R\ *) new_r=1 ;;
      C\ *) new_c=1 ;;
    esac
  done <<<"$state_keys"
  # one sound per category per refresh, never a burst
  (( new_f )) && afplay "/System/Library/Sounds/Basso.aiff" >/dev/null 2>&1 &
  (( new_r )) && afplay "/System/Library/Sounds/Ping.aiff"  >/dev/null 2>&1 &
  (( new_c )) && afplay "/System/Library/Sounds/Pop.aiff"   >/dev/null 2>&1 &
fi
printf '%s' "$state_keys" > "$SNAPSHOT"

# ---- menu bar title ------------------------------------------------------------
# The 🦊 prefix is always there, so the radar stays tellable-apart from other
# SwiftBar plugins even when counts light up.
title="🦊 "
(( n_fail        > 0 )) && title+="❌${n_fail} "
(( n_review      > 0 )) && title+="👀${n_review} "
(( n_comment_mrs > 0 )) && title+="💬${n_comment_mrs} "
if [ "$title" != "🦊 " ]; then
  echo "${title% }"
else
  echo "🦊 | color=$DIM"
fi

# ---- dropdown -------------------------------------------------------------------
echo "---"
if [ -n "$token_days_left" ] && (( token_days_left <= TOKEN_WARN_DAYS )); then
  if (( token_days_left < 0 )); then
    lbl="⚠️ Token EXPIRED $(( -token_days_left ))d ago"
  else
    lbl="⚠️ Token expires in ${token_days_left}d"
  fi
  if [ "$TOKEN_SRC" = "keychain" ]; then
    echo "$lbl — click to rotate (1 year) | color=$ORANGE bash=\"$SELF\" param1=--rotate terminal=false refresh=true"
    echo "$lbl — open token settings | alternate=true color=$ORANGE href=$GITLAB_URL/-/user_settings/personal_access_tokens"
  else
    echo "$lbl — token is in the config file, rotate manually | color=$ORANGE href=$GITLAB_URL/-/user_settings/personal_access_tokens"
  fi
  echo "---"
fi
if (( n_fail > 0 )); then
  echo "BROKEN BUILDS | size=10 color=$RED"
  for b in "${rows_fail[@]}"; do printf '%s\n' "$b"; done
  echo "---"
fi
if (( n_review > 0 || n_review_approved > 0 )); then
  echo "WAITING FOR YOUR REVIEW | size=10 color=$ORANGE"
  for b in "${rows_review[@]}"; do printf '%s\n' "$b"; done
  (( n_review_approved > 0 )) && \
    echo "✓ $n_review_approved already reviewed by you — hidden until re-requested | size=11 color=$DIM"
  echo "---"
fi
if (( n_comment_mrs > 0 )); then
  echo "NEW COMMENTS | size=10 color=$BLUE"
  for b in "${rows_comment[@]}"; do printf '%s\n' "$b"; done
  echo "Mark all read | size=11 bash=\"$SELF\" param1=--seen-all terminal=false refresh=true"
  echo "---"
fi
if (( ${#rows_todo[@]} > 0 )); then
  echo "TO-DOS | size=10 color=$GRAY"
  for b in "${rows_todo[@]}"; do printf '%s\n' "$b"; done
  echo "---"
fi
if (( ${#rows_mymr[@]} > 0 )); then
  echo "MY OPEN MRS | size=10 color=$GRAY"
  for b in "${rows_mymr[@]}"; do printf '%s\n' "$b"; done
else
  echo "No open MRs of yours | color=$GRAY"
fi
(( n_main_ok > 0 )) && echo "🟢 $n_main_ok watched default branch(es) passing | size=11 color=$DIM"
echo "---"
echo "Open GitLab: my MRs | href=$GITLAB_URL/dashboard/merge_requests?author_username=$me size=12"
echo "Open GitLab: review requests | href=$GITLAB_URL/dashboard/merge_requests?reviewer_username=$me size=12"
echo "Open GitLab: to-do list | href=$GITLAB_URL/dashboard/todos size=12"
if [ -f "$SOUNDS_FLAG" ]; then
  echo "🔔 Sounds on — click to mute | bash=/bin/rm param1=-f param2=\"$SOUNDS_FLAG\" terminal=false refresh=true"
else
  echo "🔕 Sounds off — click to enable | bash=/usr/bin/touch param1=\"$SOUNDS_FLAG\" terminal=false refresh=true"
fi
echo "Edit config | bash=/usr/bin/open param1=-t param2=\"$CONF\" terminal=false"
