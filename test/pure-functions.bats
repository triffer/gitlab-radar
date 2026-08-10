#!/usr/bin/env bats
# Unit tests for the decisions the radar makes in isolation: how it words an age,
# which icon a pipeline status gets, what it says about an MR GitLab refuses to
# merge, and which comments count as unread.
#
# The rest of the suite drives the whole plugin, which is the right way to check
# that the pieces fit together but a slow and indirect way to pin down a case
# table. These functions take arguments and produce a string, so they are sourced
# and called directly (see load_radar in helper.bash).
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup()    { radar_setup; }
teardown() { radar_teardown; }

# ------------------------------------------------------------------- ages

@test "an age is worded at the coarsest unit that still says something" {
  load_radar

  run age_str 45
  [ "$output" = "45s" ]

  run age_str 90
  [ "$output" = "1m" ]

  run age_str 7200
  [ "$output" = "2h" ]

  run age_str 172800
  [ "$output" = "2d" ]
}

@test "a clock that disagrees with GitLab never renders a negative age" {
  # updated_at can be a second or two in the future when the two machines'
  # clocks differ; "-1s ago" would look like a bug in the radar
  load_radar

  run age_str -5

  [ "$output" = "0s" ]
}

# ---------------------------------------------------- SwiftBar-safe values

@test "a pipe in an MR title can never become a SwiftBar parameter" {
  # SwiftBar splits a row on "|", so a title containing one would turn the rest
  # of the row into menu item parameters
  load_radar

  run sanitize 'fix the a|b parser'

  [ "$output" = 'fix the a¦b parser' ]
}

@test "a newline in a comment can never split one row into two" {
  load_radar

  run sanitize 'first
second'

  [ "$output" = "first second" ]
}

# --------------------------------------------------------- pipeline icons

@test "every pipeline status the radar knows has its own icon" {
  load_radar

  run pipe_icon success
  [ "$output" = "🟢" ]

  run pipe_icon failed
  [ "$output" = "❌" ]

  run pipe_icon running
  [ "$output" = "🔵" ]

  run pipe_icon pending
  [ "$output" = "⏳" ]

  run pipe_icon canceled
  [ "$output" = "⚪️" ]
}

@test "a status a newer GitLab invented still gets an icon" {
  # the row is built around the icon, so an empty one would misalign it
  load_radar

  run pipe_icon something_new

  [ "$output" = "▫️" ]
}

# --------------------------------------------------------- merge blockers

@test "a merge blocker is named in words, not in GitLab's vocabulary" {
  load_radar

  run merge_blocker conflict
  [ "$output" = "⚠️ conflicts with the target branch" ]

  run merge_blocker need_rebase
  [ "$output" = "⚠️ needs a rebase" ]

  run merge_blocker requested_changes
  [ "$output" = "🔁 a reviewer requested changes" ]
}

@test "a mergeable MR says nothing about merging" {
  load_radar

  run merge_blocker mergeable
  [ -z "$output" ]

  # what an instance older than 15.6 reports instead
  run merge_blocker can_be_merged
  [ -z "$output" ]

  run merge_blocker ""
  [ -z "$output" ]
}

@test "a status GitLab is still working out is not reported as a blocker" {
  # these flip to something final within seconds; a row that said "checking"
  # would flicker on every refresh
  load_radar

  for transient in checking unchecked preparing approvals_syncing cannot_be_merged_recheck; do
    run merge_blocker "$transient"
    [ -z "$output" ]
  done
}

@test "an unrecognised merge status is left unsaid rather than guessed at" {
  load_radar

  run merge_blocker whatever_gitlab_18_invents

  [ -z "$output" ]
}

# ------------------------------------------------------------ read markers

@test "the first sighting of an MR is baselined instead of announced" {
  # the radar is installed into a mailbox with months of history in it; every
  # comment ever written must not arrive as news on the first refresh
  load_radar
  key="1:7"; me="me"

  diff_new_comments "$(json_array "$(note 30 ann)" "$(note 20 bob)")"

  [ "$new_n" -eq 0 ]
  [ "$(seen_field 1:7)" = "30" ]
}

@test "only comments newer than the read marker count as new" {
  load_radar
  key="1:7"; me="me"
  mark_seen 1:7 20

  diff_new_comments "$(json_array "$(note 30 ann 'needs a test')" "$(note 20 bob)")"

  [ "$new_n" -eq 1 ]
  [ "$new_author" = "ann" ]
  [ "$new_body" = "needs a test" ]
  [ "$new_note_id" -eq 30 ]
  [ "$cur_max" -eq 30 ]
}

@test "your own comments are never new to you" {
  load_radar
  key="1:7"; me="me"
  mark_seen 1:7 10

  diff_new_comments "$(json_array "$(note 30 me)")"

  [ "$new_n" -eq 0 ]
}

@test "GitLab's own bookkeeping notes are not comments" {
  # every label change, assignment and milestone edit arrives as a note with
  # system=true; counting those would make the 💬 badge meaningless
  load_radar
  key="1:7"; me="me"
  mark_seen 1:7 10

  diff_new_comments "$(json_array "$(note 30 ann 'added label' system)")"

  [ "$new_n" -eq 0 ]
}

@test "the newest of several new comments is the one shown" {
  load_radar
  key="1:7"; me="me"
  mark_seen 1:7 10

  diff_new_comments "$(json_array "$(note 30 ann 'and one more thing')" \
                                  "$(note 20 bob 'first thought')")"

  [ "$new_n" -eq 2 ]
  [ "$new_author" = "ann" ]
  [ "$new_body" = "and one more thing" ]
}

@test "a long comment is cut down before it reaches a menu row" {
  load_radar
  key="1:7"; me="me"
  mark_seen 1:7 10

  diff_new_comments "$(json_array "$(note 30 ann "$(printf 'x%.0s' {1..200})")")"

  [ "${#new_body}" -eq 90 ]
}

@test "marking an MR read records the marker without touching the others" {
  load_radar
  mark_seen 1:7 20

  seen_set 2:9 55

  [ "$(seen_field 1:7)" = "20" ]
  [ "$(seen_field 2:9)" = "55" ]
}
