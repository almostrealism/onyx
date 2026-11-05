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
- **Links in the terminal open with a click** — no copy mode, no ⌘.
  Only a plain click does it (not a drag or a double click, and not the
  click that brings Onyx forward), and only web and mail links open from
  the terminal; ⌘-click still works as before.
