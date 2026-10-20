# Onyx 0.20

Draft — still being assembled.

## Finding what Onyx can do

- **What's New.** After an update, Onyx shows a card once listing what
  arrived since you last looked, with "Show me" for the features it can put
  on screen. It's in the Help menu and the command palette afterwards. New
  installs get the tour instead.
- **Tips where features live.** A one-line NEW tip appears where a new
  feature is used: in the file browser ("⌘V pastes files copied in
  Finder"), on an open file, in the monitor's agenda pane, and in the
  status bar under the terminal. Each place shows one tip at a time. A tip
  goes away for good once you use the feature or close it, in every
  window.
- **More of the command palette finds features by what they do:** today's
  calendar in the monitor, the file browser as a tree, cycling the side
  panel's width, What's New and the walkthrough.

## Side panel

- **The divider shows it can be dragged.** It has a grip, lights up under
  the pointer, and says what it does when hovered. Double-click resets
  the panel to its default width.
- **Each window remembers its panel width** across launches, on this Mac.
  ⌘\ still steps through preset widths, and the window remembers those
  too.

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
- **⌃⇥ cycles tmux sessions**, and **⇧⇥ now goes to the terminal by
  default**, so Claude Code's permission-mode switch works out of the box.
  This applies to existing installs too — if you want ⇧⇥ to cycle
  sessions again, turn it back on in Settings → General → Keyboard.
- **Paste files into the file browser.** Copy files or folders in Finder
  with ⌘C, click into the file browser, and press ⌘V. They upload to the
  folder being shown, the same as dropping them there. ⌘V with text on
  the clipboard works as it always has.
- **The monitor's agenda pane can show today's calendar instead of
  Reminders.** Press `A` with the monitor up, or click CALENDAR in the
  pane's header. That's the reminders column in the detailed layout, and
  the list in simple mode's side panel. In simple mode, `A` also opens the
  side panel. The detailed layout shows the whole day, with past events
  dimmed and the current event highlighted. Simple mode shows only what's
  left of the day. Onyx asks for calendar access the first time you switch
  to the calendar, not at launch.
- **Edit files from the file browser.** Open a text file and click Edit.
  It opens in a full-window editor; ⌘S saves it back to the host. Esc
  closes, and asks first if there are unsaved changes. Before saving, Onyx
  checks whether the file changed on the host since you opened it. If it
  did, you choose: overwrite it, or reload and lose your edits. A save
  writes into the existing file, so it keeps its permissions and
  ownership, and a symlink stays a symlink. The new bytes are on the
  host's disk before the file is touched. Line endings and every other
  byte you didn't edit are kept exactly. Files over 2 MB, or that aren't
  UTF-8 text, open read-only with an explanation.
- **The file browser can show a folder as a tree.** Click the tree button
  in its toolbar. Folders open in place when clicked, and each folder's
  contents are fetched the first time you open it. Files open as usual.
  "Open as folder" in a folder's right-click menu makes it the folder
  shown. The choice is remembered.
- **Download from the file viewer gets the right file** when the file was
  opened from search. It used to look for a file of that name in the
  folder being shown.
