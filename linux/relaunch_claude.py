#!/usr/bin/env python3
"""Relaunch Claude — reopen every Claude Code session that was interrupted
(shutdown, crash, closed terminal) and resume each one where it stopped.

Two roles in one file:
  relaunch_claude.py hook       called by Claude Code (SessionStart / SessionEnd)
  relaunch_claude.py [relaunch] called by the desktop icon
  relaunch_claude.py list       show the registry
"""
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

CLAUDE_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
REGISTRY = CLAUDE_DIR / "relaunch-claude" / "sessions"
CONFIG = CLAUDE_DIR / "relaunch-claude" / "config.json"
STALE_DAYS = 30

# Flags worth carrying over to the resumed session. Everything else (prompt,
# --resume, --continue, --session-id…) is deliberately dropped.
KEEP_BOOL = {"--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
             "--verbose", "--chrome", "--ide"}
KEEP_VALUE = {"--permission-mode", "--model", "--add-dir", "--agent", "--settings",
              "--mcp-config", "--fallback-model", "--effort"}


# ---------------------------------------------------------------- hook side

def claude_ancestor():
    """Walk up from the hook process to the `claude` process that runs it."""
    pid = os.getppid()
    for _ in range(8):
        try:
            argv = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
            argv = [a.decode(errors="replace") for a in argv if a]
            if argv and ("claude" in Path(argv[0]).name
                         or any(Path(a).name in ("claude", "cli.js") for a in argv[:2])):
                return pid, argv
            stat = Path(f"/proc/{pid}/stat").read_text()
            pid = int(stat.rsplit(")", 1)[1].split()[1])
            if pid <= 1:
                break
        except (OSError, ValueError, IndexError):
            break
    return None, []


def carried_flags(argv):
    out, i = [], 1
    while i < len(argv):
        a = argv[i]
        name = a.split("=", 1)[0]
        if name in KEEP_BOOL:
            out.append(a)
        elif name in KEEP_VALUE:
            if "=" in a:
                out.append(a)
            elif i + 1 < len(argv):
                out += [a, argv[i + 1]]
                i += 1
        i += 1
    return out


def hook():
    try:
        data = json.loads(sys.stdin.read() or "{}")
        sid = data.get("session_id")
        if not sid:
            return
        entry = REGISTRY / f"{sid}.json"
        event = data.get("hook_event_name")
        if event == "SessionEnd":
            # "other" is what an interrupted session reports (terminal closed,
            # machine going down). Any explicit exit removes it for good.
            if data.get("reason") != "other":
                entry.unlink(missing_ok=True)
            return
        if event == "SessionStart":
            pid, argv = claude_ancestor()
            REGISTRY.mkdir(parents=True, exist_ok=True)
            tmp = entry.with_suffix(".tmp")
            tmp.write_text(json.dumps({
                "session_id": sid,
                "cwd": data.get("cwd") or os.getcwd(),
                "transcript_path": data.get("transcript_path"),
                "pid": pid,
                "args": carried_flags(argv),
                # The icon runs with a bare desktop PATH (no nvm, no ~/.local/bin):
                # remember where claude lives while we still have the session's PATH.
                "claude_bin": shutil.which("claude"),
                "updated_at": time.time(),
            }, indent=2))
            tmp.replace(entry)
    except Exception:
        pass  # a hook must never get in Claude Code's way


# ------------------------------------------------------------ relaunch side

def load_entries():
    entries = []
    for f in sorted(REGISTRY.glob("*.json")):
        try:
            e = json.loads(f.read_text())
            e["_file"] = f
            entries.append(e)
        except (OSError, ValueError):
            f.unlink(missing_ok=True)
    return entries


def boot_time():
    try:
        for line in Path("/proc/stat").read_text().splitlines():
            if line.startswith("btime "):
                return int(line.split()[1])
    except OSError:
        pass
    return 0


def still_running(e):
    pid = e.get("pid")
    if not pid or e.get("updated_at", 0) < boot_time():
        return False
    try:
        return "claude" in Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace")
    except OSError:
        return False


def find_claude(recorded=None):
    for c in (recorded, shutil.which("claude"), Path.home() / ".local/bin/claude",
              CLAUDE_DIR / "local/claude"):
        if c and Path(c).exists():
            return str(c)
    return "claude"


def shell_command(e, extra):
    claude = find_claude(e.get("claude_bin"))
    transcript = e.get("transcript_path")
    resumable = transcript and Path(transcript).exists()
    cmd = [claude] + (["--resume", e["session_id"]] if resumable else []) + e.get("args", []) + extra
    # A tab opened from inside another Claude session inherits
    # CLAUDE_CODE_CHILD_SESSION, which silently disables transcript writing.
    return ("unset CLAUDE_CODE_CHILD_SESSION; export CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1; "
            f"{shlex.join(cmd)}; exec bash")


def terminal_argv(term, cwd, script):
    inner = ["bash", "-lc", script]
    return {
        "gnome-terminal": ["gnome-terminal", "--tab", f"--working-directory={cwd}", "--"] + inner,
        "ptyxis": ["ptyxis", "--tab", "-d", cwd, "--"] + inner,
        "kgx": ["kgx", "--tab", f"--working-directory={cwd}", "-e", shlex.join(inner)],
        "konsole": ["konsole", "--new-tab", "--workdir", cwd, "-e"] + inner,
        "xfce4-terminal": ["xfce4-terminal", "--tab", f"--working-directory={cwd}", "-x"] + inner,
        "kitty": ["kitty", "--directory", cwd] + inner,
        "alacritty": ["alacritty", "--working-directory", cwd, "-e"] + inner,
        "wezterm": ["wezterm", "start", "--cwd", cwd, "--"] + inner,
        "x-terminal-emulator": ["x-terminal-emulator", "-e"] + inner,
        "xterm": ["xterm", "-e"] + inner,
    }[term]


TERMINALS = ["gnome-terminal", "ptyxis", "konsole", "xfce4-terminal", "kgx", "kitty",
             "alacritty", "wezterm", "x-terminal-emulator", "xterm"]


def pick_terminal(cfg):
    wanted = cfg.get("terminal", "auto")
    if wanted != "auto":
        return wanted
    return next((t for t in TERMINALS if shutil.which(t)), None)


def notify(msg):
    print(msg)
    if shutil.which("notify-send"):
        subprocess.run(["notify-send", "-i", "utilities-terminal", "Relaunch Claude", msg],
                       check=False)


def relaunch(dry_run=False):
    cfg = {}
    if CONFIG.exists():
        try:
            cfg = json.loads(CONFIG.read_text())
        except ValueError:
            pass
    extra = cfg.get("claude_args", [])
    term = pick_terminal(cfg)
    if not term:
        notify("No supported terminal found (set \"terminal\" in " + str(CONFIG) + ").")
        return 1

    done, skipped = 0, []
    for e in load_entries():
        f = e.pop("_file")
        if time.time() - e.get("updated_at", 0) > STALE_DAYS * 86400:
            f.unlink(missing_ok=True)
            continue
        if still_running(e):
            continue
        cwd = e.get("cwd")
        if not cwd or not Path(cwd).is_dir():
            skipped.append(cwd or e["session_id"])
            f.unlink(missing_ok=True)
            continue
        argv = terminal_argv(term, cwd, shell_command(e, extra))
        if dry_run:
            print(shlex.join(argv))
            done += 1
            continue
        try:
            subprocess.Popen(argv, cwd=cwd, start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as err:
            skipped.append(f"{cwd} ({err})")
            continue
        # The resumed session registers itself again on start.
        f.unlink(missing_ok=True)
        done += 1
        time.sleep(0.6)  # let the first window appear so the next ones become tabs

    if dry_run:
        return 0
    msg = f"{done} session(s) relaunched." if done else "No interrupted Claude Code session to relaunch."
    if skipped:
        msg += f" Skipped (folder gone): {', '.join(skipped)}"
    notify(msg)
    return 0


def list_entries():
    for e in load_entries():
        state = "running" if still_running(e) else "interrupted"
        print(f"{state:12} {e['session_id']}  {e.get('cwd')}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "relaunch"
    if cmd == "hook":
        hook()
    elif cmd == "list":
        list_entries()
    elif cmd in ("relaunch", "--dry-run"):
        sys.exit(relaunch(dry_run="--dry-run" in sys.argv))
    else:
        print(__doc__)
        sys.exit(2)
