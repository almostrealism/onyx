# Quickstart

Get Onyx running in under a minute.

## 1. Build and run

```bash
swift build && .build/debug/Onyx
```

Or install to Applications:

```bash
./install.sh
```

## 2. First launch

Onyx opens a setup screen. Fill in your connection details:

- **Host** — the remote machine (e.g., `192.168.1.50`), or leave empty / enter `localhost` for local mode
- **User** — your SSH username (leave blank to use current user)
- **Port** — SSH port (default: 22)
- **Tmux Session** — name for your tmux session (default: `onyx`)
- **Identity File** — path to your SSH key (leave blank for default `~/.ssh/id_ed25519`)

Press **Save** to connect.

## 3. SSH key setup

If Onyx can't authenticate with a key, it will offer to install one automatically. Click **Install SSH Key** — you'll type your password once, and from then on it's key-based.

## 4. Using Onyx

You're now in a tmux session on the target machine. Everything you'd do in a normal terminal works here.

### Open the command palette

Press **Cmd+K** to see all available commands with their shortcuts.

### Take notes

Press **Cmd+E** to open the notes panel. Press **Shift+Cmd+E** to create a new note. Notes are saved automatically as you type.

### Monitor system stats

Press **backtick** (`` ` ``) to toggle the monitor overlay. CPU, memory, and GPU stats are collected every 5 seconds in the background — the data is always there when you open it. Press **T** to toggle between 5-second and 1-minute chart intervals.

### Browse remote files

Press **Cmd+O** to open the file browser. Click **+** to add a remote folder path, then navigate into directories and view files.

### Switch tmux sessions

The session bar at the bottom shows all tmux sessions on the target. Click a tab to switch, press **Shift+Tab** to cycle, or click **+** to create a new session.

### Customize appearance

Press **Cmd+,** to open settings. You can change:

- Font size
- Window opacity (how much desktop shows through)
- Accent color (6 presets)
- Window title (useful for time-tracking apps)

## 5. Local mode

Set the host to `localhost`, `127.0.0.1`, or leave it empty. Onyx will skip SSH entirely and run tmux directly on your machine.
