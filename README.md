# GitLab Radar

A SwiftBar menu bar plugin that surfaces the GitLab events that otherwise only
reach you by email: **broken pipelines**, **(re-)review requests**, and **new
comments on your merge requests** — polled straight from the GitLab REST API.
Free, no services, no webhooks, works with gitlab.com and self-hosted
instances.

```
menu bar:   🦊 ❌1 👀2 💬1        (a dim 🦊 when all quiet)
             │  │   │   └─ MRs of yours with unread comments
             │  │   └─ MRs waiting for your review
             │  └─ failed pipelines (your MRs + watched default branches)
             └─ always visible, so the radar is easy to spot next to other plugins
```

## Features

- ❌ **Broken builds** — failed head pipelines on your open MRs, plus failed
  default-branch pipelines. By default the radar watches the default branch of
  every project you currently have an open MR in; add more via
  `WATCH_MAIN_PROJECTS`. Click a row to open the failed pipeline.
- 👀 **Review requests** — open MRs where you are a reviewer and haven't
  approved yet. Once you approve, the MR drops out (a dim "already approved"
  line keeps the count) — until the author re-requests your review, which
  brings it back with a 🔁 ✓→ badge. A plain 🔁 badge means a pending *review
  requested* to-do; the submenu shows how long ago and lets you mark it done.
- 💬 **New comments on your MRs** — notes from others since you last looked,
  with author and snippet. Clicking opens the comment in the browser *and*
  marks it read; ⌥-click marks it read without opening. Read-state is local
  (`~/.cache/gitlab-radar`), so it never touches your GitLab to-do list.
- 📋 **To-dos** — mentions, direct replies, "cannot be merged", approvals and
  assignments from your GitLab to-do list, each with a *mark done* action.
- 📄 **MR overview** — all your open MRs with pipeline state, target branch,
  and an "unresolved threads block merging" warning.
- 🔊 **Optional sounds** — off by default; the 🔕/🔔 toggle enables one system
  sound per *new* event category (Basso = build broke, Ping = review
  requested, Pop = new comment). One sound per refresh, never a burst.
- 🔐 **Token lives in the macOS Keychain** (service `gitlab-radar`), not in a
  dotfile.
- 🔁 **Token rotation built in** — GitLab caps token lifetime at one year, so
  the radar checks the expiry date daily and shows a warning row 21 days
  before it runs out (`TOKEN_WARN_DAYS`). Clicking it rotates the token via
  `POST /personal_access_tokens/self/rotate` (GitLab ≥ 16.10, scope `api`)
  with a fresh one-year expiry and stores the new token in the Keychain —
  no browser round-trip. ⌥-click (or older GitLab) opens the token settings
  page for manual rotation instead.

## Install (Mac host)

Requires `jq` and [SwiftBar](https://swiftbar.app):

```bash
brew install jq && brew install --cask swiftbar   # launch SwiftBar once, pick a plugin folder
./gitlab-radar/install.sh
```

The installer asks for your GitLab URL and a personal access token
(create one under *User settings → Access tokens*):

- scope **`api`** — everything works, including "mark to-do done"
- scope **`read_api`** — read-only; the *mark done* actions silently do nothing

It verifies the token, stores it in the Keychain, and copies the plugin into
your SwiftBar plugin folder. Re-run it any time after pulling updates — config
and token are kept. The first time SwiftBar reads the Keychain item, macOS
prompts once: choose **Always Allow**.

Remove everything with `./gitlab-radar/install.sh --uninstall`.

## Configuration — `~/.config/gitlab-radar/config`

| Variable                | Default              | Meaning                                             |
|-------------------------|----------------------|-----------------------------------------------------|
| `GITLAB_URL`            | `https://gitlab.com` | Your GitLab instance                                |
| `WATCH_MR_TARGET_MAINS` | `1`                  | Watch the default branch of every project you have an open MR in |
| `WATCH_MAIN_PROJECTS`   | *(empty)*            | Extra projects to watch, space separated: `group/project` (default branch) or `group/project:branch` |
| `MAX_TODOS`             | `8`                  | Max to-do rows in the dropdown                      |
| `TOKEN_WARN_DAYS`       | `21`                 | Warn (and offer one-click rotation) this many days before the token expires |
| `GITLAB_TOKEN`          | *(unset)*            | Escape hatch: token in the config instead of the Keychain (not recommended) |

The file is plain bash, sourced by the plugin. The refresh interval is encoded
in the plugin filename (`gitlab-radar.3m.sh` = every 3 minutes) — rename the
file in your SwiftBar plugin folder to change it.

## Where rows link, and how they clear

| Row                  | Click opens                                | Cleared by                                                    |
|----------------------|--------------------------------------------|---------------------------------------------------------------|
| ❌ Broken build      | the failed pipeline (⌥-click: the MR)      | fixing it — the row mirrors live state, next passing/running pipeline removes it |
| 👀 Review request    | the MR                                     | approving the MR / being removed as reviewer (re-requesting review brings it back, badged 🔁 ✓→); the 🔁 badge alone via *✓ mark to-do done* |
| 💬 New comment       | the exact comment (`…#note_<id>` anchor)   | the click itself (opens **and** marks read); ⌥-click marks read without opening; *Mark all read* for everything |
| 📋 To-do             | GitLab's deep link (comment anchor etc.)   | *✓ mark done* (syncs to your GitLab to-do list) or resolving it in GitLab |
| My open MRs          | the MR (submenu: its pipeline)             | merging/closing the MR — it's an overview, not an alert       |

Two kinds of rows, two dismissal models: **state rows** (broken builds, review
requests, MR overview) mirror GitLab and only disappear when reality changes —
there is deliberately no way to swipe away a red pipeline. **Event rows**
(comments, to-dos) are dismissable: comments via a local read-marker in
`~/.cache/gitlab-radar/`, to-dos via the GitLab API so your to-do list stays
in sync.

## How it works

One script, three API queries per refresh plus two small calls per open MR:

| Signal                    | Source                                                        |
|---------------------------|---------------------------------------------------------------|
| Broken MR pipelines       | `GET /merge_requests?scope=created_by_me&state=opened` → per-MR `head_pipeline.status` |
| Broken default branches   | `GET /projects/:id/pipelines?ref=<default>` for watched projects (project metadata cached 24 h) |
| Review requests           | `GET /merge_requests?reviewer_username=<you>&state=opened`, minus MRs you approved (per-MR `GET /approvals` — the Premium-only `approved_by` list filter isn't assumed) |
| Re-review badge 🔁        | pending `review_requested` items from `GET /todos`            |
| New comments              | per-MR `GET /notes`, diffed against a local last-seen note id |
| Mentions / replies / etc. | `GET /todos` (pending)                                        |

State (read-markers, project cache, sound snapshot) lives in
`~/.cache/gitlab-radar/`. Menu actions (mark read, mark to-do done) are the
plugin invoking itself with `--seen` / `--todo-done` — no extra scripts.

## Troubleshooting

- **`🦊 ⚠️` in the menu bar** — the API is unreachable: VPN down, wrong
  `GITLAB_URL`, or the token expired. The dropdown has a *Test token* action
  that shows the raw API response in a terminal.
- **Setup row shown although you installed** — SwiftBar could not read the
  Keychain item. Run `security find-generic-password -s gitlab-radar -w`
  once in Terminal, and answer *Always Allow* on the prompt.
- **A watched project never shows up** — the project cache lasts 24 h; clear
  `~/.cache/gitlab-radar/projects.json` after renaming branches or projects.
- **Comment counts look wrong after switching users** — read-markers are per
  note id in `~/.cache/gitlab-radar/seen-comments.json`; delete it to
  re-baseline (current comments are then treated as read, not replayed).
