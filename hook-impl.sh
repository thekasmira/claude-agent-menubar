#!/bin/bash
# claude-agent-menubar :: status hook (implementation; launched by hook.sh)
#
# Invoked by Claude Code for SessionStart, UserPromptSubmit, PreToolUse, Stop,
# Notification, SubagentStart, SubagentStop and SessionEnd.
# Reads the hook JSON payload on stdin and maintains one status record per
# session at $STATUS_DIR/<session_id>.json.
#
# Two things are tracked independently and combined into the displayed state:
#   main   -> what the top-level agent loop is doing (idle/working/done/needs_input),
#             moved ONLY by events from the main context (no agent_id in payload)
#   agents -> the set of live subagents keyed by agent_id (SubagentStart adds,
#             SubagentStop removes, any event carrying an agent_id self-heals)
# state = needs_input > subagents (any live agent) > main. The old single state
# machine marked a session ✅ the moment the main loop ended its turn, even with
# background subagents still running, and let a subagent's tool calls (and cwd!)
# masquerade as the main loop's.
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

# ---- raw event log ---------------------------------------------------------
# One line per hook event (key fields only). Rotates at ~512KB so it stays a
# bounded debugging aid. Set CLAUDE_AGENT_STATUS_LOG=0 to disable.
if [ "${CLAUDE_AGENT_STATUS_LOG:-1}" != "0" ]; then
  mkdir -p "$STATUS_DIR" 2>/dev/null
  log="$STATUS_DIR/events.log"
  if [ -f "$log" ] && [ "$(stat -f%z "$log" 2>/dev/null || echo 0)" -gt 524288 ]; then
    mv -f "$log" "$log.1" 2>/dev/null
  fi
  printf '%s %s\n' "$(date +%s)" "$(printf '%s' "$payload" | "$JQ" -c \
    '{session_id,hook_event_name,agent_id,agent_type,tool_name,notification_type,stop_hook_active,cwd}
     | with_entries(select(.value != null))' 2>/dev/null)" >> "$log" 2>/dev/null
fi

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
  | ($o.main // $o.state // "idle") as $pm
  | ($p.agent_id // "" | tostring) as $aid
  | ($aid != "") as $sub_ctx
  # only a real dialog counts as "waiting on you"; idle_prompt after Stop just
  # means the session is sitting at "done", and informational types are noise
  | (($ntype | IN("permission_prompt","elicitation_dialog")) | not) as $quiet
  # ---- main-loop state machine ------------------------------------------
  # Events that carry an agent_id come from inside a subagent and must not
  # move the main loop. Stop is only ever emitted for the main agent
  # (subagents emit SubagentStop), so it always means "main loop ended turn".
  | (if   $ev == "SessionStart"                                then "idle"
     elif $ev == "UserPromptSubmit"                            then "working"
     elif $ev == "PreToolUse" then
            (if $sub_ctx then (if $pm == "needs_input" then "done" else $pm end)
             else "working" end)
     elif $ev == "Stop"                                        then "done"
     elif $ev == "Notification" then (if $quiet then $pm else "needs_input" end)
     else $pm end) as $main
  # ---- live subagent set, keyed by agent_id -----------------------------
  | (($o.agents // {}) | if type == "object" then . else {} end) as $ag0
  | (if $ev == "SubagentStart" and $sub_ctx then
        $ag0 + {($aid): {type: ($p.agent_type // "" | tostring), since: $t, seen: $t}}
     elif $ev == "SubagentStop" then
        (if $sub_ctx then ($ag0 | del(.[$aid]))
         # no id on the stop (older CLI): drop the oldest one we know about
         elif ($ag0 | length) > 0 then
           ($ag0 | del(.[($ag0 | to_entries | min_by(.value.since) | .key)]))
         else $ag0 end)
     elif $sub_ctx then
        # self-heal: a subagent we never saw start is still a live subagent
        $ag0 + {($aid): (($ag0[$aid] // {type: ($p.agent_type // "" | tostring), since: $t}) + {seen: $t})}
     else $ag0 end
     # a subagent silent for an hour is one whose Stop we missed
     | with_entries(select((.value.seen // 0) > ($t - 3600)))) as $agents
  | ($agents | length) as $nsub
  # ---- displayed state ---------------------------------------------------
  | (if   $main == "needs_input" then "needs_input"
     elif $nsub > 0               then "subagents"
     else $main end) as $st
  # only the cwd of the main context names the session (subagents may run elsewhere)
  | ((if $sub_ctx then ($o.cwd // "") else ($p.cwd // $o.cwd // "") end)
     | sub("(?<x>.)/+$"; "\(.x)")) as $cwd
  | $o + {
      session_id:  $sid,
      pid:         (if $pid != "" then ($pid | tonumber) else ($o.pid // 0) end),
      tty:         (if $tty != "" then $tty else ($o.tty // "") end),
      terminal:    (if $term != "" then $term else ($o.terminal // "") end),
      cwd:         $cwd,
      project:     (($cwd | split("/") | last) as $b
                    | if ($b // "") == "" then "/" else $b end),
      state:       $st,
      main:        $main,
      state_since: (if $st == $prev and ($o.state_since != null)
                    then $o.state_since else $t end),
      last_event:  (if $sub_ctx then "\($ev) (\($p.agent_type // "subagent"))" else $ev end),
      started_at:  ($o.started_at // $t),
      agents:      $agents,
      subagents:   $nsub,
      updated_at:  $t
    }
  | if $ev == "Notification" and ($quiet | not)
    then . + {message: ($p.message // ""), notification_type: $ntype}
    else . end
  # a stale prompt string outliving the prompt is worse than none
  | if .state != "needs_input" then del(.message, .notification_type) else . end
' > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null

exit 0
