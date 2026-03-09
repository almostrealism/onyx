# Onyx — A Terminal-First Overlay Editor for macOS

## Vision

Onyx is a minimal, visually stunning macOS app that acts as a persistent SSH terminal with built-in note-taking. It is jet-black and translucent, designed to float over other applications as a glass-like overlay. No mouse required.

## Core Properties

### 1. Always-Connected SSH Terminal (Primary Interface)

- On first launch, Onyx prompts for an SSH hostname (and optionally user/port/key).
- From then on, opening Onyx drops you straight into a terminal session connected to that remote host.
- Connection details are persisted in `~/Library/Application Support/Onyx/config.json`.
- The terminal emulator renders inside the app using a high-performance GPU-accelerated view.

### 2. Persistent Sessions via tmux

- Onyx automatically creates or reattaches to a named tmux session on the remote host.
- The tmux session name is configurable (default: `onyx`).
- On any connection drop, Onyx reconnects SSH and reattaches to the same tmux session silently — the user sees a brief "Reconnecting…" indicator and then is right back where they were.
- Reconnection is automatic with exponential backoff (0.5s, 1s, 2s, 4s… capped at 15s).

### 3. Built-in Notes (Secondary Interface)

- Toggle notes overlay with a keyboard shortcut (`Cmd+Shift+N`).
- Notes are stored in `~/Library/Application Support/Onyx/notes/` as plain-text/Markdown files.
- Simple list of notes on the left, editor on the right — all keyboard-navigable.
- Create, rename, delete, search notes without touching the file system or a mouse.
- Notes panel slides over the terminal; terminal keeps running underneath.

### 4. Visual Design — Jet-Black Translucent Overlay

- Window has no traditional title bar — uses a custom toolbar region with traffic lights.
- Background is near-black (`#0A0A0A`) with 80–85% opacity, achieving a dark glass effect.
- Vibrancy material: `.hudWindow` or `.dark` for behind-window blurring.
- Monospace font throughout (SF Mono or Menlo, user-configurable).
- Accent color: a single subtle highlight — cool white or ice-blue (`#66CCFF`).
- The window supports standard macOS window management (drag, resize, minimize, Cmd+W).
- Future: full-screen overlay mode.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Cmd+Shift+N` | Toggle notes panel |
| `Cmd+N` | New note (when notes panel is open) |
| `Cmd+K` | Quick search / command palette |
| `Cmd+,` | Settings |
| `Escape` | Close notes panel / return to terminal |
| `Cmd+W` | Close window |
| `Cmd+Q` | Quit |

## Technical Stack

- **Language:** Swift
- **UI Framework:** SwiftUI + AppKit (for window customization and vibrancy)
- **Terminal Emulation:** SwiftTerm (open-source terminal emulator library for Swift)
- **SSH:** libssh2 via NMSSH, or shelling out to the system `ssh` binary for simplicity in v1
- **Storage:** File-based (`~/Library/Application Support/Onyx/`)
- **Build:** Xcode project, Swift Package Manager for dependencies
- **Target:** macOS 14+ (Sonoma)

## Non-Goals (v1)

- Multiple simultaneous SSH connections
- Full IDE features (syntax highlighting of files, LSP, etc.)
- iOS/iPadOS support
- Plugin system
