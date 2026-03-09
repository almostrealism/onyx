# Onyx

A terminal-first overlay editor for macOS. Onyx wraps SSH + tmux in a translucent, keyboard-driven interface with built-in notes, a system monitor, and a remote file browser.

## Features

- **Always-on terminal** — connects via SSH to a remote host (or runs locally) with tmux session persistence and automatic reconnection with exponential backoff
- **Multiple tmux sessions** — discovers all sessions on the target machine at launch; Shift+Tab to cycle, + to create new ones
- **Translucent overlay** — jet-black glass window with configurable opacity; desktop shows through behind the terminal
- **Built-in notes** — Markdown/text notes stored locally, searchable, accessible without leaving the terminal
- **System monitor** — CPU, memory, and GPU stats with Activity Monitor-style grid charts; polls every 5 seconds in the background
- **Remote file browser** — browse and view files on the remote host via SSH
- **Command palette** — quick access to all commands via Cmd+K
- **SSH key setup** — automatic detection and guided installation of SSH keys when key auth fails
- **Custom window titles** — rename windows freely (useful for time-tracking integrations)
- **Accent color themes** — six preset accent colors

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.9+ toolchain (Xcode 15+ or standalone Swift)
- tmux installed on the target machine

## Install

```bash
git clone <repo-url> && cd onyx
./install.sh
```

This builds a release binary, bundles it as `Onyx.app`, signs it ad-hoc, and copies it to `/Applications`.

To build and run from source without installing:

```bash
swift build && .build/debug/Onyx
```

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+K | Command palette |
| Cmd+E | Toggle notes |
| Shift+Cmd+E | Create new note |
| Cmd+O | Toggle file browser |
| Cmd+, | Settings |
| Shift+Tab | Cycle tmux sessions |
| `` ` `` (backtick) | Toggle system monitor |
| T | Toggle monitor interval (5s / 1m) |
| Escape | Dismiss top overlay |

## Architecture

The project is split into two targets:

- **OnyxLib** — all app logic and views (library, testable)
- **Onyx** — the executable entry point (`@main`)

Key source files:

| File | Purpose |
|------|---------|
| `AppState.swift` | Central state, config persistence, SSH command building |
| `TerminalHostView.swift` | SwiftTerm integration, SSH probing, tmux session management |
| `ContentView.swift` | Root view, overlay layering, notification wiring |
| `MonitorView.swift` | Background stats polling, parsing, grid chart rendering |
| `FileBrowserView.swift` | Remote directory listing and file viewing via SSH |
| `NotesView.swift` | Local notes manager with search and editor |
| `KeyboardShortcuts.swift` | Global keyboard shortcut handler |
| `CommandPalette.swift` | Fuzzy-filtered command list |
| `SettingsView.swift` | SSH config and appearance settings |

## Tests

```bash
swift test
```

52 tests covering monitor output parsing, SSH command generation, config serialization, file browser parsing, note management, and shell escaping.

## Configuration

All data is stored in `~/Library/Application Support/Onyx/`:

- `config.json` — SSH connection settings
- `appearance.json` — font size, opacity, accent color, window title
- `folders.json` — saved remote folder paths for the file browser
- `notes/` — local note files (.md, .txt)

## License

MIT
