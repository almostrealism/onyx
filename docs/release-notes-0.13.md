# Onyx 0.13

## Code search & file browser
- **File-type filter** for search (Java, Python, JS/TS, Swift, Go, Rust, …),
  set in Settings → SEARCH FILTER. Narrows results and dims non-matching files.
- **Cmd+Shift+F** jumps straight to file search, focused on your last favorite
  and ready to type — or searches the text you've selected in a viewed file.
- Search now finds **deeply-nested files** (removed a depth cap that hid e.g.
  Java classes under `src/main/java/...`).
- File viewer switched to an AppKit text view so selections are searchable
  (syntax highlighting preserved).
- Fixes: git changed-files now detected at a repo root even through symlinks;
  "back" from a search result returns to the results; only the narrowest
  matching saved folder is highlighted.

## Terminal
- The **Cmd+Shift+C** text overlay now recognizes file paths as clickable links
  (click → open the file, ⇧-click → its folder).
- macOS smart-quote / smart-dash auto-substitution is disabled everywhere, so
  typed `"` stays straight in notes and all editors.

## Monitor overlay
- **Session idle indicators**: each session note shows how long since its
  terminal last produced output (green = active → grey = idle), so a finished
  test run stands out. Detection is content-based (no more 60-second resets)
  and survives SSH reconnects.
- Tapping a session in the overlay now actually switches to it.
- **Simple mode** gains: reminder due-today / by-tomorrow counts, session
  activity pills, and GitLab pipelines in the status strip; pipeline pills
  triage to the most relevant count; bigger pills and a fixed timing-tile clip.

## Help & polish
- **Cmd+/** opens a help / keyboard-shortcut reference; a `?` button in the
  bottom bar surfaces it, and the command palette is now a complete list.
- The "add pipeline" suggestions popover grows to fit (up to 8).
- `install.sh` warns if tmux is missing; README refreshed.
