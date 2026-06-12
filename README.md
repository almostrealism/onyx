# Onyx

**A terminal-first overlay workspace for macOS.** Onyx wraps always-on SSH + tmux sessions in a translucent, keyboard-driven window — then layers on the things you normally juggle across half a dozen apps: a full-screen work monitor, GitHub **and** GitLab PR/pipeline tracking, Apple Reminders, Timing.app stats, a remote file browser with git, built-in notes, browser sessions, and live integration with Claude Code.

It's designed to sit on top of everything, jet-black and barely there, so you can glance at "what's running, what's due, what's merging" without breaking flow — and drop it to near-transparent to see the meeting behind it.

---

## Highlights

### 🔭 Work-monitoring overlay
A full-window heads-up display (toggle with `` ` ``) that pulls your whole working context into one place:

- **System stats** — CPU, memory, and GPU with Activity-Monitor-style grid charts and a multi-week history heatmap; 5-second or 1-minute polling.
- **PR & pipeline tracking** — open pull/merge requests and CI pipeline status from **GitHub and GitLab**, side by side (see below).
- **Apple Reminders** — your lists inline, with a "due today / by tomorrow" scope indicator so you can see how much is on deck at a glance.
- **Timing.app** — weekly hours, a per-day bar chart, a half-year heatmap, and a per-project time-ratio bar.
- **Docker** — live per-container CPU/memory for the containers on the host.
- **Claude Code sessions** — active agent sessions and their pending permission requests, surfaced from the hook integration.
- **SSH connection pool** — health of the warm tmux/mux masters Onyx keeps per host.
- **Session notes** — a one-line "what is this session doing" note (`Cmd+;`) shown right in the overlay.
- **Simple mode** (`S`) — strips down to just giant CPU/GPU charts and compact status pills for ambient, at-a-glance monitoring.
- **Peek** (`X`) — momentarily drops the overlay to near-transparent so you can see the desktop or another app (e.g. a Zoom call) behind it.

### 🔀 PR & pipeline tracking (GitHub + GitLab)
Track what's in flight across both forges, merged into one list:

- **Pull requests / merge requests** — open PRs and MRs from your configured GitHub repos and GitLab projects, each row tagged with a `GH`/`GL` badge and a single mergeable / blocked / conflicts / checks-failing indicator.
- **"Only mine"** — an independent per-provider toggle. Show every PR on small GitHub repos, but filter the busy GitLab project with dozens of MRs down to just yours. Your username is auto-detected from the token.
- **CI pipelines** — explicitly tracked GitHub Actions runs/workflows and GitLab pipelines, with live in-progress / succeeded / failed job counts and an overall status dot.
- **Add from a PR** — the `+` button suggests pipelines from your open PRs' branches, or paste any pipeline URL and Onyx routes it to the right provider automatically.

### 🖥 Always-on remote sessions
- SSH to one or more hosts (or run locally) with **tmux persistence** and automatic reconnection (exponential backoff).
- **Multiple sessions** discovered at launch — `Shift+Tab` to cycle, `+` to create, `Cmd+1–9` for favorites.
- **Docker container sessions** — drop into a container's tmux, or stream its `docker logs -f`.
- **Browser sessions** — open a WKWebView "session" alongside your terminals with a URL bar (`Cmd+L`).
- **Guided SSH key setup** when key auth fails.

### 🗂 Tools on the side
- **Remote file browser** (`Cmd+O`) — browse and view files over SSH with git status, fuzzy search, and file preview.
- **Built-in notes** (`Cmd+E`) — local Markdown/text notes, searchable, without leaving the terminal.
- **Artifacts panel** (`Cmd+D`) — text, Mermaid/PlantUML diagrams, and 3D models pushed in by coding agents over MCP.
- **Command palette** (`Cmd+K`) — fuzzy access to everything.

### ✨ Built for ambient use
- Translucent jet-black glass with **configurable opacity** — the overlay is always at least as see-through as the terminal, and the desktop shows through behind both.
- **Multi-window** — each window is independent, with its own active session and accent.
- **Live browser dashboard** — Onyx serves a self-updating monitoring page over local HTTP.
- Accent themes, custom window titles (handy for time-tracking), and a CPU-fleet screensaver.

---

## Requirements

- macOS 14 (Sonoma) or later
- Swift 5.9+ toolchain (Xcode 15+ or standalone Swift)
- tmux installed on the target machine
- *(optional)* GitHub / GitLab personal access tokens for PR & pipeline tracking; a Timing.app API token for time stats

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
| `` ` `` (backtick) | Toggle the monitor overlay |
| Cmd+K | Command palette |
| Cmd+E / Shift+Cmd+E | Toggle notes / new note |
| Cmd+O / Shift+Cmd+O | File browser panel / full-window file browser |
| Cmd+D | Toggle artifacts panel |
| Cmd+L | Focus the browser URL bar |
| Cmd+; | Set/edit the active session's status note |
| Cmd+J | Toggle session manager |
| Cmd+, | Settings |
| Shift+Tab | Cycle tmux sessions |
| Cmd+1–9 | Switch to favorite session |
| Cmd+R | Refresh / reconnect active session |
| Cmd+\ | Cycle side-panel split ratio |
| Cmd+Ctrl+Arrows | Resize the tmux pane |
| Shift+Cmd+C | Toggle selectable terminal-text mode |
| Escape | Dismiss the top overlay |

**While the monitor overlay is open** (single keys):

| Key | Action |
|-----|--------|
| S | Simple / full monitor layout |
| X | Peek — drop the overlay to near-transparent |
| T | Toggle poll interval (5s / 1m) |
| M | Toggle the memory chart |
| C | Toggle all-containers view |
| P | Toggle 12/24-hour clock |

## PR & Pipeline Tracking — setup

Open **Settings** (`Cmd+,`) and fill in the **GitHub** and/or **GitLab** sections:

- **Token** — a personal access token. GitHub: classic token, `repo` scope. GitLab: `read_api` scope (gitlab.com).
- **Repos / Projects** — one `owner/repo` (GitHub) or `group/project` (GitLab) per line.
- **Only mine** — toggle per provider to filter the PR/MR list to PRs you authored (username is auto-detected).
- **Pipelines** — paste pipeline URLs to track, or use the `+` button in the overlay's PIPELINES section to add one from an open PR's latest run. GitHub workflow/run URLs and GitLab `…/-/pipelines/<id>` URLs are both accepted and routed automatically.

Everything then appears in the monitor overlay (`` ` ``), merged into single OPEN PRs and PIPELINES lists with per-row provider badges.

## Architecture

The project is split into three targets:

- **OnyxLib** — all app logic and views (library, testable)
- **Onyx** — the executable entry point (`@main`)
- **OnyxMCP** — stdio-to-socket bridge for MCP agent integration

Source is organized into strict layers (Models → Services → Stores → Managers → App → Views); see [CLAUDE.md](CLAUDE.md) for the layering rules. A few key managers:

| Area | Type |
|------|------|
| Terminal pool, SSH lifecycle, reconnect | `TerminalSessionManager`, `SSHKeeper` |
| System / Docker / Timing monitoring | `MonitorManager`, `DockerStatsManager`, `TimingManager` |
| PR & pipeline tracking | `PullRequestManager`, `WorkflowMonitor`, `GitLabMergeRequestManager`, `GitLabPipelineMonitor` |
| Files, git, notes, artifacts, browser | `FileBrowserManager`, `GitManager`, `NotesManager`, `ArtifactManager`, `BrowserManager` |
| Claude Code integration | `ClaudeSessionManager` |
| Local servers | `MCPServer`, `DashboardServer` |

## Tests

```bash
swift test
```

569 tests covering monitor output parsing, SSH command generation, config serialization, file-browser parsing and navigation, note management, shell escaping, artifact management, MCP message handling, JSON-RPC encoding, git status parsing, PR/pipeline URL parsing and provider routing (GitHub + GitLab), and right-panel state.

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
- `appearance.json` — font size, opacity, accent color, window title, reminders lists
- `folders.json` — saved remote folder paths for the file browser
- `favorites.json` — favorited session ordering
- `notes/` — local note files (.md, .txt)
- `mcp.sock` — Unix domain socket for local MCP connections

GitHub/GitLab tokens, watched repos/projects, tracked pipelines, the "only mine" toggles, and the Timing.app token are stored in the standard user defaults and configured entirely through **Settings**.

## License

MIT
