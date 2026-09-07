#!/usr/bin/env python3
# <xbar.title>Claude Agents</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>Kasmira</xbar.author>
# <xbar.desc>Shows every running Claude Code session, its state, and focuses its Terminal tab on click.</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
#
# Reads the records written by ~/dev/agent-menubar/hook.sh.
# Run with `--clear` to prune dead/corrupt records without printing a menu.

import json
import os
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
STATUS_DIR = os.environ.get(
    "CLAUDE_AGENT_STATUS_DIR", os.path.join(HOME, ".claude", "agent-status")
)

# Resolve the sibling focus script. SwiftBar resolves symlinks in the plugin
# path, so fall back to the canonical install location.
_here = os.path.dirname(os.path.abspath(os.environ.get("SWIFTBAR_PLUGIN_PATH", __file__)))
FOCUS = os.path.join(os.path.dirname(_here), "focus-tab.sh")
if not os.path.isfile(FOCUS):
    FOCUS = os.path.join(HOME, ".claude", "agent-menubar", "focus-tab.sh")

ICON = {"working": "🟢", "needs_input": "🔴", "done": "✅", "idle": "⚪"}
# needs_input first, then done, then working, then idle
ORDER = {"needs_input": 0, "done": 1, "working": 2, "idle": 3}
# menu-bar count order, per spec: 🟢2 🔴1
TITLE_ORDER = ["working", "needs_input", "done", "idle"]


def live_pids():
    """One `ps` call -> {pid: comm}. Cheaper and more correct than kill(0)
    alone, which can't tell a recycled pid from the original claude."""
    try:
        out = subprocess.run(
            ["/bin/ps", "-Ao", "pid=,comm="],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        return None
    procs = {}
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        pid, _, comm = line.partition(" ")
        try:
            procs[int(pid)] = comm.strip()
        except ValueError:
            pass
    return procs


def is_alive(pid, procs):
    if not pid:
        return False
    if procs is not None:
        comm = procs.get(pid)
        return comm is not None and os.path.basename(comm) == "claude"
    try:                       # fallback if `ps` was unavailable
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return False


def load(prune_only=False):
    """Return live session records; delete records for dead or corrupt ones."""
    procs = live_pids()
    sessions = []
    try:
        names = sorted(os.listdir(STATUS_DIR))
    except FileNotFoundError:
        return []
    for name in names:
        if not name.endswith(".json") or name.endswith(".tmp"):
            continue
        path = os.path.join(STATUS_DIR, name)
        try:
            with open(path) as fh:
                rec = json.load(fh)
            if not isinstance(rec, dict):
                raise ValueError("not an object")
        except Exception:
            if prune_only:
                _unlink(path)
            continue
        if not is_alive(rec.get("pid"), procs):
            _unlink(path)
            continue
        sessions.append(rec)
    return sessions


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def elapsed(since):
    try:
        secs = int(time.time() - float(since))
    except (TypeError, ValueError):
        return "?"
    if secs < 0:
        secs = 0
    if secs < 60:
        return "%ds" % secs
    if secs < 3600:
        return "%dm" % (secs // 60)
    hours, mins = divmod(secs // 60, 60)
    if hours < 24:
        return "%dh%02dm" % (hours, mins)
    days, hours = divmod(hours, 24)
    return "%dd%02dh" % (days, hours)


def clean(text):
    """`|` separates a SwiftBar item's title from its parameters, and a leading
    `--` would make the line a submenu entry. Neither may leak in from a path."""
    text = str(text).replace("|", "│").replace("\n", " ").strip()
    while text.startswith("--"):
        text = text[2:]
    return text or "?"


def tilde(path):
    path = str(path)
    return "~" + path[len(HOME):] if path.startswith(HOME) else path


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--clear":
        load(prune_only=True)
        return

    sessions = load()

    # ---- menu bar title ---------------------------------------------------
    counts = {}
    for s in sessions:
        st = s.get("state", "idle")
        counts[st] = counts.get(st, 0) + 1
    if not sessions:
        print("Claude: none")
    else:
        parts = ["%s%d" % (ICON.get(st, "⚪"), counts[st])
                 for st in TITLE_ORDER if counts.get(st)]
        # any unexpected state still gets counted
        for st in sorted(counts):
            if st not in TITLE_ORDER:
                parts.append("%s%d" % (ICON.get(st, "⚪"), counts[st]))
        print(" ".join(parts))

    print("---")

    if not sessions:
        print("No Claude Code sessions running | color=#888888")
    else:
        sessions.sort(key=lambda s: (ORDER.get(s.get("state", "idle"), 4),
                                     s.get("state_since", 0)))
        for s in sessions:
            state = s.get("state", "idle")
            icon = ICON.get(state, "⚪")
            project = clean(s.get("project") or "?")
            tty = str(s.get("tty") or "")
            line = "%s %s  %s  %s" % (icon, project, state, elapsed(s.get("state_since")))
            params = ["symbolize=false"]
            if tty:
                term_prog = clean(s.get("terminal") or "Apple_Terminal")
                params += ["bash=%s" % FOCUS, "param1=%s" % tty,
                           "param2=%s" % term_prog,
                           "terminal=false", "refresh=false"]
            print("%s | %s" % (line, " ".join(params)))

            # submenu: detail + the things you'd want on a stuck session
            print("--%s | symbolize=false color=#888888" % clean(tilde(s.get("cwd", ""))))
            if tty:
                print("--tty /dev/%s · pid %s | color=#888888" % (clean(tty), s.get("pid", "?")))
            subs = s.get("subagents") or 0
            if subs > 0:
                print("--%d subagent%s running" % (subs, "" if subs == 1 else "s"))
            msg = s.get("message")
            if msg and state == "needs_input":
                print("--%s | symbolize=false length=70" % clean(msg))
            print("--up %s · last event: %s | color=#888888"
                  % (elapsed(s.get("started_at")), clean(s.get("last_event", "?"))))

    print("---")
    print("Open status folder | bash=/usr/bin/open param1=%s terminal=false refresh=false"
          % STATUS_DIR)
    plugin = os.environ.get("SWIFTBAR_PLUGIN_PATH", os.path.abspath(__file__))
    print("Clear stale | bash=%s param1=--clear terminal=false refresh=true" % plugin)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:              # never leave a bare ⚠️ in the menu bar
        print("⚠️ Claude")
        print("---")
        print("plugin error: %s | color=red" % str(exc).replace("|", "/"))
