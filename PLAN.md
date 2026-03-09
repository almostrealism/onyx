# Onyx — Build Plan

## Phase 1: Foundation [DONE]

1. Swift Package with SwiftTerm dependency
2. Translucent, borderless dark window with vibrancy
3. SwiftTerm terminal view rendering full-bleed
4. App lifecycle (Cmd+Q, Cmd+W, window dragging)
5. Proper GUI activation policy for bare executables

## Phase 2: SSH + tmux [DONE]

1. First-launch config screen: hostname, user, tmux session name
2. Config persisted to `~/Library/Application Support/Onyx/config.json`
3. Spawns `ssh -t user@host "exec $SHELL -lc 'tmux new-session -A -s <name>'"`
4. Auto-reconnect on disconnect with exponential backoff (0.5s → 15s cap)
5. "Reconnecting..." overlay indicator

## Phase 3: Notes [DONE]

1. Notes as Markdown files in `~/Library/Application Support/Onyx/notes/`
2. List view (left) + editor (right), keyboard-navigable
3. Cmd+Shift+N toggle, Escape to dismiss
4. Create (Cmd+N), delete (context menu), search/filter
5. Auto-save on edit

## Phase 4: Polish [DONE]

1. Cmd+K command palette with fuzzy search
2. Settings panel (Cmd+,): font size, window opacity, accent color, SSH config
3. Smooth animations for all panel transitions (asymmetric moves, opacity, scale)
4. Connection status pill (bottom-right) with green/red indicator
5. Escape key dismisses topmost overlay in stack order
6. Dynamic accent color (6 presets, persisted)
7. Appearance config persisted separately

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Cmd+Shift+N` | Toggle notes panel |
| `Cmd+N` | New note (in notes panel) |
| `Cmd+K` | Command palette |
| `Cmd+,` | Settings |
| `Escape` | Dismiss topmost overlay / return to terminal |
| `Cmd+W` | Close window |
| `Cmd+Q` | Quit |
