# Onyx 0.17

The release where agents got a way to reach you.

Until now Onyx showed you things and you watched. This one adds the other
direction: an agent working in one of your sessions can put a page in front
of you, interrupt you when it's blocked, and reach your phone when you're
nowhere near the desk. The rest of the release follows from that — because
once agents can send you something, every gap between "sent" and "seen"
becomes a bug worth fixing.

## Agents can reach you

- **`notify`** — an agent can get your attention. Alerts are urgent by
  default — the dock bounces, and depending on your settings it reaches
  Notification Center and your phone — and the agent is told, firmly, that
  a non-urgent alert reaches nobody and is only for when you've asked it to
  keep quiet. *Where* an alert goes is your choice per Mac (Settings →
  ALERTS ON THIS MAC: every alert, urgent only, never), not the agent's:
  it can't know which machine you're sitting at. Alerts attach to the
  session they came from, so the indicator lights next to the work that's
  waiting rather than in a general list.
- **Alerts on your phone, and therefore your watch.** An Apple Watch
  mirrors an iPhone, not a Mac — macOS notifications never reach it — so
  Onyx sends urgent alerts to something your phone already listens to:
  **ntfy**, **Pushover**, any **JSON webhook** (with `text`/`content`
  aliases so Slack and Discord webhooks work unmodified), or **iMessage to
  yourself**, which needs no signup and, being data rather than SMS,
  survives a carrier that filters gateway traffic. Settings → ALERTS ON
  YOUR PHONE, with a Test button that reports the service's own answer.
- **A menu bar item** listing the sessions you're tracking and which of
  them an agent is trying to reach you about — with the alert text inline,
  so you can read it without switching to Onyx. Tracked pipelines are
  there too, failures first. Clicking a session jumps to it.
- **`show_html`** — an agent can publish a real page into an artifact slot:
  a review summary, a table of results, anything with structure. Links open
  in your browser, so every row can be one click from the thing it
  describes.
- **`onyx_guide`** — agents can ask how to use Onyx. Tool descriptions
  answer "what does this one do"; nothing answered "what can I build with
  these together", so an agent had to discover on its own that publishing
  and alerting are two calls that pair, or that a remote agent can't hand
  Onyx a file path.
- **An outbox.** If Onyx can't be reached when an agent sends an alert, the
  alert is kept and delivered when it can be — retried at session start, on
  the next successful call, and on a one-minute heartbeat, expiring after
  24 hours. It carries the time it was *sent*, so a 2am alert doesn't claim
  to have happened when the network came back. "Nobody's around,
  undeliverable" was never an acceptable answer.

## Installing the bridge

- **One click per host.** Onyx ships the bridge for macOS and Linux inside
  the app and installs it over your existing connection — including
  registering it with Claude Code — with a status light per host in the
  monitor's CONNECTIONS section. A machine with several accounts gets a
  command you can hand to the others.
- **The bridge can explain itself.** When Onyx can't be reached, an agent
  used to be told "unreachable" and nothing more, and had to conclude "it's
  broken". Now every failure says what this host has seen: whether Onyx has
  *ever* answered from here, which desktop, how long ago, over which route,
  and what the last attempt found. An `onyx_status` tool answers the same
  from the host's own records without the desktop running, and
  `OnyxMCP --status` prints it for a person. A session that starts while
  Onyx is closed no longer stays dead — the tools appear when it opens.
- **The install now tells you if it can't reach Onyx afterwards**, naming
  the symptom. Registered is not the same as reachable, and the alternative
  first symptom was Claude hanging for thirty seconds and reporting a
  timeout that named no cause. `OnyxMCP --probe` reports the same thing,
  route by route, at any time.

## Your notes and favorites, on every Mac

- **Settings → SHARED STATE** picks a host, and session notes, favorite
  sessions and tracked pipelines live in `~/.onyx/shared-state.json` there.
  A change reaches your other machines within about a minute, or straight
  away when you switch to one. API tokens never leave the Mac they were
  entered on.
- Your Mac keeps its own copy and works normally when the host is
  unreachable. Changing hosts **merges** — nothing is replaced or deleted —
  and a backup is kept on both ends, never overwritten by an empty one.
- **Notes and favorites are keyed by user@host and session name**, not by
  an internal id. Deleting a host in Settings and adding it back used to
  lose every note attached to it.

## Pipelines

- **Every open PR shows its own CI.** Under each PR in the monitor: the
  latest run of each workflow on its branch, the run number, the attempt
  when it's a re-run, how long ago, and — when it's red — which jobs
  failed. They're in the menu bar too, failures first. Nothing to add
  and nothing to remove after the merge; tracking is now for pipelines
  that aren't on a PR (a nightly, a release).
- **Attempt numbers.** A GitHub run on its second or later try says so,
  in the monitor and in the menu bar. It's invisible on the run's own page
  until you open it.
- **Adding a pipeline** is now a panel rather than a popover — see below.
  And its URL field works for a second pipeline: it used to stop
  accepting paste after the first.

## Keyboard

- **⇧⇥ can be given back to the terminal** (Settings → KEYBOARD). Claude
  Code uses Shift-Tab to switch permission modes, and a key the terminal
  never receives looks exactly like a program ignoring it. ⌘1–9 and ⌘J
  switch sessions either way.

## Fixes worth naming

- **The "+" on the pipelines section crashed the app.** A SwiftUI popover
  that changes size animates an AppKit window resize, and the animation
  runs a nested runloop in which a stale observer is called — a null
  pointer, with no Onyx frames in the crash report at all. Adding a
  pipeline is a panel now, and nothing resizes.
- **A missing copy on the home host wiped everything.** A fetch that came
  back empty-handed while ssh was flapping was merged as though the remote
  had deleted every note, favorite and pipeline — and then pushed. A
  missing file is not a deletion. Any sync that would empty everything at
  once is now refused outright and says so.
- **A note typed while a sync was running would vanish**, or an edit would
  revert a few seconds later. The sync merged against a snapshot taken
  before the fetch, so anything typed during it was written away.
- **Killing a session left it in the list looking healthy** for thirty
  seconds, then grayed out for ten minutes. It's removed at once now.
- **Favorites appeared twice** in the bar, and each duplicate silently ate
  a ⌘-number.
- **Clearing a session note didn't always clear it** — it would come back,
  with no way to remove it from the UI at all.
- **MCP connections dropped after working for a while.** Two causes: Onyx
  answered JSON-RPC notifications, which is a protocol violation the client
  drops the connection over (`notifications/cancelled` is sent on every
  interrupt), and a connection failover could leave a host with no route
  back to Onyx at all. Both fixed; the second is now repaired explicitly
  every time a connection comes up.
- **A port that accepts and says nothing is no longer trusted.** The
  bridge waited out a thirty-second timeout on it — which is exactly
  Claude's startup budget, so the session began with a hang and an
  unexplained failure.

## Under the hood

- `AppState` and `TerminalSessionManager` were split by subject; both had
  grown past the point where the file could be read as one thing, and one
  had crossed SwiftLint's hard limit. Lint is down from 305 warnings to 64,
  with two rules disabled that were arguing with deliberate style.
- One version number now drives the app, the bridge, the bundle and the
  release tag. The bridge additionally reports a protocol number, because
  matching version strings never proved two binaries agree.
- The test suite is at 1,233, including the ~1KB remote-script ceiling
  measured for every script that can reach a terminal — which found one
  already over.
