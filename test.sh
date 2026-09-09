#!/bin/bash
# claude-agent-menubar :: regression test
#
# Self-contained: points CLAUDE_AGENT_STATUS_DIR at a throwaway temp dir,
# pipes synthetic Claude Code hook payloads through ./hook.sh, and asserts
# the resulting status record with jq after each step. Never touches
# ~/.claude/agent-status or a real session. Safe to run anytime.
#
# Usage: ./test.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/hook.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL: %s\n' "$1"
  shift
  for line in "$@"; do
    printf '      %s\n' "$line"
  done
}

assert_eq() {
  # assert_eq <description> <actual> <expected>
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "expected [$3] got [$2]"
  fi
}

check_bash_syntax() {
  local desc="$1" file="$2" out
  out="$(bash -n "$file" 2>&1)"
  if [ $? -eq 0 ]; then
    pass "$desc"
  else
    fail "$desc" "$out"
  fi
}

check_py_compile() {
  local desc="$1" file="$2" out
  out="$(python3 -m py_compile "$file" 2>&1)"
  if [ $? -eq 0 ]; then
    pass "$desc"
  else
    fail "$desc" "$out"
  fi
}

# ============================================================================
# Static checks
# ============================================================================
check_bash_syntax "bash -n hook.sh" "$SCRIPT_DIR/hook.sh"
check_bash_syntax "bash -n hook-impl.sh" "$SCRIPT_DIR/hook-impl.sh"
check_py_compile "python3 -m py_compile plugins/claude-agents.5s.sh" "$SCRIPT_DIR/plugins/claude-agents.5s.sh"

# ============================================================================
# Hook state-machine scenario
# ============================================================================
TMP_STATUS_DIR="$(mktemp -d)"
BROKEN_DIR=""
cleanup() {
  rm -rf "$TMP_STATUS_DIR" 2>/dev/null
  [ -n "$BROKEN_DIR" ] && rm -rf "$BROKEN_DIR" 2>/dev/null
}
trap cleanup EXIT

export CLAUDE_AGENT_STATUS_DIR="$TMP_STATUS_DIR"

SID="11111111-1111-1111-1111-111111111111"
CWD="/tmp/agent-menubar-test-proj"
REC="$TMP_STATUS_DIR/$SID.json"

send() {
  # send <json-payload> -- pipes it through hook.sh, returns hook.sh's exit code
  printf '%s' "$1" | "$HOOK"
  return $?
}

field() {
  # field <jq filter> -- reads the current record
  jq -r "$1" "$REC" 2>/dev/null
}

# ---- SessionStart -> idle --------------------------------------------------
send '{"session_id":"'"$SID"'","hook_event_name":"SessionStart","cwd":"'"$CWD"'"}'
rc=$?
assert_eq "hook.sh always exits 0 (normal payload)" "$rc" "0"
assert_eq "SessionStart -> state idle" "$(field .state)" "idle"
assert_eq "SessionStart -> main idle" "$(field .main)" "idle"

# ---- UserPromptSubmit -> working -------------------------------------------
send '{"session_id":"'"$SID"'","hook_event_name":"UserPromptSubmit","cwd":"'"$CWD"'"}'
assert_eq "UserPromptSubmit -> state working" "$(field .state)" "working"
assert_eq "UserPromptSubmit -> main working" "$(field .main)" "working"

# ---- SubagentStart -> subagents --------------------------------------------
send '{"session_id":"'"$SID"'","hook_event_name":"SubagentStart","agent_id":"agentA","agent_type":"general-purpose","cwd":"'"$CWD"'"}'
assert_eq "SubagentStart -> state subagents" "$(field .state)" "subagents"
assert_eq "SubagentStart -> main left alone (still working)" "$(field .main)" "working"
assert_eq "SubagentStart -> subagents count 1" "$(field .subagents)" "1"
assert_eq "SubagentStart -> agentA recorded with its type" "$(field '.agents.agentA.type')" "general-purpose"

# ---- Stop with a live agent -> state subagents / main done ----------------
send '{"session_id":"'"$SID"'","hook_event_name":"Stop","cwd":"'"$CWD"'"}'
assert_eq "Stop w/ live agent -> state stays subagents" "$(field .state)" "subagents"
assert_eq "Stop w/ live agent -> main becomes done" "$(field .main)" "done"

# ---- PreToolUse with agent_id for an unseen agent --------------------------
# self-heals the agent into `agents`, but must not touch cwd/project.
send '{"session_id":"'"$SID"'","hook_event_name":"PreToolUse","agent_id":"agentB","agent_type":"code-reviewer","tool_name":"Bash","cwd":"/tmp/should-not-apply"}'
assert_eq "PreToolUse unseen agent -> self-healed into agents" "$(field '.agents.agentB.type')" "code-reviewer"
assert_eq "PreToolUse unseen agent -> subagents count 2" "$(field .subagents)" "2"
assert_eq "PreToolUse unseen agent -> cwd NOT overwritten by subagent cwd" "$(field .cwd)" "$CWD"
assert_eq "PreToolUse unseen agent -> project NOT overwritten" "$(field .project)" "$(basename "$CWD")"

# ---- SubagentStop with an unknown id -> no change --------------------------
send '{"session_id":"'"$SID"'","hook_event_name":"SubagentStop","agent_id":"unknown-agent-id","cwd":"'"$CWD"'"}'
assert_eq "SubagentStop unknown id -> subagents count unchanged" "$(field .subagents)" "2"
assert_eq "SubagentStop unknown id -> agentA still present" "$(field '.agents | has("agentA")')" "true"
assert_eq "SubagentStop unknown id -> agentB still present" "$(field '.agents | has("agentB")')" "true"

# ---- SubagentStop for known ids -> removes them ----------------------------
send '{"session_id":"'"$SID"'","hook_event_name":"SubagentStop","agent_id":"agentA","cwd":"'"$CWD"'"}'
assert_eq "SubagentStop known id (agentA) -> removed" "$(field '.agents | has("agentA")')" "false"
assert_eq "SubagentStop known id (agentA) -> subagents count 1" "$(field .subagents)" "1"
assert_eq "SubagentStop known id (agentA) -> state still subagents (agentB live)" "$(field .state)" "subagents"

# last live agent goes, main is already "done" -> state should become done
send '{"session_id":"'"$SID"'","hook_event_name":"SubagentStop","agent_id":"agentB","cwd":"'"$CWD"'"}'
assert_eq "SubagentStop last agent (agentB) -> subagents count 0" "$(field .subagents)" "0"
assert_eq "SubagentStop last agent, main==done -> state becomes done" "$(field .state)" "done"

# ---- SubagentStop with no agent_id -> removes the oldest -------------------
send '{"session_id":"'"$SID"'","hook_event_name":"SubagentStart","agent_id":"agentC","agent_type":"typeC","cwd":"'"$CWD"'"}'
sleep 1.1
send '{"session_id":"'"$SID"'","hook_event_name":"SubagentStart","agent_id":"agentD","agent_type":"typeD","cwd":"'"$CWD"'"}'
assert_eq "setup: two agents live before oldest-removal test" "$(field .subagents)" "2"
send '{"session_id":"'"$SID"'","hook_event_name":"SubagentStop","cwd":"'"$CWD"'"}'
assert_eq "SubagentStop no agent_id -> removes the oldest (agentC)" "$(field '.agents | has("agentC")')" "false"
assert_eq "SubagentStop no agent_id -> keeps the newer one (agentD)" "$(field '.agents | has("agentD")')" "true"
assert_eq "SubagentStop no agent_id -> subagents count 1" "$(field .subagents)" "1"

# ---- Notification permission_prompt -> needs_input -------------------------
MSG="Claude needs your permission to run: rm -rf /"
send '{"session_id":"'"$SID"'","hook_event_name":"Notification","notification_type":"permission_prompt","message":"'"$MSG"'","cwd":"'"$CWD"'"}'
assert_eq "Notification permission_prompt -> state needs_input" "$(field .state)" "needs_input"
assert_eq "Notification permission_prompt -> main needs_input" "$(field .main)" "needs_input"
assert_eq "Notification permission_prompt -> message stored" "$(field .message)" "$MSG"

# ---- Notification idle_prompt -> no change ---------------------------------
send '{"session_id":"'"$SID"'","hook_event_name":"Notification","notification_type":"idle_prompt","cwd":"'"$CWD"'"}'
assert_eq "Notification idle_prompt -> state unchanged (needs_input)" "$(field .state)" "needs_input"
assert_eq "Notification idle_prompt -> main unchanged (needs_input)" "$(field .main)" "needs_input"
assert_eq "Notification idle_prompt -> earlier prompt message preserved" "$(field .message)" "$MSG"
assert_eq "Notification idle_prompt -> notification_type not overwritten" "$(field .notification_type)" "permission_prompt"

# ============================================================================
# Launcher safety: a broken hook-impl.sh must still exit 0
# ============================================================================
BROKEN_DIR="$(mktemp -d)"
cp "$SCRIPT_DIR/hook.sh" "$BROKEN_DIR/hook.sh"
cat > "$BROKEN_DIR/hook-impl.sh" <<'EOF'
#!/bin/bash
fi   # deliberately invalid syntax -- bash exits 2 on this
EOF
chmod +x "$BROKEN_DIR/hook.sh" "$BROKEN_DIR/hook-impl.sh"
printf '%s' '{"session_id":"'"$SID"'","hook_event_name":"SessionStart"}' | "$BROKEN_DIR/hook.sh"
rc=$?
assert_eq "broken hook-impl.sh -> launcher still exits 0" "$rc" "0"

# ============================================================================
# Summary
# ============================================================================
echo "----------------------------------------"
echo "$PASS_COUNT passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
