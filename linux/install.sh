#!/usr/bin/env bash
# Relaunch Claude — Linux installer (Ubuntu / GNOME, KDE, XFCE…)
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/relaunch-claude"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"

command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 1; }

mkdir -p "$DEST"
install -m 755 "$SRC/relaunch_claude.py" "$DEST/relaunch_claude.py"
install -m 644 "$SRC/../assets/icon.svg" "$DEST/icon.svg"
install -m 644 "$SRC/../assets/icon.png" "$DEST/icon.png"

# 1. Register the hook in Claude Code settings (merged, idempotent, backed up).
mkdir -p "$CLAUDE_DIR"
[ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak-relaunch-claude"
python3 - "$SETTINGS" "python3 \"$DEST/relaunch_claude.py\" hook" <<'PY'
import json, sys, pathlib
path, cmd = pathlib.Path(sys.argv[1]), sys.argv[2]
cfg = json.loads(path.read_text()) if path.exists() and path.read_text().strip() else {}
hooks = cfg.setdefault("hooks", {})
for event in ("SessionStart", "SessionEnd"):
    groups = hooks.setdefault(event, [])
    present = any("relaunch_claude.py" in h.get("command", "")
                  for g in groups for h in g.get("hooks", []))
    if not present:
        groups.append({"hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
path.write_text(json.dumps(cfg, indent=2) + "\n")
PY

# 2. `reclaude` terminal command.
BIN="$HOME/.local/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\nexec python3 "%s/relaunch_claude.py" "$@"\n' "$DEST" > "$BIN/reclaude"
chmod +x "$BIN/reclaude"

# 3. Desktop launcher: application menu + desktop icon.
DESKTOP_FILE="[Desktop Entry]
Type=Application
Name=Relaunch Claude
Comment=Reopen and resume every interrupted Claude Code session
Exec=python3 \"$DEST/relaunch_claude.py\"
Icon=$DEST/icon.svg
Terminal=false
Categories=Development;Utility;
StartupNotify=false"

APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$APPS"
printf '%s\n' "$DESKTOP_FILE" > "$APPS/relaunch-claude.desktop"

DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
if [ -d "$DESKTOP_DIR" ]; then
  printf '%s\n' "$DESKTOP_FILE" > "$DESKTOP_DIR/relaunch-claude.desktop"
  chmod +x "$DESKTOP_DIR/relaunch-claude.desktop"
  # GNOME only launches desktop files marked as trusted.
  gio set "$DESKTOP_DIR/relaunch-claude.desktop" metadata::trusted true 2>/dev/null || true
fi

# Optional: relaunch automatically at login.
if [ "${1:-}" = "--autostart" ]; then
  mkdir -p "$HOME/.config/autostart"
  printf '%s\nX-GNOME-Autostart-Delay=10\n' "$DESKTOP_FILE" > "$HOME/.config/autostart/relaunch-claude.desktop"
  echo "Autostart enabled."
fi

echo "Relaunch Claude installed."
echo "  - Sessions started from now on are tracked (already open ones: restart them once)."
echo "  - After a reboot, click the \"Relaunch Claude\" icon, or run: reclaude"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "  - $BIN is not in your PATH yet: open a new terminal (or log out/in) before using reclaude." ;; esac
