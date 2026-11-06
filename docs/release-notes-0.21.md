# Onyx 0.21

Draft — still being assembled.

## Claude sessions

- **Quitting Claude takes it off the list.** Each time Claude starts it has
  a new session, so opening and quitting it a few times left a row for
  every one of them for five minutes. Now a session goes when Claude
  quits or you `/clear`, and a Claude started in a tmux pane replaces the
  one that ran there before, even one that was killed without saying
  goodbye. Hosts need the new bridge (protocol 6) and its hooks, so they
  show "update available" until reinstalled.
- **A Claude at work in one of your sessions is part of that session.**
  When Onyx can tell which tmux session a Claude is running in, that
  session is in the sessions list whether or not it has a note, with a
  second line in purple saying what Claude is doing. Its favorite tab
  carries a purple mark (amber and pulsing while Claude waits for
  permission), and its idle clock counts Claude's activity as well as
  the terminal's. CLAUDE SESSIONS now lists only the Claudes Onyx can't
  place. A Claude that quit while your Mac was asleep is noticed within
  a couple of minutes of reconnecting.

- **Simple mode's PR list shows only PRs with CI to show.** A PR whose
  workflows are all switched off in "CI on open PRs" (or that has run
  none) leaves simple mode's column and the iPhone's Today page; the full
  overlay still lists every PR.
- **The fleet layouts show the top six hosts, not five**, so simple
  mode's side-by-side fleet is a full two-by-three grid.
- **The menu bar's pipelines are listed by PR title.** The workflow and
  "repo#12", which read almost the same on every line, moved to the
  tooltip; a PR's runs sit together.
- **GPU charts are half as tall**, with the same size squares and half as
  many: a GPU is usually off, drawing, or maxed, and doesn't need CPU-sized
  detail to say so. CPU and memory get the room.
- **Links in the terminal open with a click** — no copy mode, no ⌘.
  Only a plain click does it (not a drag or a double click, and not the
  click that brings Onyx forward), and only web and mail links open from
  the terminal; ⌘-click still works as before.
- **A compact window (⇧⌘D).** The whole window becomes simple mode's side
  panel — sessions and their Claudes, today's reminders or calendar, PRs
  — small enough to sit at the side of the screen. ⇧⌘D again (or the
  corner button, or clicking a session) brings back the full window.
  Each shape remembers its own size and place, per window, across
  launches.
- **Onyx's identifier is now `ai.almostrealism.onyx`** (it was
  `com.onyx.terminal`). On first launch Onyx copies your settings, window
  positions and browser-tab logins across from the old identifier; the
  old copies are left where they were. macOS ties privacy permissions to
  the identifier, so it will ask once more for Reminders, Calendars,
  notifications and Messages.
- **A desktop widget for your sessions.** "Onyx Sessions" (small, medium,
  large or extra large) lists your noted sessions and the ones with a
  Claude, what each Claude is doing — amber when one is waiting for
  permission — and how long each has been quiet. Click a session to open
  it in Onyx. Where there's room it also shows your open PRs' CI, as
  simple mode's column does; click one to open the PR. It says so when
  Onyx isn't running rather than showing old status as live.
