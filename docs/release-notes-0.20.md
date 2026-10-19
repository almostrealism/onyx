# Onyx 0.20

Draft — still being assembled.

## Timing

- **Up to three Timing.app projects at once.** Settings → Monitor → Filter
  Projects now takes up to three top-level projects, in the order you
  choose them (each chip shows its place). Each one gets its own bars and
  numbers:
  - The week chart has one bar per project for each day, side by side,
    each split by that project's subprojects as before. A thin strip in
    the project's color under each bar, matching the dots in the header,
    tells them apart.
  - The legend is the union of every selected project's subprojects (and
    the projects themselves, when time is logged to them directly), most
    time first, whichever project it's under. It wraps onto more lines
    when it needs to.
  - The numbers are columns: one per project plus a total, each with
    the week's hours above its hours per day (with the 4-week and 30-day
    averages in small type), and the column's label underneath, so it
    can't be confused with the legend's subproject names. Fewer projects
    means fewer, wider columns. One project gets a single column, since
    its total would repeat it.
  - In the simple layout, the corner widget repeats once per project,
    with the project's name above it. Every tile has its colored bar,
    including a project whose time is all in one subproject, where the
    bar is solid. It used to appear only when there was more than one
    part.

  "All" still clears the selection, and a single project looks exactly as
  it did before. An existing single-project filter carries over.
- **Projects with no color in Timing keep the same fallback color**: from
  launch to launch, and between a bar and its legend dot. The fallback
  used to come from a hash that changes every launch, and the chart and
  legend each chose their own.
- **The simple monitor's charts stay above the bottom strip.** They were
  sized without counting their own titles and spacing, so they ran down
  behind the strip's text. With the memory chart on, the Timing tiles'
  labels were half covered. Each chart's full height is now counted, and
  nothing in the chart area can draw past it.
- **Fleet charts per machine go side by side past three machines.** In the
  simple layout, four or more machines used to be stacked in one column
  that never fit the screen. Now a column holds at most three machines:
  four are split 2 + 2, five are split 3 + 2.
- **The simple monitor's bottom strip shows PR jobs in flight, as well as
  containers.** A PR with a job running or queued gets a pill with its
  branch and the job's name, colored as in the side panel: blue for
  running, amber for queued. Click a pill to open the PR. The strip's
  three slots go to whatever matters most right now. A container doing
  real work (about a third of a core or more) comes before a PR's job,
  and a PR's job comes before an idle container. A PR the side panel is
  already listing doesn't take a slot. Slots don't flip back and forth
  when two things are about equally busy. A long branch name is shortened
  from the prefixes first: `experiment/quant-welfare/phase-1` shows as
  `expe/quan/phase-1`. If it still doesn't fit, it is cut inside the last
  part: `feature/delta-consolidation` shows as `feat/delta-…dation`.
- **`D` in the detailed monitor switches to simple mode and opens the side
  panel.** It used to toggle the side panel without leaving the detailed
  layout, where there is no side panel. The change couldn't be seen, and
  the panel was off the next time simple mode came up. `R` (reminders due
  soon) likewise does nothing in simple mode, which has no list for it to
  filter. The hint line under the clock lists only the keys that do
  something in the current layout.
- **The side panel's PR lines no longer name the workflow**, only the
  running or queued job, leaving more room for the branch. Hover a PR line
  to see the workflow.
- **Renaming a session no longer leaves a copy under its old name.** The
  terminal stays attached through the rename and keeps its activity clock.
  Before, the old name stayed in the session list beside the new one.
- **Shift-Return makes a new line in Claude Code** instead of submitting.
  Onyx now sends Shift-Return as ESC CR (Meta-Return), the sequence
  Claude Code reads as a line break. It passes through tmux unchanged. In
  a zsh prompt it adds a line to the command being edited.
- **⌃⇥ cycles tmux sessions**, whatever ⇧⇥ is set to. With ⇧⇥ given back
  to the terminal (Settings → General → Keyboard), Claude Code's
  permission-mode switch works and you still have a cycling key.
