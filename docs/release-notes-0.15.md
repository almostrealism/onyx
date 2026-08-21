# Onyx 0.15

## File browser

- **Favorites are a treemap.** A favorite inside another favorite is drawn
  inside it, so adding both `~/agent1` and `~/agent1/Projects` gives you one
  box containing the other instead of two unrelated buttons. Same-named
  folders disambiguate themselves: two `Projects` get their parent folders
  introduced as containers around them, repeating up the tree until the
  labels differ.
- The layout optimises **legibility, not squareness**. Every cell is at
  least as wide as its own name (recursively — a container is never given a
  width that dooms its children), siblings break across rows like text, and
  spare height is spent widening cells rather than left empty. A cell can
  no longer read `c…n`.
- **Heart in the path bar** adds or removes the folder you're standing in.
  Un-hearting leaves you where you are.
- The **git panel is back** — branch, staged and changed files above the
  listing. It had been silently absent; see below.

## Monitor overlay

- **GPU stats for AMD hosts** via amdgpu's sysfs counters — utilization,
  VRAM, temperature — with no rocm-smi, no root, nothing to install.
- **NPU (Ryzen AI / XDNA)**: the driver exposes no utilization counter, so
  this reports what actually exists — the share of each interval the
  accelerator was powered up, from runtime-PM residency. It catches bursts
  that start and finish between polls. Labelled as residency, not
  utilization, because that's what it is.
- Accelerator probing runs as its own call on its own cadence, and only on
  hosts that can answer it.
- **`R` filters reminders to what's due today or tomorrow**, keeping the
  by-list grouping. Tomorrow's items dim so today's hold the eye; hovering
  restores them, and overdue never dims.
- **Session activity indicators** are deliberately larger than the
  surrounding text — the one thing worth reading across the room.
- Session notes are ordered like the favorites bar and show the **⌘N that
  actually reaches them** (a favorite with no note still owns its number,
  which is what made ⌘4 land on the 5th favorite). The selected row is now
  unmissable.
- Clicking a session note takes you there and closes the overlay.
- **Failing stats no longer take the whole overlay down.** Reminders, PRs,
  pipelines, notes and timing render as usual; only the stats column
  reports the failure.
- **RECENT EVENTS** in the connections panel: probe failures, failovers,
  slot deaths, and failed polls, timestamped, in the host's own words.
- Thicker project-ratio bar on the simple-mode timing tile; the connections
  table can no longer wrap at larger UI font sizes.

## Connections

- **Pause a host** (Settings → HOSTS). Config, favorites, notes and session
  lists are all kept; Onyx simply stops reaching for it, which matters when
  a machine on a bad link is degrading the network for everything else.
  Paused hosts cost zero SSH calls per tick, and nothing un-pauses them but
  you.
- **A connected host is never asked to install an SSH key.** A failed probe
  used to mean exactly that — unconditionally, whatever the actual error —
  and the flag was sticky, so one bad probe latched the overlay on. Only
  OpenSSH genuinely refusing authentication says so now, a live connection
  overrules it, and reconnecting clears the claim.
- Switching sessions by any means except the sidebar list now dismisses
  whatever is covering the terminal.

## Remote execution

Most of this release went into one class of bug: a remote script that
silently didn't run. Four separate causes, each invisible in a different
way, all found the same way in the end — by capturing what the host
actually said instead of guessing.

- **Scripts go over a pipe, not a terminal.** `-tt` is only needed to
  defeat noexec shells, and it costs a ~1KB input queue, a line discipline
  that was observed corrupting the tail of a script (the shell then reports
  "command not found" and exits 127), an echo that pollutes the output, and
  no EOF. It is now the fallback, tried only when the completion marker
  doesn't come back.
- **`!` removed from remote scripts** — history expansion in an interactive
  shell discards the whole line, which killed stats on every zsh host.
- **No unmatched globs** — zsh treats those as fatal, which killed stats
  locally.
- **Payloads stay under a size budget**, enforced by tests, with anything
  larger split into a second command.
- **The TTY echo interleaves**, so the cleaner no longer discards an entire
  response when its boundary heuristic doesn't apply. That one bug had the
  git panel, docker stats and the CPU fleet poller all reading empty.
- Failures now say what happened — the exit code, whether it timed out, and
  the remote's own first line — instead of "connection failed".

## Fixes

- Reordering favorites steps over entries this window doesn't render, so
  one press moves one visible row.
- Reorder chevrons and the pipelines `+` have real hit targets instead of
  glyph-sized ones.
- Paced stdin writes can no longer crash the app on launch when ssh exits
  first.
