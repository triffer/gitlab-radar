#!/usr/bin/env bats
# Clicking a row. Every action in the dropdown is the plugin re-invoking itself
# with a flag (`bash=… param1=--seen …`), which is why these run the real script
# with real arguments rather than calling a function.
#
# The read markers are what the 💬 badge is built on, so most of this file is
# about them: a marker that is not recorded means the same comment arrives as
# news for ever, and one recorded too eagerly loses a comment you never read.
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup() {
  radar_setup
  radar_config
  radar_quiet_gitlab
}
teardown() { radar_teardown; }

# One MR of yours with one unread comment on it — the state every read-marker
# action starts from.
one_unread_comment() {
  my_mrs <<<"$(json_array "$(mr iid=7 references.full='g/p!7')")"
  mr_detail 7 <<<"$(mr_json)"
  approvals_for 7 <<<"$(approvals 0 0)"
  notes_for 7 <<<"$(json_array "$(note 30 ann 'have a look at this')")"
  mark_seen 1:7 20
}

# ------------------------------------------------------------ marking read

@test "marking one MR read records the note it was read up to" {
  mark_seen 1:7 20

  radar --seen 1:7 30

  [ "$(seen_field 1:7)" = "30" ]
}

@test "marking an MR read for the first time records it just the same" {
  # the action can arrive before any render has baselined this MR
  radar --seen 1:7 30

  [ "$(seen_field 1:7)" = "30" ]
}

@test "a comment marked read stays read on the next refresh" {
  # the round trip the badge depends on: render, click, render again
  one_unread_comment
  run radar
  [ "${lines[0]}" = "🦊 💬1" ]

  radar --seen 1:7 30

  run radar
  [ "${lines[0]}" = "🦊 | color=#6e6e73" ]
  [[ "$output" != *"NEW COMMENTS"* ]]
}

@test "opening a comment marks it read and opens the note itself" {
  one_unread_comment
  local url="https://gitlab.example.com/g/p/-/merge_requests/1#note_30"

  radar --open-seen "$url" 1:7 30

  [ "$(seen_field 1:7)" = "30" ]
  assert_called_with open "note_30"
}

@test "Mark all read clears every MR the last render found comments on" {
  # the maxima are recorded per render, so the action needs no arguments — it
  # cannot pick up a comment that arrived after you looked at the menu
  my_mrs <<<"$(json_array "$(mr iid=7 references.full='g/p!7')" \
                          "$(mr iid=8 references.full='g/p!8')")"
  mr_detail 7 <<<"$(mr_json)"; approvals_for 7 <<<"$(approvals 0 0)"
  mr_detail 8 <<<"$(mr_json)"; approvals_for 8 <<<"$(approvals 0 0)"
  notes_for 7 <<<"$(json_array "$(note 30 ann)")"
  notes_for 8 <<<"$(json_array "$(note 40 bob)")"
  mark_seen 1:7 20; mark_seen 1:8 20
  run radar
  [ "${lines[0]}" = "🦊 💬2" ]

  radar --seen-all

  [ "$(seen_field 1:7)" = "30" ]
  [ "$(seen_field 1:8)" = "40" ]
}

@test "Mark all read leaves the markers alone when there was nothing to mark" {
  mark_seen 1:7 20
  radar   # a render with no new comments empties the pending maxima

  radar --seen-all

  [ "$(seen_field 1:7)" = "20" ]
}

@test "a comment that arrives while the menu is open is not marked read" {
  # --seen-all replays what the render recorded, not what GitLab says now
  one_unread_comment
  radar >/dev/null
  notes_for 7 <<<"$(json_array "$(note 50 ann 'and this too')")"

  radar --seen-all

  [ "$(seen_field 1:7)" = "30" ]
}

# --------------------------------------------------------------- to-do done

@test "marking a to-do done tells GitLab about it" {
  radar --todo-done 42

  assert_called_with curl "POST.*/api/v4/todos/42/mark_as_done"
}

@test "a to-do that cannot be marked done fails quietly" {
  # no route for the POST: SwiftBar shows nothing for a non-zero exit anyway, and
  # the next refresh will simply still list the to-do
  run radar --todo-done 42

  [ "$status" -eq 0 ]
}

# --------------------------------------------------------------- the sounds

@test "the radar is silent until you ask it not to be" {
  my_mrs <<<"$(json_array "$(mr iid=7 references.full='g/p!7')")"
  mr_detail 7 <<<"$(mr_json head_pipeline.status=failed)"
  notes_for 7 <<<'[]'; approvals_for 7 <<<"$(approvals 0 0)"

  run radar

  [ "${lines[0]}" = "🦊 ❌1" ]
  refute_called afplay
  [[ "$output" == *"🔕 Sounds off — click to enable"* ]]
}

@test "enabling sounds does not replay everything that was already broken" {
  # the snapshot of the previous render is what "new" is measured against, and
  # switching sounds on is not the moment to hear about a week-old failure
  sounds_on
  my_mrs <<<"$(json_array "$(mr iid=7 references.full='g/p!7')")"
  mr_detail 7 <<<"$(mr_json head_pipeline.status=failed)"
  notes_for 7 <<<'[]'; approvals_for 7 <<<"$(approvals 0 0)"

  run radar

  refute_called afplay
  [[ "$output" == *"🔔 Sounds on — click to mute"* ]]
}

@test "a failure that was not there on the last refresh makes a sound" {
  sounds_on
  radar >/dev/null                      # quiet render: writes the snapshot
  my_mrs <<<"$(json_array "$(mr iid=7 references.full='g/p!7')")"
  mr_detail 7 <<<"$(mr_json head_pipeline.status=failed)"
  notes_for 7 <<<'[]'; approvals_for 7 <<<"$(approvals 0 0)"

  radar >/dev/null

  wait_for_call afplay
  assert_called_with afplay "Basso"
}

@test "the same failure does not make a sound twice" {
  sounds_on
  radar >/dev/null                      # quiet render: writes the snapshot
  my_mrs <<<"$(json_array "$(mr iid=7 references.full='g/p!7')")"
  mr_detail 7 <<<"$(mr_json head_pipeline.status=failed)"
  notes_for 7 <<<'[]'; approvals_for 7 <<<"$(approvals 0 0)"
  radar >/dev/null                      # first sight of the failure — Basso
  wait_for_call afplay
  : > "$STUB_CALLS"

  radar >/dev/null

  refute_called afplay
}

@test "each kind of news has its own sound" {
  sounds_on
  mark_seen 1:7 20
  radar >/dev/null
  my_mrs <<<"$(json_array "$(mr iid=7 references.full='g/p!7')")"
  mr_detail 7 <<<"$(mr_json)"
  notes_for 7 <<<"$(json_array "$(note 30 ann)")"
  approvals_for 7 <<<"$(approvals 1 0 ann)"
  review_mrs <<<"$(json_array "$(mr iid=11 references.full='g/p!11')")"
  notes_for 11 <<<'[]'; approvals_for 11 <<<"$(approvals 1 1)"

  radar >/dev/null

  wait_for_call afplay
  assert_called_with afplay "Pop"     # a comment
  assert_called_with afplay "Glass"   # an approval
  assert_called_with afplay "Ping"    # a review request
}
