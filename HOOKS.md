# Onyx + Claude Code Integration

Onyx can track Claude Code sessions running on remote hosts, showing real-time tool usage on the monitoring overlay and letting you approve/deny permissions graphically.

## How It Works

```
Remote host                           Local machine
-----------                           -------------
Claude Code                           Onyx app
  |                                      |
  | (hook fires)                         |
  v                                      |
OnyxMCP --hook                           |
  |                                      |
  | (JSON-RPC via SSH port forward)      |
  +------------------------------------->|
  |                                      | Monitor overlay shows:
  |                                      |   - Active sessions
  |                                      |   - Current tools
  |                                      |   - Permission requests
  |<-------------------------------------+
  |  (allow/deny response)               |
  v                                      |
Claude Code continues
```

The connection uses the same SSH port forward (`ONYX_MCP_PORT`) that Onyx already establishes for MCP artifact support. No extra ports or services needed.

## Quick Setup

### Option 1: Automatic (recommended)

From your local machine where the Onyx repo is checked out:

```bash
# Set up a remote host in one command
./setup-remote.sh user@hostname

# Or with a custom SSH port
./setup-remote.sh -p 2222 user@hostname
```

This will:
1. Build the OnyxMCP binary for the remote architecture
2. Copy it to the remote host (`~/.onyx/bin/OnyxMCP`)
3. Configure Claude Code hooks on the remote host (`~/.claude/settings.json`)

### Option 2: Manual

#### Step 1: Install OnyxMCP on the remote host

Copy the pre-built binary:
```bash
# Build locally (macOS)
swift build --product OnyxMCP

# Copy to remote host
scp .build/debug/OnyxMCP user@hostname:~/.onyx/bin/OnyxMCP
ssh user@hostname 'chmod +x ~/.onyx/bin/OnyxMCP'
```

If the remote host runs Linux, build a Linux binary first:
```bash
# Using Docker (from macOS):
./build-linux-mcp.sh          # builds for linux/amd64
./build-linux-mcp.sh arm64    # builds for linux/arm64
# Output: .build/linux/OnyxMCP

# Or build directly on the Linux host:
swift build --product OnyxMCP -c release
cp .build/release/OnyxMCP ~/.onyx/bin/
```

#### Step 2: Configure Claude Code hooks

On the remote host, run:
```bash
~/.onyx/bin/OnyxMCP --setup-hooks
```

Or run the setup script if you have the repo:
```bash
./setup-hooks.sh ~/.onyx/bin/OnyxMCP
```

Or manually add to `~/.claude/settings.json`:
```json
{
  "hooks": {
    "PreToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "~/.onyx/bin/OnyxMCP --hook PreToolUse", "timeout": 10}]}],
    "PostToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "~/.onyx/bin/OnyxMCP --hook PostToolUse", "timeout": 5}]}],
    "PermissionRequest": [{"matcher": "", "hooks": [{"type": "command", "command": "~/.onyx/bin/OnyxMCP --hook PermissionRequest", "timeout": 120}]}],
    "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "~/.onyx/bin/OnyxMCP --hook SessionStart", "timeout": 5}]}],
    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "~/.onyx/bin/OnyxMCP --hook Stop", "timeout": 5}]}]
  }
}
```

**Important:** Each hook command includes the event name as an argument (e.g. `--hook PreToolUse`) so OnyxMCP can tag the JSON-RPC payload. Without this, the desktop can't route events to the correct handler.

### Option 3: Local only

If you run Claude Code locally (not via SSH), just run:
```bash
./install-mcp.sh
./setup-hooks.sh
```

## Verifying the Setup

1. Open Onyx and connect to the remote host via SSH
2. Start a Claude Code session in the terminal
3. Open the monitoring overlay (backtick key)
4. You should see a "CLAUDE SESSIONS" section appear when Claude starts working

If the section doesn't appear:
- Check that `ONYX_MCP_PORT` is set: `echo $ONYX_MCP_PORT` (should show `19432`)
- Check that OnyxMCP can connect: `echo '{}' | ~/.onyx/bin/OnyxMCP --hook` (should exit silently)
- Check that hooks are configured: `cat ~/.claude/settings.json | grep OnyxMCP`

## What Each Hook Does

| Hook | Purpose | Blocking? |
|------|---------|-----------|
| **SessionStart** | Registers the session in Onyx monitor | No (async) |
| **PreToolUse** | Shows which tool is being used (Bash, Edit, etc.) | No (10s timeout) |
| **PostToolUse** | Clears the tool status after completion | No (async) |
| **PermissionRequest** | Shows Allow/Deny buttons in Onyx monitor | Yes (120s, falls back to normal prompt) |
| **Stop** | Marks the session as stopped | No (async) |

## Permission Requests

When Claude Code needs permission (e.g., to run a shell command or edit a file), the request appears in the Onyx monitoring overlay with **Allow** and **Deny** buttons. If you don't respond within 120 seconds, it falls through to the normal Claude Code terminal permission prompt.

## Troubleshooting

**"OnyxMCP: Cannot connect to Onyx"**
- Make sure Onyx is running on your local machine
- Check that the SSH session was started from Onyx (not a regular terminal)
- Verify port forwarding: `nc -z 127.0.0.1 19432` on the remote host

**Hooks not firing**
- Restart Claude Code after changing settings.json
- Check `~/.claude/settings.json` is valid JSON: `python3 -m json.tool ~/.claude/settings.json`

**Permission requests timing out**
- Open the monitoring overlay (backtick key) to see and respond to requests
- The 120-second timeout is configurable in settings.json
