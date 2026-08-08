# GitLab Radar

A SwiftBar menu bar plugin for macOS that shows you the GitLab events which
otherwise only arrive by email: failed pipelines, review requests, new comments
on your merge requests, approvals. It polls the GitLab REST API directly. No
server, no webhooks, works with gitlab.com and self-hosted instances.

```
🦊 ❌1 👀2 💬1 ✅1
│  │   │   │   └─ your MRs that someone approved
│  │   │   └─ unread comments on MRs you wrote or review
│  │   └─ MRs waiting for your review
│  └─ failed pipelines (your MRs + watched default branches)
└─ always visible, dimmed when everything is quiet
```

Every count has a section in the dropdown. Clicking a row opens the MR,
pipeline or comment in the browser.

## Install

You need `jq` and [SwiftBar](https://swiftbar.app) first, npm can install
neither:

```bash
brew install jq && brew install --cask swiftbar   # launch SwiftBar once, pick a plugin folder
npx github:triffer/gitlab-radar install
```

The installer asks for your GitLab URL and a personal access token, created
under *User settings → Access tokens*. Scope `api` gives you everything,
including the *mark to-do done* actions; with `read_api` those actions silently
do nothing.

The token goes into the macOS Keychain (service `gitlab-radar`), not a dotfile.
The first time SwiftBar reads that Keychain item, macOS prompts once: choose
**Always Allow**.

```bash
npx github:triffer/gitlab-radar version     # what you have vs. what is installed
npx github:triffer/gitlab-radar uninstall   # plugin, token and cache (keeps your config)
```

## What it shows

- ❌ Failed head pipelines on your open MRs, plus failed pipelines on watched
  default branches. By default the radar watches the default branch of every
  project you have an open MR in; add more with `WATCH_MAIN_PROJECTS`.
- 👀 Open MRs where you are a reviewer and haven't approved yet. Approving
  removes the MR from the list until the author re-requests your review, which
  brings it back badged 🔁 ✓→. A plain 🔁 is a pending *review requested* to-do.
- 💬 Notes from other people since you last looked, on your own MRs and on the
  ones you review. That includes plain replies after you approved, which
  GitLab's to-do list ignores unless someone `@mention`s you. Clicking opens the
  exact comment and marks it read; ⌥-click only marks it read.
- ✅ Your open MRs that someone else approved, so you know they are ready to
  merge. GitLab creates no to-do for this, so the radar reads each MR's
  approvals itself. Unresolved threads get a warning.
- 📋 Your pending GitLab to-dos: mentions, replies, "cannot be merged", approval
  requests, assignments. Each row has a *mark done* action.
- 📄 All your open MRs with pipeline state and target branch.

Sounds are off by default. The 🔕/🔔 row turns them on: one system sound per new
event category per refresh (Basso for a broken build, Ping for a review request,
Pop for a comment, Glass for an approval), never a burst.

### How rows clear

Pipelines, review requests, approvals and the MR list mirror GitLab, so they
only disappear once the underlying state changes. There is deliberately no way
to swipe away a red pipeline.

Comments and to-dos are dismissable. Comment read-state is local, in
`~/.cache/gitlab-radar/`, so marking something read never touches your GitLab
to-do list. To-dos go through the API instead, which keeps that list in sync.

## Updates

The radar asks GitHub for a newer release once a day (`UPDATE_CHECK_HOURS`, `0`
disables it) and puts the answer in the last row of the dropdown:

```
⬆ GitLab Radar 1.2.0 available — read the release notes
↳ you have v1.1.0 · copy the update command
```

Clicking never upgrades anything. The installer is interactive and may ask for a
token, which is not something to hide behind a menu bar row. The second row
copies the right command to your clipboard (`npx github:…#v1.2.0 install`, or
`git pull && ./install.sh` if you installed from a checkout) so you run it where
you can see it. Re-running the installer keeps your config and token.

With no update pending, the row shows the version you are running and links to
the releases page. ⌥-click checks on the spot. The check runs detached from the
refresh, so a slow or missing network never delays the menu bar.

## Token rotation

GitLab caps token lifetime at one year. The radar checks the expiry date daily
and shows a warning row 21 days before it runs out (`TOKEN_WARN_DAYS`). Clicking
that row rotates the token via `POST /personal_access_tokens/self/rotate`, gives
it a fresh one-year expiry and stores it in the Keychain, with no browser
round-trip. That needs GitLab 16.10 or newer and scope `api`; ⌥-click, or an
older GitLab, opens the token settings page for manual rotation.

## Configuration

`~/.config/gitlab-radar/config` is plain bash, sourced by the plugin.

| Variable                | Default              | Meaning                                             |
|-------------------------|----------------------|-----------------------------------------------------|
| `GITLAB_URL`            | `https://gitlab.com` | Your GitLab instance                                |
| `WATCH_MR_TARGET_MAINS` | `1`                  | Watch the default branch of every project you have an open MR in |
| `WATCH_MAIN_PROJECTS`   | *(empty)*            | Extra projects to watch, space separated: `group/project` (default branch) or `group/project:branch` |
| `MAX_TODOS`             | `8`                  | Max to-do rows in the dropdown                      |
| `TOKEN_WARN_DAYS`       | `21`                 | Warn (and offer one-click rotation) this many days before the token expires |
| `UPDATE_CHECK_HOURS`    | `24`                 | How often to ask GitHub for a newer release (`0` = never; ⌥-click still checks on demand) |
| `GITLAB_TOKEN`          | *(unset)*            | Escape hatch: token in the config instead of the Keychain (not recommended) |

The refresh interval is the `3m` in the plugin filename (`gitlab-radar.3m.sh` =
every 3 minutes). Rename the file in your SwiftBar plugin folder to change it.

## How it works

One bash script, a few API calls per refresh:

| Signal                | Source                                                        |
|-----------------------|---------------------------------------------------------------|
| Broken pipelines      | `GET /merge_requests?scope=created_by_me&state=opened` → per-MR `head_pipeline.status`, plus `GET /projects/:id/pipelines?ref=<default>` for watched projects (project metadata cached 24 h) |
| Review requests       | `GET /merge_requests?reviewer_username=<you>&state=opened`, minus MRs you approved (per-MR `GET /approvals`, since the `approved_by` filter is Premium-only) |
| Approvals on your MRs | per-MR `GET /approvals` → `approved_by`, others only           |
| New comments          | per-MR `GET /notes`, diffed against a locally stored last-seen note id |
| To-dos and 🔁 badges  | `GET /todos`, pending only                                    |

Read-markers, the project cache, the sound snapshot and the last update check
live in `~/.cache/gitlab-radar/`. Menu actions are the plugin invoking itself
with a flag (`--seen`, `--todo-done`, `--check-update`, …), so there are no
helper scripts.

## Troubleshooting

- `🦊 ⚠️` in the menu bar means the API is unreachable: VPN down, wrong
  `GITLAB_URL`, or an expired token. The dropdown has a *Test token* action that
  shows the raw API response in a terminal.
- The setup row appears although you installed: SwiftBar could not read the
  Keychain item. Run `security find-generic-password -s gitlab-radar -w` once in
  Terminal and answer *Always Allow*.
- A watched project never shows up: the project cache lasts 24 h. Delete
  `~/.cache/gitlab-radar/projects.json` after renaming branches or projects.
- Comment counts look wrong after switching users: read-markers are per note id
  in `~/.cache/gitlab-radar/seen-comments.json`. Delete that file to
  re-baseline; current comments then count as read instead of being replayed.

## Contributing

Commits on `main` follow
[Conventional Commits](https://www.conventionalcommits.org) (`feat:`, `fix:`,
`docs:`, `chore:`). CI rejects a PR whose commits don't, because the type is what
decides the next version.
[semantic-release](https://semantic-release.gitbook.io) does the rest on every
push to `main`: tag, `CHANGELOG.md`, `package.json`, GitHub Release. Nothing is
published to npm. The git tag is the release artifact and that is what
`npx github:…` installs, so never bump the version by hand.
