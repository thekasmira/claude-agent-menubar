#!/bin/bash
# claude-agent-menubar :: installer
#
# Safe to re-run. Detects an already-working install (this exact source
# folder already registered in ~/.claude/settings.json, or the canonical
# ~/.claude/agent-menubar/ already in place) and treats that as done rather
# than duplicating it. On a clean machine, installs to the canonical
# location: ~/.claude/agent-menubar/.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CANONICAL_DIR="$HOME/.claude/agent-menubar"
SETTINGS="$HOME/.claude/settings.json"
HOOK_EVENTS="SessionStart UserPromptSubmit PreToolUse Stop Notification SubagentStart SubagentStop SessionEnd"

echo "== claude-agent-menubar installer =="

# ---- 0. platform check ------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  echo "This tool only works on macOS (uses SwiftBar + AppleScript). Aborting." >&2
  exit 1
fi

# ---- 1. Homebrew check --------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install it first: https://brew.sh" >&2
  exit 1
fi

# ---- 2. figure out where we're actually installing ----------------------
# Detect an already-registered hook.sh anywhere (last two path segments
# "agent-menubar/hook.sh") -- if found, adopt it instead of installing a
# second copy alongside it.
EXISTING_DIR="$(python3 - "$SETTINGS" <<'PY'
import json, os, sys

path = sys.argv[1]
try:
    with open(path) as fh:
        cfg = json.load(fh)
except Exception:
    sys.exit(0)

hooks = cfg.get("hooks", {})
for groups in hooks.values():
    if not isinstance(groups, list):
        continue
    for group in groups:
        for h in group.get("hooks", []):
            cmd = h.get("command", "")
            parts = cmd.split("/")
            if len(parts) >= 2 and parts[-1] == "hook.sh" and parts[-2] == "agent-menubar":
                d = "/".join(parts[:-1])
                if os.path.isfile(os.path.join(d, "hook.sh")):
                    print(d)
                    sys.exit(0)
PY
)"

if [ -n "$EXISTING_DIR" ]; then
  INSTALL_DIR="$EXISTING_DIR"
  echo "Existing install found at $INSTALL_DIR -- reusing it (not installing a duplicate)."
elif [ "$SCRIPT_DIR" = "$CANONICAL_DIR" ]; then
  INSTALL_DIR="$CANONICAL_DIR"
  echo "Running from the canonical install location ($INSTALL_DIR)."
else
  INSTALL_DIR="$CANONICAL_DIR"
  echo "Installing to $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude='.git' --exclude='.DS_Store' "$SCRIPT_DIR"/ "$INSTALL_DIR"/
  else
    cp -R "$SCRIPT_DIR"/. "$INSTALL_DIR"/
    rm -rf "$INSTALL_DIR/.git"
  fi
fi

chmod +x "$INSTALL_DIR"/*.sh "$INSTALL_DIR"/plugins/*.sh 2>/dev/null

# ---- 3. jq check ---------------------------------------------------------
JQ_BIN=""
if [ -x /usr/bin/jq ]; then
  JQ_BIN=/usr/bin/jq
elif command -v jq >/dev/null 2>&1; then
  JQ_BIN="$(command -v jq)"
else
  echo "jq not found. Installing via Homebrew..."
  brew install jq
  JQ_BIN="$(command -v jq)"
fi
if [ -z "$JQ_BIN" ]; then
  echo "jq is required but could not be found or installed." >&2
  exit 1
fi
echo "jq: $JQ_BIN"

# ---- 4. SwiftBar check ----------------------------------------------------
if [ -d "/Applications/SwiftBar.app" ]; then
  echo "SwiftBar: already installed."
else
  echo "SwiftBar not found. Installing via Homebrew cask..."
  brew install --cask swiftbar
fi

# ---- 5. SwiftBar plugin directory -----------------------------------------
# Never hijack an existing SwiftBar setup: only set the preference if it's
# unset. If it's already pointed somewhere else, put our plugin there instead.
PLUGIN_SRC="$INSTALL_DIR/plugins/claude-agents.5s.sh"
CURRENT_PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
CURRENT_PLUGIN_DIR="${CURRENT_PLUGIN_DIR%/}"
TARGET_PLUGIN_DIR="$INSTALL_DIR/plugins"

if [ -z "$CURRENT_PLUGIN_DIR" ]; then
  echo "Setting SwiftBar PluginDirectory to $TARGET_PLUGIN_DIR"
  defaults write com.ameba.SwiftBar PluginDirectory -string "$TARGET_PLUGIN_DIR"
elif [ "$CURRENT_PLUGIN_DIR" = "$TARGET_PLUGIN_DIR" ]; then
  echo "SwiftBar PluginDirectory already points at $TARGET_PLUGIN_DIR."
else
  echo "SwiftBar already has a PluginDirectory ($CURRENT_PLUGIN_DIR) -- linking the plugin there instead of changing it."
  mkdir -p "$CURRENT_PLUGIN_DIR"
  ln -sf "$PLUGIN_SRC" "$CURRENT_PLUGIN_DIR/claude-agents.5s.sh"
fi

# ---- 6. merge hooks into ~/.claude/settings.json ---------------------------
HOOK_PATH="$INSTALL_DIR/hook.sh"
BACKUP="$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"

MERGE_RESULT="$(python3 - "$SETTINGS" "$HOOK_PATH" "$BACKUP" $HOOK_EVENTS <<'PY'
import json, os, sys

settings_path, hook_path, backup_path = sys.argv[1:4]
events = sys.argv[4:]

if os.path.exists(settings_path):
    with open(settings_path) as fh:
        original_text = fh.read()
    try:
        cfg = json.loads(original_text)
    except Exception as exc:
        print("ERROR: %s is not valid JSON (%s) -- not touching it." % (settings_path, exc))
        sys.exit(1)
else:
    original_text = None
    cfg = {}

hooks = cfg.setdefault("hooks", {})
changed = False

for ev in events:
    groups = hooks.setdefault(ev, [])
    already = any(
        h.get("command") == hook_path
        for g in groups
        for h in g.get("hooks", [])
    )
    if already:
        continue
    groups.append({"hooks": [{"type": "command", "command": hook_path, "timeout": 5}]})
    changed = True

if not changed:
    print("NOCHANGE")
    sys.exit(0)

new_text = json.dumps(cfg, indent=2) + "\n"

if original_text is not None:
    os.makedirs(os.path.dirname(backup_path), exist_ok=True)
    with open(backup_path, "w") as fh:
        fh.write(original_text)

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as fh:
    fh.write(new_text)

print("CHANGED")
PY
)"

case "$MERGE_RESULT" in
  NOCHANGE)
    echo "Hooks already registered in $SETTINGS -- no change."
    ;;
  CHANGED)
    echo "Hooks merged into $SETTINGS (backup: $BACKUP)"
    ;;
  ERROR:*)
    echo "$MERGE_RESULT" >&2
    exit 1
    ;;
  *)
    echo "Unexpected output while merging hooks:" >&2
    echo "$MERGE_RESULT" >&2
    exit 1
    ;;
esac

# ---- 7. launch SwiftBar ----------------------------------------------------
open -a SwiftBar

# ---- 8. summary -------------------------------------------------------------
echo ""
echo "== done =="
echo "Installed to:        $INSTALL_DIR"
echo "Hook script:         $HOOK_PATH"
echo "SwiftBar plugin dir: ${CURRENT_PLUGIN_DIR:-$TARGET_PLUGIN_DIR}"
echo ""
echo "First click on a session in the menu bar will prompt macOS for"
echo "Automation permission (System Settings > Privacy & Security > Automation)"
echo "-- approve it once per terminal app (Terminal.app / iTerm2)."
echo ""
echo "Claude Code re-reads settings.json while running, so sessions already"
echo "open usually pick up the hooks on their next event -- but a session"
echo "that never fires another event won't appear until it restarts."
