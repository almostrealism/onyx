# Matched sessions: one session, its notes and its Claudes

A **matched session** is a tmux session Onyx already tracks with at least
one Claude its hooks place there confidently. Matched sessions are part of
the sessions list; the CLAUDE SESSIONS list keeps only the Claudes Onyx
can't place.

## Matching

Hook events carry `onyx_origin`: machine (the host's short `hostname`),
account, tmux session and pane. A Claude matches a session when exactly one
tmux-backed session fits:

- the tmux session name is equal;
- the machine is one of the host's names: the configured `ssh.host`
  (prefix match on a dot boundary, as alert routing does), or the
  `hostname` Onyx learned by asking the host — a host configured by alias
  or IP address carries no name to match otherwise. Learned names persist
  (`HostMachineNames`); a local host's is this Mac's;
- the account is equal — and if nothing fits, the account is ignored and a
  single fit is still believed (a Claude under `su` reports the account it
  became, not the one Onyx connected as).

Anything ambiguous stays unmatched. `ClaudeSessionMatching` (OnyxCore) is
pure and is where the tests live.

## Lifetime

Unmatched Claudes keep the old rule: listed for five minutes after their
last event. A Claude from a bridge that reports its pane (protocol 6, which
also sends `SessionEnd`) is believed alive until it ends — `SessionEnd`, a
new Claude in the same pane, or the pane check below.

**A missed `SessionEnd`** (laptop asleep, connection down) must not leave a
session marked forever. Every two minutes, for each host with a matched
Claude that has gone quiet, Onyx runs one `tmux list-panes` and ends the
Claudes whose pane is gone or back at a shell. A Claude whose tmux session
isn't in that output at all can't be judged and is left alone (it may be
another tmux server); if the session is really gone, enumeration drops it
and the Claude falls back to the unmatched five-minute rule. After a sleep
the check is overdue, so it runs as soon as the host is usable again.

## What it looks like

- **Sessions list** (detailed overlay and simple mode's side panel): every
  noted session and every matched session. A matched row has a second line
  in purple saying what Claude is doing; one without a note is labeled by
  the session's name.
- **CLAUDE SESSIONS**: permission requests, and unmatched Claudes only.
- **Favorites bar**: a purple mark on a matched tab, amber and pulsing while
  a Claude there waits for permission.
- **Idle clocks**: a matched session's last activity is the later of its
  terminal output and its Claudes' last hook event.
