#!/usr/bin/env bash
# Relaunch Claude — Linux uninstaller
set -euo pipefail

DEST="${XDG_DATA_HOME:-$HOME/.local/share}/relaunch-claude"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"

if [ -f "$SETTINGS" ]; then
  python3 - "$SETTINGS" <<'PY'
import json, sys, pathlib
path = pathlib.Path(sys.argv[1])
cfg = json.loads(path.read_text())
hooks = cfg.get("hooks", {})
for event in ("SessionStart", "SessionEnd"):
    groups = []
    for g in hooks.get(event, []):
        g["hooks"] = [h for h in g.get("hooks", []) if "relaunch_claude.py" not in h.get("command", "")]
        if g["hooks"]:
            groups.append(g)
    if groups:
        hooks[event] = groups
    else:
        hooks.pop(event, None)
path.write_text(json.dumps(cfg, indent=2) + "\n")
PY
fi

DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
rm -f "$HOME/.local/bin/reclaude"
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/relaunch-claude.desktop" \
      "$DESKTOP_DIR/relaunch-claude.desktop" \
      "$HOME/.config/autostart/relaunch-claude.desktop"
rm -rf "$DEST" "$CLAUDE_DIR/relaunch-claude"
echo "Relaunch Claude uninstalled."
