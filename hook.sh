#!/bin/bash
# claude-agent-menubar :: status hook
#
# Invoked by Claude Code for SessionStart, UserPromptSubmit, PreToolUse, Stop,
# Notification, SubagentStart, SubagentStop and SessionEnd.
# Reads the hook JSON payload on stdin and maintains one status record per
# session at $STATUS_DIR/<session_id>.json.
#
# Design constraints:
#   * must be fast   -> bash + jq (~10ms), no python interpreter start-up
#   * must never fail -> every path ends in `exit 0`
#
# Docs: https://code.claude.com/docs/en/hooks

STATUS_DIR="${CLAUDE_AGENT_STATUS_DIR:-$HOME/.claude/agent-status}"
JQ="${JQ_BIN:-/usr/bin/jq}"
command -v "$JQ" >/dev/null 2>&1 || JQ="$(command -v jq 2>/dev/null)"
[ -n "$JQ" ] || exit 0

payload="$(cat 2>/dev/null)"
[ -n "$payload" ] || exit 0

# ---- extract the three fields we need to route on -------------------------
# One value per line, read with IFS= so that an EMPTY field stays empty.
# (@tsv + `read` is wrong here: TAB is IFS-whitespace, so bash collapses empty
# leading fields and a payload with no session_id would shift into it.)
fields="$(printf '%s' "$payload" | "$JQ" -r \
  '(.session_id // ""), (.hook_event_name // ""), (.notification_type // "")' 2>/dev/null)"
[ -n "$fields" ] || exit 0

sid=""; ev=""; ntype=""
{ IFS= read -r sid; IFS= read -r ev; IFS= read -r ntype; } <<< "$fields"

# Session ids are uuid-shaped. Anything else is malformed or hostile, and this
# value becomes a filename -- so validate rather than sanitise.
case "$sid" in
  ""|*[!A-Za-z0-9_-]*) exit 0 ;;
esac
[ -n "$ev" ] || exit 0

# ---- SessionEnd: drop the record ------------------------------------------
if [ "$ev" = "SessionEnd" ]; then
  rm -f "$STATUS_DIR/$sid.json" 2>/dev/null
  exit 0
fi

# ---- locate the owning `claude` process (pid + tty) -----------------------
# The hook may be exec'd directly by claude or wrapped in a shell, so walk up
# the ancestor chain rather than trusting $PPID blindly. stdin is a pipe, so
# `tty` itself reports "not a tty" -- we must read it off the claude process.
CPID=""
CTTY=""
# TERM_PROGRAM identifies the terminal app hosting this session (Apple_Terminal,
# iTerm.app, vscode, ghostty, ...) -- inherited from the claude process's own
# environment since the hook is a child of it. Used by focus-tab.sh to pick
# the right AppleScript dialect for click-to-focus.
CTERM="${TERM_PROGRAM:-}"
p="$PPID"
i=0
while [ "${p:-0}" -gt 1 ] && [ "$i" -lt 8 ]; do
  # shellcheck disable=SC2046
  set -- $(ps -o ppid=,tty=,comm= -p "$p" 2>/dev/null)
  [ "$#" -ge 3 ] || break
  ppid="$1"; ptty="$2"; pcomm="$3"
  if [ "${pcomm##*/}" = "claude" ]; then
    CPID="$p"
    [ "$ptty" != "??" ] && [ "$ptty" != "-" ] && CTTY="$ptty"
    break
  fi
  p="$ppid"
  i=$((i + 1))
done

now="$(date +%s)"
mkdir -p "$STATUS_DIR" 2>/dev/null
f="$STATUS_DIR/$sid.json"
[ -f "$f" ] || printf '{}\n' > "$f" 2>/dev/null
tmp="$f.$$.tmp"

printf '%s' "$payload" | "$JQ" -c \
  --slurpfile old "$f" \
  --arg sid "$sid" --arg ev "$ev" --arg ntype "$ntype" \
  --arg pid "$CPID" --arg tty "$CTTY" --arg term "$CTERM" --arg now "$now" '
  . as $p
  | ($old[0] // {}) as $o
  | ($now | tonumber) as $t
  | ($o.state // "idle") as $prev
  # only a real dialog counts as "waiting on you"; idle_prompt after Stop just
  # means the session is sitting at "done", and informational types are noise
  | (($ntype | IN("permission_prompt","elicitation_dialog")) | not) as $quiet
  # ---- state machine ----------------------------------------------------
  | (if   $ev == "SessionStart"                                then "idle"
     elif $ev == "UserPromptSubmit" or $ev == "PreToolUse"     then "working"
     elif $ev == "Stop"                                        then "done"
     elif $ev == "Notification" then (if $quiet then $prev else "needs_input" end)
     else $prev end) as $st
  # ---- subagent counter (state deliberately unchanged) ------------------
  | (if   $ev == "SubagentStart" then (($o.subagents // 0) + 1)
     elif $ev == "SubagentStop"  then ((($o.subagents // 0) - 1) | if . < 0 then 0 else . end)
     else ($o.subagents // 0) end) as $sub
  | (($p.cwd // $o.cwd // "") | sub("(?<x>.)/+$"; "\(.x)")) as $cwd
  | $o + {
      session_id:  $sid,
      pid:         (if $pid != "" then ($pid | tonumber) else ($o.pid // 0) end),
      tty:         (if $tty != "" then $tty else ($o.tty // "") end),
      terminal:    (if $term != "" then $term else ($o.terminal // "") end),
      cwd:         $cwd,
      project:     (($cwd | split("/") | last) as $b
                    | if ($b // "") == "" then "/" else $b end),
      state:       $st,
      state_since: (if $st == $prev and ($o.state_since != null)
                    then $o.state_since else $t end),
      last_event:  $ev,
      started_at:  ($o.started_at // $t),
      subagents:   $sub,
      updated_at:  $t
    }
  | if $ev == "Notification" and ($quiet | not)
    then . + {message: ($p.message // ""), notification_type: $ntype}
    else . end
  # a stale prompt string outliving the prompt is worse than none
  | if .state != "needs_input" then del(.message, .notification_type) else . end
' > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null

exit 0
