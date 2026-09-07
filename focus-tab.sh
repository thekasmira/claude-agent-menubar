#!/bin/bash
# claude-agent-menubar :: focus the terminal tab attached to a given tty
#
# Usage: focus-tab.sh ttys004 [terminal]      (or /dev/ttys004)
#
#   <tty>       required. "ttys004" or "/dev/ttys004".
#   [terminal]  optional. The hosting terminal app's $TERM_PROGRAM value, as
#               recorded by hook.sh (Apple_Terminal, iTerm.app, vscode, ...).
#               Defaults to Apple_Terminal so old records / manual calls with
#               only a tty keep working exactly as before.
#
# Requires macOS Automation permission: the FIRST invocation from a given
# parent app (SwiftBar, Terminal, ...) raises a "wants to control <app>"
# prompt that must be approved once, per target app.

set -u

arg="${1:-}"
term="${2:-Apple_Terminal}"
if [ -z "$arg" ]; then
  echo "usage: $(basename "$0") <tty> [terminal]   e.g. ttys004 or /dev/ttys004" >&2
  exit 64
fi

# accept both "ttys004" and "/dev/ttys004"
case "$arg" in
  /dev/*) target="$arg" ;;
  *)      target="/dev/$arg" ;;
esac

notify_not_found() {
  local msg="$1"
  echo "$msg" >&2
  # SwiftBar runs actions with terminal=false, so stderr is invisible --
  # surface it where the user will actually see it.
  osascript -e "display notification \"$msg\" with title \"Claude Agents\"" >/dev/null 2>&1
}

notify_failure() {
  local rc="$1" out="$2"
  echo "osascript failed (rc=$rc): $out" >&2
  osascript -e "display notification \"Could not talk to the terminal app. Grant Automation permission in System Settings > Privacy & Security > Automation.\" with title \"Claude Agents\"" >/dev/null 2>&1
}

case "$term" in
  Apple_Terminal|"")
    result="$(osascript 2>&1 <<APPLESCRIPT
on run
  set target to "$target"
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        try
          if (tty of t) is target then
            set selected of t to true
            set index of w to 1
            set frontmost of w to true
            activate
            return "ok"
          end if
        end try
      end repeat
    end repeat
  end tell
  return "notfound"
end run
APPLESCRIPT
    )"
    rc=$?
    ;;

  iTerm.app|iTerm2)
    result="$(osascript 2>&1 <<APPLESCRIPT
on run
  set target to "$target"
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with sess in sessions of t
          try
            if (tty of sess) is target then
              select sess
              select t
              select w
              activate
              return "ok"
            end if
          end try
        end repeat
      end repeat
    end repeat
  end tell
  return "notfound"
end run
APPLESCRIPT
    )"
    rc=$?
    ;;

  *)
    notify_not_found "Click-to-focus isn't supported for $term. Only Terminal.app and iTerm2 can be focused (tty $target)."
    exit 1
    ;;
esac

case "$result" in
  ok)
    echo "focused $target"
    exit 0
    ;;
  notfound)
    notify_not_found "No $term tab is attached to $target (session may have exited or lives in another terminal app)."
    exit 1
    ;;
  *)
    notify_failure "$rc" "$result"
    exit 1
    ;;
esac
