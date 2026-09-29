# Onyx 0.18

A release of small repairs, most of them to things 0.17 introduced and
people then actually used.

Nothing here is a new direction. It's the gap between a feature existing
and a feature working for the person in front of it: the Mac you're
sitting at couldn't install the bridge from the UI, pasted text was
unreadable, the embedded browser dropped every keystroke, and a Linux
host had no bridge to download. Each of those looked fine from where we
were standing.

## Installing the bridge on this Mac

- **The Mac running Onyx gets its own install button.** The monitor's
  CONNECTIONS panel now starts with a THIS MAC row, with the same light
  and Install button every remote host has. The installer always supported
  this machine; the panel just left it off the list, so the one machine
  without a button was the one in front of you.
- **Claude Code is found where its own installer puts it.** A local
  install runs under the app's PATH rather than a login shell's, which
  has neither `~/.claude/local/claude` nor `~/.npm-global/bin/claude`. Both
  are now looked for, instead of registering nothing and reporting that
  Claude isn't installed.
- **Linux bridges are on the GitHub release**, x86-64 and arm64 (DGX
  Spark, Graviton, Ampere). 0.17 was published with only the DMG: CI tried
  to attach the Linux binaries seconds after the tag, minutes before the
  release existed, and failed every time. The release is now written by one
  thing. It takes the bridges out of the app inside the DMG it's publishing,
  so what a Linux host downloads is byte-identical to what the app installs.

## Pipelines

- **Each PR's CI says which job it's on.** "Running" describes a
  five-minute test job and a forty-minute deploy identically. Every run
  under a PR now names the running job that started most recently. When
  nothing is running but the run isn't over, it names the newest queued job
  instead, in amber with an hourglass. A GitLab `manual` job is not counted
  as queued: it's waiting for a person, and calling it queued would make a
  pipeline that is waiting on you look like one that's getting on with it.

## The simple monitor's side panel

The column that `d` opens in the across-the-room layout:

- **Sessions are clickable**, as they are in the detailed overlay. A
  compact copy of a list that does less than the original is just a worse
  version of it.
- **Open PRs join the column**, one line each: the branch on the left, and
  on the right the pipeline the PR is busy with and the step it's on. A PR
  with nothing running says "passed" or "failed" instead.
- **Busy PRs come first.** Up to six, in three tiers: something running or
  queued (newest first), then nothing in flight but something red, then
  finished and green. A run that's red and still going counts as busy,
  because what it's doing now is the live fact. A green PR needs nothing
  from anyone, so it's the first dropped when the list overflows. Within a
  tier the forge's own order is kept, so the list doesn't reshuffle under
  the pointer on every poll.
- **The column is about 20% wider**, since a branch name next to a pipeline
  step is the widest thing it holds. The window size at which it appears
  hasn't changed.

## Fixes worth naming

- **Pasted text was dark gray and hard to read.** zsh and bash 5.1+
  highlight pasted text with reverse video. Onyx's terminal background is
  transparent so the window shows through. Inverting a transparent
  background gave another transparent one, and the light text inverted to
  dark gray, so the result was dark gray on nothing. Reversed cells now get
  a solid light background with dark text, as in any other terminal. This
  also fixes reverse video anywhere else it's used: `less`'s prompt, editor
  selections, status lines.
- **The embedded browser was barely usable.** Three problems with one
  cause: code that assumed every session comes from tmux.
  - *Focus:* every click on a web page was also treated as a click on the
    hidden terminal behind it, which took the keyboard straight back, so
    text fields on a page couldn't be typed into.
  - *The session list:* each refresh rebuilt it from what's running on
    your hosts, and a browser tab isn't running anywhere, so the tab you
    were looking at kept vanishing from the list.
  - *Favorites:* a tab's favorite and note were keyed by the site it was
    showing, so following a link lost both. They're keyed by the address
    the tab was opened with now, and existing ones still resolve.
- **Selecting text with the mouse in the ⌘; note field could hang the
  app**, or leave the field unable to take typing. A click in the note
  field was treated as a click on the terminal behind it, and handing the
  terminal the keyboard ran in the middle of the field's own selection
  drag. The note editor, window rename, help, the walkthrough and the
  pipeline adder all had this problem. They're now all on the one list of
  things that cover the terminal.
- **⌘K commands couldn't be clicked.** The rows looked like buttons and
  weren't. They are now, with hover highlighting, and Return runs the top
  match. Before, a command with no shortcut, such as Install Onyx MCP,
  could only be run by the mouse, and the mouse didn't work.

## Under the hood

- The terminal's background is a small Objective-C `NSColor` subclass,
  transparent when painted and opaque when inverted. It's Objective-C
  because Swift can't subclass `NSColor`. It's macOS-only and the Linux
  bridge build never compiles it.
- The bridge protocol is unchanged (3), so bridges installed by 0.17 are
  current and don't need reinstalling.
- The test suite is at 1,335. The reverse-video fix is tested by drawing a
  real terminal and reading its pixels, with a control that reproduces the
  original bug.
