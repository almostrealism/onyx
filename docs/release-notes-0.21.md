# Onyx 0.21

## Before you update

- **macOS asks for permissions once more.** Onyx's identifier is now
  `ai.almostrealism.onyx` (it was `com.onyx.terminal`). On first launch
  Onyx copies your settings, window positions and browser-tab logins
  across from the old identifier, and leaves the old copies where they
  were, so an older build still works. macOS ties privacy permissions to
  the identifier, so expect it to ask again for Reminders, Calendars,
  notifications and Messages.
- **Reinstall the bridge on your hosts** when CONNECTIONS says "update
  available" (bridge protocol 6, below).

## Keeping sessions in view

- **A compact window (⇧⌘D).** The whole window becomes simple mode's side
  panel: sessions and their Claudes, today's reminders or calendar, and
  PRs. It's small enough to sit at the side of the screen. Nothing else is
  drawn behind it, not even the monitor if it was open. Claude's
  permission prompts still appear, since they need an answer. ⇧⌘D again,
  the corner button, or clicking a session brings back the full window.
  Each shape remembers its own size and place, per window, across
  launches. Typing while compact doesn't reach the hidden terminal.
- **A desktop widget for your sessions.** Add "Onyx Sessions" from the
  desktop's Edit Widgets, in small, medium, large or extra large. It lists:
  - your noted sessions and the ones with a Claude;
  - what each Claude is doing, in amber when it's waiting for permission;
  - how long each session has been quiet.

  Click a session to open it in Onyx. Where there's room, it also shows
  your open PRs' CI, as simple mode's column does. The large always keeps
  room for three PRs, and the extra large gives them a column of their
  own. Click a PR to open it. A Claude that starts waiting, or a PR that
  starts failing, updates the widget at once. When Onyx isn't running,
  the widget says so rather than showing old status as live. The widget
  comes only in the signed DMG; a build from source has none.

## Claude sessions

- **Quitting Claude takes it off the list.** Claude starts a new session
  every time it launches, so opening and quitting it a few times left a
  row behind for each one, for five minutes. Now a session goes when
  Claude quits or you `/clear`. A Claude started in a tmux pane also
  replaces the one that ran there before, even one that was killed
  without saying goodbye. Hosts need the new bridge (protocol 6) and its
  hooks, so they show "update available" until reinstalled.
- **A Claude at work in one of your sessions is part of that session.**
  When Onyx can tell which tmux session a Claude is running in, that
  session is in the sessions list, whether or not it has a note. A second
  line in purple says what Claude is doing. Its favorite tab carries a
  purple mark, which turns amber and pulses while Claude waits for
  permission. The session's idle clock counts Claude's activity as well
  as the terminal's. CLAUDE SESSIONS now lists only the Claudes Onyx
  can't place. A Claude that quit while your Mac was asleep is noticed
  within a couple of minutes of reconnecting.

## Terminal

- **Links in the terminal open with a click**, with no copy mode and no ⌘.
  Only a plain click does it: not a drag, not a double click, and not
  the click that brings Onyx forward. Only web and mail links open from
  the terminal, for ⌘-click too.

## Monitor

- **GPU charts are half as tall.** The squares stay the same size, and
  there are half as many of them. A GPU is usually off, drawing, or
  maxed, and doesn't need CPU-sized detail to say so. CPU and memory get
  the room.
- **The fleet layouts show the top six hosts, not five**, so simple mode's
  side-by-side fleet is a full two-by-three grid.
- **Simple mode's PR list shows only PRs with CI to show.** A PR whose
  workflows are all switched off in "CI on open PRs", or that has run
  none, leaves simple mode's column and the iPhone's Today page. The full
  overlay still lists every PR.
- **Simple mode's side panel scrolls** when its sections don't fit, like
  the full layout's columns, instead of cutting off at the bottom.

## Menu bar

- **Pipelines are listed by their PR's title.** The workflow and
  "repo#12" read almost the same on every line, so they moved to the
  tooltip, and a PR's runs are listed together. A re-run still shows its
  attempt. A pipeline you track by hand that isn't on a PR keeps its old
  line, since there's no PR title to show.
