# Onyx 0.16

The first release shaped mostly by other people using it. Several things
here exist because a user asked a question whose real answer was "you
can't, actually" — and a few because the answer was "you can, but nothing
told you so".

## Getting around

- **New sessions claim a ⌘-number automatically.** Switching sessions by
  keyboard needed a favorite first, so the fast path was gated behind a
  concept you hadn't met yet — the question that surfaced this was "is
  there a shortcut to toggle between sessions". The first nine sessions in
  a window now arrive ready to jump to. It only ever adds: nothing is
  reordered, and a session you unfavorite stays that way.
- **Picking a session in the list closes the list.** It used to stay open
  on the theory you might flip between several — but you pick one, and then
  the list is sitting over the terminal you just asked for. ⌘J reopens it.
- **Rename and kill sessions** from the session list, right-click. A rename
  carries the session's note and its ⌘-number across, since a session's
  identity is its name and both are keyed to it. Names are restricted to
  letters, digits, `-` and `_` — narrower than tmux allows, because tmux
  reads `.` and `:` as separators and a session named with them can't be
  targeted afterwards.
- **⌘⌥← and ⌘⌥→** move the keyboard between the terminal and the open side
  panel. Directional rather than a toggle: you shouldn't have to know where
  focus is to predict where it lands. The file browser says which way round
  it currently is, and which key sends the keyboard back — on screen, where
  someone stuck in the panel is actually looking.
- **A guided tour** on first launch, and under Help → Onyx Walkthrough
  after that. Organised by the job rather than by the key, because the
  shortcut list answers "what does ⌘J do" and not "what can this do for
  me".
- The **Help menu** opens that help, instead of macOS reporting that help
  isn't available for Onyx.

## Drag a file onto the terminal

Terminal.app inserts a dropped file's path, and that gesture has become how
people point Claude Code at a file. Onyx does it too — and over SSH, where
the path would otherwise be meaningless, it copies the file to
`~/.onyx/dropped` first and inserts where it landed. Sessions inside a
container take a second hop, so the path names a file the shell in the
container can actually open.

The upload rides the host's existing connection as a multiplexed channel,
like everything else here: a drop never opens another connection.

## Watching more than one machine

- **Two fleet layouts.** `F` cycles what the charts are about: this host,
  the busiest few hosts one row each, or the whole fleet collapsed to one
  CPU and one GPU chart where each column is the max across machines — if
  anyone is busy, we're busy. Every row shares a time axis, so a spike on
  one machine lines up with a spike on another.
- Memory can't be merged that way (an absolute number over wildly different
  totals), so the merged view puts per-host memory charts underneath as
  small multiples.
- **`S` and `F` are separate axes now.** `S` is detailed vs. simple; `F` is
  which machines. They compose, and fleet mode applies to the detailed
  layout too.
- **AMD GPUs are visible to the fleet views.** They were reported by the
  active-host poller but not the fleet sweep, so an AMD box pinned at 100%
  showed nothing at all — and with no other GPU host, the merged chart
  disappeared entirely rather than reading zero.
- **`T` zooms the fleet window** — ten minutes at one sample per column, or
  an hour averaged. It can't change how often the fleet is sampled (that
  sweep is shared with the screensaver), so it changes how much time is on
  screen, and says which.
- Fleet views carry the side panel and the bottom strip, and their
  containers strip is **merged across the fleet** — the busiest containers
  anywhere, each labelled with its host.

## Simple mode

- The left column (`D`) now lists **session notes above today's
  reminders** — both halves of what's on your plate, in the view you leave
  up on a second screen. Sessions show a colour only: at that distance the
  colour is the status.
- Reminders in that column are **grouped by list**, in your configured
  order, and filtered strictly to today and earlier.
- With the column up, the activity pills in the corner are hidden rather
  than saying the same thing twice.

## Pull requests

- **Watch a whole GitHub owner or GitLab group.** One line — `almostrealism`,
  `fivn` — instead of a hand-maintained list that's always missing the repo
  someone created yesterday. GitLab groups cover their subgroups.
- **Filter drafts**: all, hide drafts, or only drafts. A PR counts as a
  draft if the forge says so *or* if its title starts with `Draft:`, `WIP:`
  or `[draft]` — which is GitLab's actual mechanism, and a convention plenty
  of GitHub teams use on PRs the API considers ready.

## Page watches

Some things you're waiting for aren't announced, they're edited: a
configurator gains an option, a status page loses the word "degraded", a
vendor deletes their own "coming later" notice. A watch is a URL, a string,
and whether you care about it appearing or disappearing. Buried at the
bottom of Settings, polled no more often than every five minutes.

The first check only establishes a baseline and never fires, firing needs a
transition rather than a state, and a failed check records the error
without disturbing the baseline — a watch quietly 403ing for a week is
worse than no watch, because you think you're covered. The last check time
is shown under the monitor headline, and goes amber when it's stale.

## Fixes

- **The file browser was eating every space typed into the terminal.** With
  the panel open and a file selected, space toggled a preview and never
  reached the shell. Bare keys are now claimed by whichever component
  actually holds the keyboard — the same authority that decides where your
  typing goes, so the two can't disagree. `⌘Y` previews from anywhere, and
  space in the file browser's own search box types a space.
- **Focus stopped drifting to the side panel.** Closing the monitor or the
  session list re-asserted panel focus merely because a panel was open. A
  panel isn't modal; it claims the keyboard when it opens and not
  afterwards.
- **The keyboard can no longer go nowhere.** Handing it away without
  anything taking over left it with the window, where keystrokes are simply
  discarded — clicking between the terminal and the panel a couple of times
  could land you there, with no sign except that nothing worked. Whenever
  nobody holds the keyboard it now goes back to the terminal.
- **Clicking the terminal takes the keyboard**, rather than hoping the
  terminal wins a race with a focused text field. That was the "clicked the
  terminal, still typing into the search box" case. An empty search box also
  closes when you click away; one with a query in it stays, because those
  results cost a round trip.
- The **focus outline** (Settings → DEBUG) now follows the keyboard between
  events instead of only correcting itself on the next keystroke.
- **The session idle clock was measuring the wrong thing.** It could only
  see sessions still in the terminal pool, and the pool drops anything you
  haven't looked at for five minutes — so "time since last output" quietly
  became "time since we stopped watching", and a busy session read as
  quiet. It now reads tmux's own activity timestamp for every session on
  the host, pooled or not.
- **Clicking in ⇧⌘C text mode hung the app** for up to a minute and a
  half. Selectable SwiftUI text is backed by a text field on macOS, and
  clicking one re-runs text layout across the whole string for every
  tracked mouse position — fine for a label, ruinous for a captured
  terminal screen. It's a proper text view now, so holding the mouse down
  costs nothing.
- **A 30-second hang** when search results were large. The results tree was
  rendered recursively inside a lazy stack, which can only be lazy about
  its direct children — so the whole tree was measured and placed on every
  layout pass. It's flattened now.
- **Slack and other sites no longer refuse to load** in a browser tab.
  WKWebView's user agent is Safari's without the `Version/… Safari/…`
  tokens, so anything sniffing for Safari saw an unknown browser.
- **The dock bounces when an agent is blocked** on a permission decision —
  it times out after 120 seconds, so an unnoticed request isn't delayed, it's
  abandoned. It stops when you answer or when it expires.
- **Double-click the top of the window to zoom** again. Hiding the title bar
  meant content sat where the title bar would be and swallowed the click.
  Honours your "double-click a window's title bar to" setting.
- 12/24-hour clock and show-all-containers **moved to Settings** from the
  overlay's key list. Both keys still work. Show-all-containers is now
  persisted and has one source of truth, so it can't disagree with itself
  across windows, and the header says "all" when the idle filter is off.

## Packaging

- `release.sh` publishes a version to GitHub Releases: tag, notes and the
  DMG, refusing to ship a disk image Gatekeeper would reject, and checking
  the resulting download URL actually resolves before calling it done.
- Script-installed builds **stamp their real version**. Crash and hang
  reports used to say `0.1.0` regardless of what was installed, which made
  a user's report impossible to tie to a build.
