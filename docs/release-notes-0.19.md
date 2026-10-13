# Onyx 0.19

Settings you can find your way around, and an answer to "why aren't this
machine's Claude sessions listed?"

The question came up because the sessions list and alerts look like one
feature and aren't. Alerts ride the MCP connection; the sessions list is
fed by Claude Code hooks, which are configured separately, per account, and
run as short-lived processes with a few seconds to work. A host could
deliver every alert and never list a session, with nothing anywhere to say
why. Now the hooks are installed reliably and there are tools to see each
link in that chain.

## Settings

- **Settings is laid out like System Settings**: a list of categories on
  the left (General, Appearance, Hosts, Monitor, Reminders, Pull Requests,
  Page Watches, Alerts, Claude Code, Shared State, Files, Flowtree) and the
  chosen category's settings on the right. It used to be one long
  scrolling column. Settings reopens on the category you last looked at.
- **Reminders has its own pane, and you can reorder the lists.** The order
  used to be whatever order you happened to choose the lists in, so
  changing it meant removing every list and adding them back one at a
  time. Now the chosen lists are shown, numbered, in the order the monitor
  draws them. Drag one to move it, or use the arrows. A list that has been
  renamed or deleted in Reminders stays visible and marked, so you can
  remove it.

## Claude sessions

- **Missing Claude sessions, explained and fixed.** The sessions list is
  fed by Claude Code hooks, which are separate from the connection alerts
  use, so a host could deliver alerts and never list a session. Three
  causes, none of them visible until now:
  - The hooks were never written. The installer merged them using python3
    and, without it (or on a Mac whose python3 is only the Command Line
    Tools stub), skipped them and still reported success. The bridge now
    writes them itself, and an install that can't write them says so.
  - The script for a machine's other accounts registered the bridge but
    wrote no hooks, so an agent run under another account (with `su`, say)
    could alert you and never appear. It installs hooks now.
  - A hook that couldn't reach Onyx in its few seconds failed silently.
    Each hook now tries the route that last worked first, and every hook
    run is recorded on the host.
- **New diagnostics.** Each host's MCP row in CONNECTIONS says when its
  hooks aren't set up. A HOOKS HEARD FROM list shows every machine and
  account Onyx has received hook events from, and when. On a host,
  `OnyxMCP --status` (and the `onyx_status` tool) now reports whether
  hooks are configured, the last hook delivered and the last one that
  failed, and why. `OnyxMCP --hooks-status` gives a one-line verdict, and
  `OnyxMCP --install-hooks` sets them up for whichever account runs it.
- **Sessions say where they're running**: the tmux session, or the machine,
  instead of the first eight characters of an id.
- The bridge protocol is now 4, so hosts show "update available". The
  reinstall is what writes hooks where they were missing.

- **A hook can no longer stall Claude.** Hooks run on every tool call and
  Claude waits for them, up to 60 seconds when no timeout is set. On a
  host where Onyx was unreachable, one agent measured 31 seconds per hook,
  so a minute per tool call. Now every hook gives up at 3 seconds and
  records which step it was stuck in (`OnyxMCP --status` shows it). After
  a hook hangs, the hooks that follow don't try for 30 seconds. Connection
  attempts have a 2-second limit, and the hooks Onyx installs carry an
  explicit `"timeout": 5`.

## Monitor

- **Claude sessions are in the left column in the simple layout too** (the
  column `d` opens), not a band across the whole overlay. With several
  agents running, the band pushed every chart down and could make the
  overlay unusable. Both layouts cap the list (five in the simple column,
  eight in the detailed one) with "+N more"; permission requests are never
  hidden.

## Fixes worth naming

- **The session chips along the bottom no longer show an empty bell**
  once a session's alerts have all been read. That strip is the tightest
  space on the screen, and "you had messages here once" isn't worth a
  slot in it. The bell appears there only while something is unread. The
  monitor still shows the empty bell beside a session's note, and the menu
  bar item still lists the history.

- **With more than one window open, Claude sessions split between them.**
  Each window started its own MCP server: agents on this Mac reached the
  window opened last, and remote hosts reached the first. There is now one
  server and one session list for the whole app.

## Under the hood

- The bridge protocol is 4. Reinstall the bridge on each host when Onyx
  offers to; that is what writes the hooks.
- The test suite is at 1,365, including integration tests that run the
  real bridge to install hooks, check them, and deliver a hook event to a
  stand-in desktop.
