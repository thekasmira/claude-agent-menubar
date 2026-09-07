#!/bin/bash
# claude-agent-menubar :: uninstaller
#
# Removes the hook entries, the SwiftBar plugin file/symlink, and the status
# directory. Leaves SwiftBar itself installed (prints how to remove it too)
# and leaves the installed folder (hook.sh, focus-tab.sh, etc.) in place --
# delete it yourself once you're sure you're done with it.

set -u

SETTINGS="$HOME/.claude/settings.json"
STATUS_DIR="${CLAUDE_AGENT_STATUS_DIR:-$HOME/.claude/agent-status}"

echo "== claude-agent-menubar uninstaller =="

# ---- 1. remove hook entries (any path ending in agent-menubar/hook.sh) ----
if [ -f "$SETTINGS" ]; then
  BACKUP="$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
  RESULT="$(python3 - "$SETTINGS" "$BACKUP" <<'PY'
import json, os, sys

settings_path, backup_path = sys.argv[1:3]

with open(settings_path) as fh:
    original_text = fh.read()
try:
    cfg = json.loads(original_text)
except Exception as exc:
    print("ERROR: %s is not valid JSON (%s) -- not touching it." % (settings_path, exc))
    sys.exit(1)

def is_ours(cmd):
    parts = str(cmd).split("/")
    return len(parts) >= 2 and parts[-1] == "hook.sh" and parts[-2] == "agent-menubar"

hooks = cfg.get("hooks", {})
changed = False
for ev in list(hooks.keys()):
    groups = hooks[ev]
    if not isinstance(groups, list):
        continue
    kept = []
    for g in groups:
        hs = g.get("hooks", [])
        remaining = [h for h in hs if not is_ours(h.get("command"))]
        if len(remaining) != len(hs):
            changed = True
        if remaining:
            g = dict(g)
            g["hooks"] = remaining
            kept.append(g)
        elif not hs:
            kept.append(g)
    if kept:
        hooks[ev] = kept
    else:
        del hooks[ev]
        changed = True

if not changed:
    print("NOCHANGE")
    sys.exit(0)

if not hooks:
    cfg.pop("hooks", None)

with open(backup_path, "w") as fh:
    fh.write(original_text)
with open(settings_path, "w") as fh:
    fh.write(json.dumps(cfg, indent=2) + "\n")

print("CHANGED")
PY
)"
  case "$RESULT" in
    NOCHANGE) echo "No agent-menubar hook entries found in $SETTINGS." ;;
    CHANGED)  echo "Hook entries removed from $SETTINGS (backup: $BACKUP)" ;;
    ERROR:*)  echo "$RESULT" >&2 ;;
    *)        echo "$RESULT" >&2 ;;
  esac
else
  echo "$SETTINGS not found -- nothing to remove there."
fi

# ---- 2. remove the plugin file/symlink from SwiftBar's plugin directory ---
PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [ -n "$PLUGIN_DIR" ] && [ -e "$PLUGIN_DIR/claude-agents.5s.sh" ]; then
  rm -f "$PLUGIN_DIR/claude-agents.5s.sh"
  echo "Removed $PLUGIN_DIR/claude-agents.5s.sh"
else
  echo "No claude-agents.5s.sh found in SwiftBar's plugin directory."
fi

# ---- 3. drop the state directory ------------------------------------------
if [ -d "$STATUS_DIR" ]; then
  rm -rf "$STATUS_DIR"
  echo "Removed $STATUS_DIR"
else
  echo "$STATUS_DIR not present."
fi

# ---- 4. leave SwiftBar installed --------------------------------------------
echo ""
echo "SwiftBar itself was left installed. To remove it too:"
echo "  osascript -e 'quit app \"SwiftBar\"'"
echo "  brew uninstall --cask swiftbar"
echo "  defaults delete com.ameba.SwiftBar PluginDirectory"
echo ""
echo "The installed folder (hook.sh, focus-tab.sh, install.sh, plugins/) was"
echo "left in place -- delete it by hand if you don't need it anymore."
