#!/usr/bin/env bats
# What the menu bar actually shows: the title line and the grouped dropdown, with
# GitLab answering from the routing table in helper.bash rather than the network.
#
# The counts in the title are the whole point of the radar — they are what you see
# without opening anything — so most of what follows is about which situations
# light one up and which deliberately do not.
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup() {
  radar_setup
  radar_config
  radar_quiet_gitlab
}
teardown() { radar_teardown; }

# An MR of yours that GitLab is perfectly happy with: green pipeline, mergeable,
# nothing to approve, no comments. Tests override the parts they are about.
my_mr() { # $@: overrides for mr()
  my_mrs <<<"$(json_array "$(mr "$@")")"
  mr_detail 7 <<<"$(mr_json)"
  notes_for 7 <<<'[]'
  approvals_for 7 <<<"$(approvals 0 0)"
}

# ------------------------------------------------------------------ quiet

@test "nothing going on renders a dim fox and says so" {
  run radar

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "🦊 | color=#6e6e73" ]
  [[ "$output" == *"No open MRs of yours"* ]]
}

@test "a healthy MR of yours is listed without lighting up the bar" {
  # the bar is for things that need you; an MR that is simply open does not
  my_mr iid=7 references.full='g/p!7' title='Teach the parser to count'

  run radar

  [ "${lines[0]}" = "🦊 | color=#6e6e73" ]
  [[ "$output" == *"MY OPEN MRS"* ]]
  [[ "$output" == *"🟢 p!7 Teach the parser to count"* ]]
  [[ "$output" == *"→ main · updated"* ]]
}

# ------------------------------------------------------------ broken builds

@test "a failed pipeline on your MR is counted and gets its own row" {
  my_mr iid=7 references.full='g/p!7'
  mr_detail 7 <<<"$(mr_json head_pipeline.status=failed)"

  run radar

  [ "${lines[0]}" = "🦊 ❌1" ]
  [[ "$output" == *"BROKEN BUILDS"* ]]
  [[ "$output" == *"❌ p!7 — pipeline failed"* ]]
  # straight to the failing pipeline, not to the MR
  [[ "$output" == *"href=https://gitlab.example.com/g/p/-/pipelines/9"* ]]
}

@test "a red pipeline on a draft is shown but never counted" {
  # a draft is work in progress: its failing pipeline is expected, not news
  my_mr iid=7 references.full='g/p!7' draft=true
  mr_detail 7 <<<"$(mr_json head_pipeline.status=failed)"

  run radar

  [ "${lines[0]}" = "🦊 | color=#6e6e73" ]
  [[ "$output" != *"BROKEN BUILDS"* ]]
  [[ "$output" == *"not counted while this is a draft"* ]]
}

@test "a draft is badged and the word is dropped from its title" {
  my_mr iid=7 references.full='g/p!7' title='Draft: Teach the parser to count' draft=true

  run radar

  [[ "$output" == *"📝 p!7 Teach the parser to count"* ]]
  [[ "$output" != *"Draft: Teach"* ]]
}

@test "a draft is recognised however this GitLab spells it" {
  # .draft is current, .work_in_progress is the old field, and the title prefix
  # is all an instance that exposes neither ever gives you
  my_mr iid=7 references.full='g/p!7' title='WIP: not ready' work_in_progress=true

  run radar

  [[ "$output" == *"📝 p!7 not ready"* ]]
}

@test "a draft with neither field set is spotted by its title alone" {
  my_mr iid=7 references.full='g/p!7' title='WIP: not ready'

  run radar

  [[ "$output" == *"📝 p!7 not ready"* ]]
}

# ---------------------------------------------------------- merge blockers

@test "an MR GitLab refuses to merge says why" {
  my_mr iid=7 references.full='g/p!7'
  mr_detail 7 <<<"$(mr_json detailed_merge_status=conflict)"

  run radar

  [[ "$output" == *"⚠️ conflicts with the target branch"* ]]
}

@test "open threads are reported even when GitLab blames something else" {
  # GitLab names one blocker only, so an MR that conflicts AND has open threads
  # would otherwise never mention the threads
  my_mr iid=7 references.full='g/p!7'
  mr_detail 7 <<<"$(mr_json detailed_merge_status=conflict blocking_discussions_resolved=false)"

  run radar

  [[ "$output" == *"⚠️ conflicts with the target branch"* ]]
  [[ "$output" == *"⚠️ unresolved threads block merging"* ]]
}

@test "open threads are not reported twice when they are the blocker" {
  my_mr iid=7 references.full='g/p!7'
  mr_detail 7 <<<"$(mr_json detailed_merge_status=discussions_not_resolved \
                            blocking_discussions_resolved=false)"

  run radar

  [ "$(grep -c 'unresolved threads block merging' <<<"$output")" -eq 1 ]
}

@test "the draft badge is not repeated as a merge blocker" {
  my_mr iid=7 references.full='g/p!7' draft=true
  mr_detail 7 <<<"$(mr_json detailed_merge_status=draft_status)"

  run radar

  [[ "$output" == *"📝 p!7"* ]]
  [[ "$output" != *"still a draft — mark it ready"* ]]
}

@test "an instance too old for detailed_merge_status still says something" {
  # detailed_merge_status arrived in GitLab 15.6; before it there was only
  # merge_status, which knows yes and no
  my_mr iid=7 references.full='g/p!7'
  mr_detail 7 <<<"$(jq -nc '{merge_status: "cannot_be_merged",
    head_pipeline: {status: "success"}, blocking_discussions_resolved: true}')"

  run radar

  [[ "$output" == *"⚠️ cannot be merged — conflicts?"* ]]
}

# --------------------------------------------------------------- approvals

@test "an approval on your MR is counted and gets its own section" {
  my_mr iid=7 references.full='g/p!7'
  approvals_for 7 <<<"$(approvals 1 0 ann)"

  run radar

  [ "${lines[0]}" = "🦊 ✅1" ]
  [[ "$output" == *"APPROVED — YOUR MRS"* ]]
  [[ "$output" == *"✅ p!7 — approved by ann"* ]]
  [[ "$output" == *"ready to merge"* ]]
}

@test "ready to merge is only claimed when GitLab agrees the approvals are in" {
  # one approval on a project that wants two used to read as "ready to merge"
  my_mr iid=7 references.full='g/p!7'
  approvals_for 7 <<<"$(approvals 2 1 ann)"

  run radar

  [[ "$output" == *"✍️ 1 more approval(s) needed (of 2)"* ]]
  [[ "$output" != *"ready to merge"* ]]
}

@test "waiting for approvals is not said twice when someone has approved" {
  # GitLab reports "not_approved" until the last approval lands; the line with
  # the count is the more useful of the two
  my_mr iid=7 references.full='g/p!7'
  mr_detail 7 <<<"$(mr_json detailed_merge_status=not_approved)"
  approvals_for 7 <<<"$(approvals 2 1 ann)"

  run radar

  [[ "$output" != *"✍️ waiting for approvals"* ]]
  [[ "$output" == *"✍️ 1 more approval(s) needed (of 2)"* ]]
}

@test "an approved MR whose threads are still open is not ready either" {
  my_mr iid=7 references.full='g/p!7'
  mr_detail 7 <<<"$(mr_json blocking_discussions_resolved=false)"
  approvals_for 7 <<<"$(approvals 1 0 ann)"

  run radar

  [[ "$output" == *"⚠️ unresolved threads still block merging"* ]]
  [[ "$output" != *"ready to merge"* ]]
}

@test "an unreachable approvals endpoint does not leave the previous MR's approvers standing" {
  # the eval that unpacks the approvals produces nothing when the call fails, so
  # the variables have to be reset per MR — this is what that guards against
  my_mrs <<<"$(json_array "$(mr iid=7 references.full='g/p!7')" \
                          "$(mr iid=8 references.full='g/p!8')")"
  mr_detail 7 <<<"$(mr_json)"; notes_for 7 <<<'[]'
  mr_detail 8 <<<"$(mr_json)"; notes_for 8 <<<'[]'
  approvals_for 7 <<<"$(approvals 1 0 ann)"
  # no route for !8's approvals: curl fails the way an outage does

  run radar

  [ "${lines[0]}" = "🦊 ✅1" ]
  [[ "$output" == *"✅ p!7 — approved by ann"* ]]
  [[ "$output" != *"p!8 — approved"* ]]
}

# ----------------------------------------------------------------- reviews

@test "an MR waiting for your review is counted and named" {
  review_mrs <<<"$(json_array "$(mr iid=11 references.full='g/p!11' \
                                    title='Rewrite the scheduler')")"
  notes_for 11 <<<'[]'
  approvals_for 11 <<<"$(approvals 1 1)"

  run radar

  [ "${lines[0]}" = "🦊 👀1" ]
  [[ "$output" == *"WAITING FOR YOUR REVIEW"* ]]
  [[ "$output" == *"👀 p!11 Ann Other — Rewrite the scheduler"* ]]
}

@test "a re-requested review is badged and offers to clear its to-do" {
  review_mrs <<<"$(json_array "$(mr iid=11 references.full='g/p!11')")"
  notes_for 11 <<<'[]'
  approvals_for 11 <<<"$(approvals 1 1)"
  todos_are <<<"$(json_array "$(todo 42 review_requested target.iid=11)")"

  run radar

  [[ "$output" == *"👀 🔁 p!11"* ]]
  [[ "$output" == *"review (re-)requested"* ]]
  [[ "$output" == *"param1=--todo-done param2=\"42\""* ]]
}

@test "an MR you already approved drops off the list and is counted as done" {
  review_mrs <<<"$(json_array "$(mr iid=11 references.full='g/p!11')")"
  notes_for 11 <<<'[]'
  approvals_for 11 <<<"$(approvals 1 0 me)"

  run radar

  [ "${lines[0]}" = "🦊 | color=#6e6e73" ]
  [[ "$output" == *"1 already reviewed by you — hidden until re-requested"* ]]
  [[ "$output" != *"👀 p!11"* ]]
}

@test "an MR you approved comes back when the review is re-requested" {
  review_mrs <<<"$(json_array "$(mr iid=11 references.full='g/p!11')")"
  notes_for 11 <<<'[]'
  approvals_for 11 <<<"$(approvals 1 0 me)"
  todos_are <<<"$(json_array "$(todo 42 review_requested target.iid=11)")"

  run radar

  [ "${lines[0]}" = "🦊 👀1" ]
  [[ "$output" == *"👀 🔁 ✓→ p!11"* ]]
}

@test "having commented counts as having reviewed" {
  review_mrs <<<"$(json_array "$(mr iid=11 references.full='g/p!11')")"
  notes_for 11 <<<"$(json_array "$(note 5 me 'please rename this')")"
  approvals_for 11 <<<"$(approvals 1 1)"

  run radar

  [ "${lines[0]}" = "🦊 | color=#6e6e73" ]
  [[ "$output" == *"1 already reviewed by you"* ]]
}

@test "your own MR is never something you are asked to review" {
  # the reviewer_username query returns MRs you authored too when you are on
  # your own reviewer list
  review_mrs <<<"$(json_array "$(mr iid=11 references.full='g/p!11' \
                                    author.username=me author.name='Me Myself')")"

  run radar

  [ "${lines[0]}" = "🦊 | color=#6e6e73" ]
  [[ "$output" != *"WAITING FOR YOUR REVIEW"* ]]
}

@test "a review request on a draft says so" {
  # asked for early feedback — worth knowing before you read it as finished work
  review_mrs <<<"$(json_array "$(mr iid=11 references.full='g/p!11' draft=true)")"
  notes_for 11 <<<'[]'
  approvals_for 11 <<<"$(approvals 1 1)"

  run radar

  [[ "$output" == *"👀 📝 p!11"* ]]
}

@test "an endpoint that fails keeps the review row rather than hiding it" {
  # no notes and no approvals route: the radar cannot tell whether you reviewed
  # this one, and a review you never see is worse than one you see twice
  review_mrs <<<"$(json_array "$(mr iid=11 references.full='g/p!11')")"

  run radar

  [ "${lines[0]}" = "🦊 👀1" ]
}

# ---------------------------------------------------------------- comments

@test "a new comment on your MR is counted and quoted" {
  my_mr iid=7 references.full='g/p!7'
  notes_for 7 <<<"$(json_array "$(note 30 'Ann Other' 'this breaks on empty input')")"
  mark_seen 1:7 20

  run radar

  [ "${lines[0]}" = "🦊 💬1" ]
  [[ "$output" == *"NEW COMMENTS"* ]]
  [[ "$output" == *"💬 p!7 — Ann Other: “this breaks on empty input”"* ]]
  [[ "$output" == *"💬 1 new comment(s)"* ]]
}

@test "several new comments are counted once, with the newest quoted" {
  # one row per MR, not per comment: the badge counts conversations to catch up on
  my_mr iid=7 references.full='g/p!7'
  notes_for 7 <<<"$(json_array "$(note 30 ann 'and another thing')" "$(note 25 bob 'hm')")"
  mark_seen 1:7 20

  run radar

  [ "${lines[0]}" = "🦊 💬1" ]
  [[ "$output" == *"“and another thing” (+1 more)"* ]]
}

@test "a comment row opens the note itself and marks the MR read" {
  my_mr iid=7 references.full='g/p!7'
  notes_for 7 <<<"$(json_array "$(note 30 ann)")"
  mark_seen 1:7 20

  run radar

  [[ "$output" == *"param1=--open-seen param2=\"https://gitlab.example.com/g/p/-/merge_requests/1#note_30\" param3=\"1:7\" param4=\"30\""* ]]
  [[ "$output" == *"mark read without opening | alternate=true"* ]]
  [[ "$output" == *"Mark all read | size=11"* ]]
}

@test "comments on an MR you are reviewing count too" {
  # replies to your own review comments keep coming after you have signed off
  review_mrs <<<"$(json_array "$(mr iid=11 references.full='g/p!11')")"
  notes_for 11 <<<"$(json_array "$(note 30 ann 'fixed, have another look')")"
  approvals_for 11 <<<"$(approvals 1 0 me)"
  mark_seen 1:11 20

  run radar

  [ "${lines[0]}" = "🦊 💬1" ]
  [[ "$output" == *"💬 p!11 — ann: “fixed, have another look”"* ]]
  [[ "$output" == *"(reviewing)"* ]]
}

@test "a pipe in a comment cannot break SwiftBar's markup" {
  my_mr iid=7 references.full='g/p!7'
  notes_for 7 <<<"$(json_array "$(note 30 ann 'try grep foo | wc -l')")"
  mark_seen 1:7 20

  run radar

  [[ "$output" == *"try grep foo ¦ wc -l"* ]]
  [[ "$output" != *"try grep foo | wc -l"* ]]
}

@test "a pipe in an MR title cannot break SwiftBar's markup either" {
  my_mr iid=7 references.full='g/p!7' title='support a|b alternation'

  run radar

  [[ "$output" == *"support a¦b alternation"* ]]
}

# ------------------------------------------------------------------ to-dos

@test "every kind of to-do the radar words gets its own label" {
  todos_are <<<"$(json_array "$(todo 1 mentioned)" "$(todo 2 directly_addressed)" \
                             "$(todo 3 unmergeable)" "$(todo 4 approval_required)" \
                             "$(todo 5 assigned)")"

  run radar

  [[ "$output" == *"TO-DOS"* ]]
  [[ "$output" == *"🏷 Ann Other mentioned you"* ]]
  [[ "$output" == *"🗣 Ann Other replied to you"* ]]
  [[ "$output" == *"⚠️ cannot be merged"* ]]
  [[ "$output" == *"✍️ approval required"* ]]
  [[ "$output" == *"📌 assigned to you"* ]]
}

@test "a to-do you caused yourself is not news" {
  todos_are <<<"$(json_array "$(todo 1 mentioned author.username=me)")"

  run radar

  [[ "$output" != *"TO-DOS"* ]]
}

@test "the to-do list is capped at MAX_TODOS" {
  radar_config 'MAX_TODOS=2'
  todos_are <<<"$(json_array "$(todo 1 mentioned)" "$(todo 2 mentioned)" \
                             "$(todo 3 mentioned)")"

  run radar

  [ "$(grep -c 'mentioned you' <<<"$output")" -eq 2 ]
}

@test "a review request is not listed twice as a to-do" {
  # it already has a row in WAITING FOR YOUR REVIEW, with the same action on it
  review_mrs <<<"$(json_array "$(mr iid=11 references.full='g/p!11')")"
  notes_for 11 <<<'[]'
  approvals_for 11 <<<"$(approvals 1 1)"
  todos_are <<<"$(json_array "$(todo 42 review_requested target.iid=11)")"

  run radar

  [[ "$output" != *"TO-DOS"* ]]
}

# --------------------------------------------------- watched default branches

@test "a broken default branch on a project you have an MR in is counted" {
  radar_config 'WATCH_MR_TARGET_MAINS=1'
  my_mr iid=7 references.full='g/p!7'
  project_is 1 <<<"$(project main g/p)"
  pipelines_for 1 main <<<"$(pipeline failed 600)"

  run radar

  [ "${lines[0]}" = "🦊 ❌1" ]
  [[ "$output" == *"❌ p · main — pipeline failed 10m ago"* ]]
}

@test "default branches that are green are summed up in one line" {
  radar_config 'WATCH_MR_TARGET_MAINS=1'
  my_mr iid=7 references.full='g/p!7'
  project_is 1 <<<"$(project main g/p)"
  pipelines_for 1 main <<<"$(pipeline success)"

  run radar

  [ "${lines[0]}" = "🦊 | color=#6e6e73" ]
  [[ "$output" == *"🟢 1 watched default branch(es) passing"* ]]
}

@test "watching MR target projects can be turned off" {
  # the default config the installer writes has it on; this is the escape hatch
  # for someone with dozens of MRs across dozens of projects
  my_mr iid=7 references.full='g/p!7'
  project_is 1 <<<"$(project main g/p)"
  pipelines_for 1 main <<<"$(pipeline failed)"

  run radar

  [ "${lines[0]}" = "🦊 | color=#6e6e73" ]
  refute_called_with curl '/pipelines'
}

@test "an explicitly watched project is looked up by its path" {
  radar_config 'WATCH_MAIN_PROJECTS="platform/api"'
  project_is 'platform%2Fapi' <<<"$(project main platform/api)"
  pipelines_for 'platform%2Fapi' main <<<"$(pipeline failed)"

  run radar

  [ "${lines[0]}" = "🦊 ❌1" ]
  [[ "$output" == *"❌ api · main — pipeline failed"* ]]
}

@test "a watched project can name a branch other than its default" {
  radar_config 'WATCH_MAIN_PROJECTS="platform/api:develop"'
  project_is 'platform%2Fapi' <<<"$(project main platform/api)"
  pipelines_for 'platform%2Fapi' develop <<<"$(pipeline failed)"

  run radar

  [[ "$output" == *"❌ api · develop — pipeline failed"* ]]
}

@test "a project watched twice is only fetched once" {
  radar_config 'WATCH_MR_TARGET_MAINS=1'
  my_mrs <<<"$(json_array "$(mr iid=7 references.full='g/p!7')" \
                          "$(mr iid=8 references.full='g/p!8')")"
  mr_detail 7 <<<"$(mr_json)"; notes_for 7 <<<'[]'; approvals_for 7 <<<"$(approvals 0 0)"
  mr_detail 8 <<<"$(mr_json)"; notes_for 8 <<<'[]'; approvals_for 8 <<<"$(approvals 0 0)"
  project_is 1 <<<"$(project main g/p)"
  pipelines_for 1 main <<<"$(pipeline success)"

  run radar

  [[ "$output" == *"🟢 1 watched default branch(es) passing"* ]]
}

# ------------------------------------------------------------- all at once

@test "the title counts each kind of attention separately, in a fixed order" {
  my_mrs <<<"$(json_array "$(mr iid=7 references.full='g/p!7')")"
  mr_detail 7 <<<"$(mr_json head_pipeline.status=failed)"
  notes_for 7 <<<"$(json_array "$(note 30 ann)")"
  approvals_for 7 <<<"$(approvals 1 0 ann)"
  mark_seen 1:7 20
  review_mrs <<<"$(json_array "$(mr iid=11 references.full='g/p!11')")"
  notes_for 11 <<<'[]'
  approvals_for 11 <<<"$(approvals 1 1)"

  run radar

  [ "${lines[0]}" = "🦊 ❌1 👀1 💬1 ✅1" ]
}

@test "a GitLab that answers nothing but /user still renders a usable menu" {
  # every list call failing is what a revoked scope or a partial outage looks
  # like; the radar must not go blank
  route "*scope=created_by_me*" 22 </dev/null
  route "*reviewer_username=*" 22 </dev/null
  route "*/api/v4/todos?*" 22 </dev/null

  run radar

  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "🦊 | color=#6e6e73" ]
  [[ "$output" == *"No open MRs of yours"* ]]
  [[ "$output" == *"Open GitLab: my MRs"* ]]
}

@test "the footer links out to the three lists the radar summarises" {
  run radar

  [[ "$output" == *"href=https://gitlab.example.com/dashboard/merge_requests?author_username=me"* ]]
  [[ "$output" == *"href=https://gitlab.example.com/dashboard/merge_requests?reviewer_username=me"* ]]
  [[ "$output" == *"href=https://gitlab.example.com/dashboard/todos"* ]]
}
