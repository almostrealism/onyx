# Onyx

A terminal-first overlay editor for macOS. Onyx wraps SSH + tmux in a translucent, keyboard-driven interface with built-in notes, a system monitor, and a remote file browser.

## Features

- **Always-on terminal** — connects via SSH to a remote host (or runs locally) with tmux session persistence and automatic reconnection with exponential backoff
- **Multiple tmux sessions** — discovers all sessions on the target machine at launch; Shift+Tab to cycle, + to create new ones
- **Docker container sessions** — discovers running containers and their tmux sessions; includes a live log stream (`docker logs -f`) per container
- **Translucent overlay** — jet-black glass window with configurable opacity; desktop shows through behind the terminal
- **Split layout** — terminal on the left, side panels (notes, file browser, artifacts) on the right
- **Built-in notes** — Markdown/text notes stored locally, searchable, accessible without leaving the terminal
- **System monitor** — CPU, memory, and GPU stats with Activity Monitor-style grid charts; polls every 5 seconds in the background
- **Remote file browser** — browse and view files on the remote host via SSH, with git repository status
- **MCP agent integration** — coding agents running in remote sessions can display artifacts (text, diagrams, 3D models) via the built-in MCP server
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
| Cmd+D | Toggle artifacts panel |
| Cmd+, | Settings |
| Shift+Tab | Cycle tmux sessions |
| Cmd+1–9 | Switch to favorite session |
| Cmd+R | Refresh/reconnect session |
| Cmd+J | Toggle session manager |
| `` ` `` (backtick) | Toggle system monitor |
| T | Toggle monitor interval (5s / 1m) |
| Escape | Dismiss top overlay |

## Architecture

The project is split into three targets:

- **OnyxLib** — all app logic and views (library, testable)
- **Onyx** — the executable entry point (`@main`)
- **OnyxMCP** — stdio-to-socket bridge for MCP agent integration

Key source files:

| File | Purpose |
|------|---------|
| `AppState.swift` | Central state, config persistence, SSH command building |
| `TerminalHostView.swift` | SwiftTerm integration, SSH probing, tmux session management |
| `ContentView.swift` | Root view, split layout, notification wiring |
| `MonitorView.swift` | Background stats polling, parsing, grid chart rendering |
| `FileBrowserView.swift` | Remote directory listing and file viewing via SSH |
| `GitStatusView.swift` | Git repository status for file browser landing page |
| `ArtifactModels.swift` | Artifact data models and slot manager |
| `ArtifactView.swift` | Artifact display (text, Mermaid diagrams, 3D models) |
| `MCPServer.swift` | MCP JSON-RPC server (Unix socket + TCP) |
| `NotesView.swift` | Local notes manager with search and editor |
| `KeyboardShortcuts.swift` | Global keyboard shortcut handler |
| `CommandPalette.swift` | Fuzzy-filtered command list |
| `SettingsView.swift` | SSH config and appearance settings |

## Tests

```bash
swift test
```

145 tests covering monitor output parsing, SSH command generation, config serialization, file browser parsing, note management, shell escaping, artifact management, MCP message handling, JSON-RPC encoding, git status parsing, and right panel state.

## MCP Agent Integration

Onyx includes a built-in MCP (Model Context Protocol) server that lets coding agents display artifacts to the user. This works transparently over SSH — agents running in remote tmux sessions can communicate back to Onyx on the local Mac.

### How it works

1. Onyx starts a TCP listener on `127.0.0.1` (dynamic port) and a Unix socket at `~/Library/Application Support/Onyx/mcp.sock`
2. SSH connections automatically include `-R 19432:127.0.0.1:<local_port>` to forward a port back through the tunnel
3. The `ONYX_MCP_PORT` environment variable is exported into the remote tmux session
4. The `OnyxMCP` bridge reads this variable and connects via the forwarded port

### Setup on the remote host

Build and install OnyxMCP on the remote machine, then configure your MCP client:

```json
{
  "mcpServers": {
    "onyx": {
      "command": "/path/to/OnyxMCP"
    }
  }
}
```

### Available tools

| Tool | Description |
|------|-------------|
| `show_text` | Display text/markdown in a slot (0–7) |
| `show_diagram` | Render Mermaid/PlantUML diagram in a slot |
| `show_model` | Display a 3D model (OBJ/USDZ/STL) in a slot |
| `clear_slot` | Clear a specific artifact slot |
| `list_slots` | List all occupied slots |

View artifacts with **Cmd+D**.

## Configuration

All data is stored in `~/Library/Application Support/Onyx/`:

- `hosts.json` — multi-host SSH connection settings
- `appearance.json` — font size, opacity, accent color, window title
- `folders.json` — saved remote folder paths for the file browser
- `favorites.json` — favorited session ordering
- `notes/` — local note files (.md, .txt)
- `mcp.sock` — Unix domain socket for local MCP connections

## License

MIT
