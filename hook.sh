#!/bin/bash
# claude-agent-menubar :: hook launcher
#
# DO NOT put logic here. This file is the command registered in
# ~/.claude/settings.json; its only job is to run hook-impl.sh and ALWAYS
# exit 0. A hook that exits 2 (which bash does on a syntax error) BLOCKS the
# tool call / stop it was attached to -- in every session on the machine.
# Keeping this launcher trivial means a bad edit to hook-impl.sh degrades the
# menu bar, never Claude Code itself.
impl="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/hook-impl.sh"
[ -f "$impl" ] && /bin/bash "$impl" 2>/dev/null
exit 0
