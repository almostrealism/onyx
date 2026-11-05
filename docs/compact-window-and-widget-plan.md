# The compact window and the session widget

Two ways to keep sessions in view while doing something else:

1. **The compact window** (⇧⌘D) — built. The whole window becomes simple
   mode's side panel and shrinks to sit at the side of the screen.
2. **A macOS widget** — planned here, not built. Session status on the
   desktop or in Notification Center, with Onyx's window closed or hidden.
   It doesn't include reminders or the calendar, which have their own
   widgets.

## 1. The compact window

### What it is

⇧⌘D, the command palette's "Compact Window", or the expand button in its
corner switches a window between its **full** shape and its **compact**
one. Compact shows exactly what the simple monitor's left column shows:

- the session list (noted and matched sessions, with their Claude activity);
- unmatched Claude sessions;
- today's reminders or calendar (`A` switches, as in the monitor);
- open PRs that have CI to show.

It uses the monitor's tint. The terminal stays connected underneath and
hidden, as it is under the monitor. D was chosen because D is the side
panel's own key in the monitor.

### Each shape has its own frame

Each window remembers two frames, per window like `PanelSplit`:

- the last frame it had **full**;
- the last frame it had **compact**.

Switching saves the frame being left and applies the one being entered. A
move or a manual resize also saves the frame of the current shape, so a
window that was moved while compact goes back where it was left.

The first time a window goes compact, it keeps the full window's right
edge and height, and its width is the side panel's column plus gutters.
It doesn't jump across the screen.

A remembered frame on a display that has since gone is moved onto the
window's current screen (`WindowModeFrames.fitted`). Frames are kept on
this Mac only: a frame that suits one set of screens is wrong on another.

Whether a window was compact is also remembered. A relaunch comes back
compact, and `AppState.init` reads the flag before any view sees the
state, so restoring it isn't mistaken for a switch.

The window's minimum size depends on the shape. It is 600×400 for full
(room for a terminal) and 240×240 for compact. That is why the minimum
moved from `OnyxApp` into `ContentView`. The new frame is set one turn of
the run loop after the switch, because SwiftUI only lowers the minimum
once it has re-rendered. It is set without animation, given what
animated AppKit resizes have done to us (CLAUDE.md, NSPopover).

### Behavior while compact

- **Clicking a session goes to it.** The window comes back full size with
  that session in front. `jumpToSession` clears `compactMode`, and the
  frame swap follows from the change.
- **Keys don't reach the hidden terminal.** A window can sit compact for
  hours, so typing must not land in a shell nobody can see. Bare and
  shifted keys are swallowed. `A` toggles the agenda pane. ⌘ and ⌃ chords
  work as usual.
- **Scrolling is the column's.** The terminal's mouse-wheel forwarding
  stands down, as it does for the monitor.
- **Not from full screen.** There is no window shape to change there.
- The favorites bar is hidden.

### Files

- `Sources/OnyxCore/Services/WindowModeFrames.swift`: frame and flag
  storage, the first compact frame, and fitting a frame onto a screen.
  Pure apart from UserDefaults. Tested in `WindowModeFramesTests`.
- `Sources/OnyxLib/App/CompactWindow.swift`: the AppKit half (save,
  choose, `setFrame`, and restore at launch).
- `Sources/OnyxLib/Views/CompactWindowView.swift`: the view.
- `AppState.compactMode`, which feeds `terminalIsCovered`, and
  `jumpToSession`.
- `ContentView`: the minimum size, the swap when `compactMode` changes,
  and saving the frame on move and resize.
- `KeyboardShortcuts`: ⇧⌘D, and the key guard while compact.

## 2. The session widget (planned)

### What it shows

Sessions only, the same rows as the compact window's SESSIONS:

- favorites first, then the rest by last activity;
- each row has its title, its note or its Claude line ("running Bash",
  "waiting for you"), and an idle dot.

The time since each session was last active uses
`Text(date, style: .relative)`. WidgetKit keeps that ticking with no
reloads, so the clock stays right between updates. Sizes:

- **small:** a count ("3 sessions · 1 waiting for you") and the session
  that most needs you;
- **medium:** four rows;
- **large:** eight or nine rows.

Clicking a row opens Onyx on that session. That needs `widgetURL`/`Link`
with an `onyx://session/<id>` URL, which means registering the scheme in
the app's Info.plist and handling it in `AppDelegate` with
`jumpToSession`. The same URL would let a notification or the menu bar
deep-link too.

### How the data gets there

A widget is a separate, **sandboxed** extension process. It can't see the
app's state or run ssh. The app publishes a small snapshot and the widget
renders it:

1. The app writes `sessions-widget.json` (≈1KB) into a shared App Group
   container. The data is the rows above plus a generated-at time. The
   writes are debounced, and the app writes only when a row's content
   changes. The relative clocks don't need writes.
2. After a write, the app calls
   `WidgetCenter.shared.reloadTimelines(ofKind:)`.
3. The widget's timeline provider reads the file and returns one entry.
   When the file's generated-at time is old, the widget says so
   ("as of 14:02 — Onyx isn't running") rather than showing stale status
   as live.

WidgetKit limits how often an app may reload a widget: roughly a few
dozen times a day, more while the app is in front. So the widget is near
live, not live. Session titles and notes change rarely. The Claude
activity line changes often, so it is the thing to rate-limit: at most
one reload a minute, plus one immediately when a Claude starts waiting
for permission.

### What it takes to build

This is the costly part. None of it can be done in the SPM build alone.

- **An Xcode target.** A widget is an app extension (`.appex`), and SPM
  can't build one. Add a macOS WidgetKit extension target, either in a
  new `Apps/OnyxWidget` project or as a macOS target beside the iOS app in
  `Apps/OnyxToday`. It would link `OnyxCore` for the row model, so the
  widget and the app can't disagree about what a row is.
- **Packaging.** `package.sh` builds the extension with xcodebuild, copies
  it into `Onyx.app/Contents/PlugIns/`, and signs it first (inside out)
  with its own sandbox and App Group entitlements. Notarization then
  covers it with the app.
- **An App Group.** Both the app and the extension need the
  `com.apple.security.application-groups` entitlement with a
  Team-ID-prefixed group (`<TEAMID>.ai.almostrealism.onyx`, after the app's bundle id). That form
  works for Developer ID distribution without a provisioning profile.
  The `group.ai.almostrealism.onyx` form also works, and is the one an iOS
  app can share, but on macOS 15 and later it needs a provisioning profile
  embedded in the Mac app. Bundle ids never carry the team prefix; app
  groups and keychain groups do.
  The app itself stays unsandboxed; only the extension must be sandboxed.
- **Signed builds only.** macOS registers a widget only from a signed app
  in an Applications folder. `swift run` and `./run.sh` will never show
  it, so the widget is tested from a `./package.sh --sign` build. This
  machine has no signing identity, so that has to happen on the user's
  Mac.
- **iPhone, later.** The iOS app already has an Xcode project, so a
  matching iOS widget could reuse the extension's views. Its data would
  come from the home host, the way Today's does, rather than from a Mac.

### Decisions needed before building

1. **Where the extension lives:** a new `Apps/OnyxWidget` project, or a
   macOS target in `Apps/OnyxToday`. Recommended: a new project. The iOS
   project's settings are tuned for the phone, and a Mac-only extension
   beside them complicates both.
2. **The App Group name.** It's permanent once shipped: changing it
   strands every installed widget's data.
3. **Whether clicking a row should open the session** (the `onyx://` URL
   scheme). Recommended: yes. It's what makes the widget a shortcut and
   not just a picture.
