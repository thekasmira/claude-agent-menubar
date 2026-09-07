# claude-agent-menubar

A macOS menu bar indicator for every Claude Code session running on your
Mac. It shows what each session is doing right now, and clicking one
focuses its terminal tab.

```
🟢2 🔴1                          <- menu bar
├── 🔴 my-api             needs_input  3m
│     ~/dev/my-api
│     tty /dev/ttys001 · pid 62324
│     Claude needs your permission to run: git push origin test
│     up 1h30m · last event: Notification
├── 🟢 Refactor auth middleware  working  48s
│     ~/dev/website
│     3 subagents running
└── ✅ agent-menubar      done         2h02m
```

## The four marks

| Mark | Meaning |
|---|---|
| 🟢 | **working** — Claude is actively doing something |
| ✅ | **done / waiting on you** — Claude finished and there's nothing blocking it |
| 🔴 | **needs input** — a real permission prompt or question dialog is blocking the session |
| ⚪ | **idle** — session opened, nothing asked of it yet |

## Install

1. Get the code:
   ```bash
   git clone https://github.com/thekasmira/claude-agent-menubar.git agent-menubar
   # or: unzip claude-agent-menubar.zip
   cd agent-menubar
   ```
2. Run the installer:
   ```bash
   ./install.sh
   ```

`install.sh` is safe to re-run. It will:

* check you're on macOS with Homebrew installed
* install SwiftBar (`brew install --cask swiftbar`) if it isn't already
* check for `jq` and install it via Homebrew if missing
* copy this folder to `~/.claude/agent-menubar/` (its permanent home — skipped
  if you're already running it from there, or if it detects hooks already
  registered elsewhere on this machine)
* point SwiftBar at the bundled plugin — either by setting SwiftBar's plugin
  directory (only if none is set yet) or by linking the plugin into your
  existing SwiftBar plugin directory, so it never hijacks a setup you already
  have
* merge the required hooks into `~/.claude/settings.json`, backing it up
  first (skipped if they're already there — running it twice never creates
  duplicate entries)
* launch SwiftBar

After it finishes, restart any Claude Code sessions that were already open
(or just keep working — Claude Code re-reads `settings.json` while running,
so most sessions pick the hooks up on their next event without a restart).

### Automation permission

The **first** time you click a session in the menu, macOS will show an
"agent-menubar wants to control Terminal" (or iTerm) prompt. Approve it —
that permission is what lets `focus-tab.sh` find and raise the right tab.
You'll see this prompt once per terminal app.

### Supported terminals for click-to-focus

| Terminal | Click-to-focus |
|---|---|
| Terminal.app | ✅ |
| iTerm2 | ✅ |
| VS Code integrated terminal, Ghostty, tmux, SSH sessions, etc. | Shows up in the list and is tracked normally, but clicking it shows a "not found" notification — these apps don't expose an AppleScript tab/tty API the same way. |

## Uninstall

```bash
./uninstall.sh
```

This removes the hook entries from `~/.claude/settings.json` (backing it up
first), removes the plugin file/symlink from SwiftBar's plugin directory, and
deletes `~/.claude/agent-status/`. It leaves SwiftBar itself installed and
prints the commands to remove it too, and leaves the installed folder
(`~/.claude/agent-menubar/`) in place for you to delete by hand.

## How it works

Three pieces, no daemon and no database:

1. **`hook.sh`** — registered on eight Claude Code hook events in
   `~/.claude/settings.json`. Every event writes/updates one small JSON record at
   `~/.claude/agent-status/<session_id>.json`. Because a hook runs as a child of
   the `claude` process, it can walk up its own ancestor chain to find that
   process and record its **pid**, **tty**, and hosting **terminal app** — what's
   needed to prove the session is alive and to find its tab later. (`tty` on the
   hook's own stdin is useless: stdin is a pipe.)
2. **`plugins/claude-agents.5s.sh`** — a SwiftBar plugin that re-reads those
   records every 5 seconds and renders the menu.
3. **`focus-tab.sh <tty> [terminal]`** — AppleScript that walks the hosting
   terminal app's windows and tabs, finds the tab whose `tty` matches, selects
   it, and raises the window. Dispatches to a Terminal.app or iTerm2 script
   depending on the recorded terminal app.

Records are the only shared state, so nothing needs to be restarted or kept in
sync. A record is created by whichever event fires first and deleted on
`SessionEnd`; anything the plugin finds pointing at a dead process is deleted on
the next refresh.

### Session names

Each session's label is picked with this precedence: a custom name you set
with `/rename` in that session, otherwise Claude Code's auto-generated
conversation title (read from the session's transcript), otherwise the
project folder name. The submenu always shows the full cwd underneath,
regardless of which one is used for the label.

## State model

| State | Icon | Set by | Meaning |
|---|---|---|---|
| `idle` | ⚪ | `SessionStart` | Session opened, nothing asked of it yet |
| `working` | 🟢 | `UserPromptSubmit`, `PreToolUse` | Claude is actively doing something |
| `done` | ✅ | `Stop` | Claude finished and is waiting on you |
| `needs_input` | 🔴 | `Notification` | Permission prompt / elicitation dialog — **you are blocking it** |
| *(deleted)* | — | `SessionEnd` | Record removed |

`SubagentStart` / `SubagentStop` only increment and decrement a `subagents`
counter; they deliberately leave `state` alone, so a session running five
subagents still reads as `working` rather than flapping.

Two details worth knowing:

* **`state_since` only moves when the state actually changes.** Ten `PreToolUse`
  events in a row keep one "working since" timestamp, so the elapsed time in the
  menu answers "how long has it been like this", not "how long since the last
  event".
* **Informational notifications don't fake a prompt.** `auth_success`,
  `agent_completed` and the `quota_auto_resume_*` types leave the state and any
  pending prompt text untouched — otherwise a background auth refresh would
  clear the real permission prompt you still need to answer.

### Record shape

```json
{
  "session_id": "6781f9fd-…", "pid": 57421, "tty": "ttys004",
  "terminal": "Apple_Terminal",
  "cwd": "/Users/you/dev/agent-menubar", "project": "agent-menubar",
  "state": "working", "state_since": 1788813153, "last_event": "PreToolUse",
  "started_at": 1788813153, "subagents": 0, "updated_at": 1788813180,
  "message": "…", "notification_type": "permission_prompt"
}
```

`terminal` comes from the hosting terminal's `$TERM_PROGRAM` and is only as
reliable as that environment variable (Apple_Terminal, iTerm.app, vscode,
ghostty, ...). `message` / `notification_type` are present only while `state`
is `needs_input`.

## Menu items

* **Click a session** → focuses its tab (Terminal.app / iTerm2 only, see above).
* **Submenu** (hover a session) → cwd, tty/pid, subagent count when > 0, the
  pending prompt text when blocked, uptime and last event.
* **Open status folder** → opens `~/.claude/agent-status`.
* **Clear stale** → forces a prune of dead and unparseable records.

## Known limits

* **Sessions that were already running may not appear until they restart.**
  Claude Code re-reads `settings.json` while running, so in practice sessions
  often pick the hooks up immediately — but a session that never fires another
  event won't register until it does.
* **Only Terminal.app and iTerm2 support click-to-focus.** Sessions in VS
  Code, Ghostty, tmux or over SSH still appear in the list (state tracking is
  terminal-agnostic) but clicking them reports that no matching tab was
  found. tmux is the awkward case: the tty recorded is the pane's, which
  neither app has ever heard of.
* **🔴 `needs_input` only means a real dialog.** Only `permission_prompt` and
  `elicitation_dialog` notifications turn a session red. `idle_prompt` (Claude
  finished and you haven't typed for a while) leaves it at ✅ `done`, so under
  `--dangerously-skip-permissions` you will rarely see red at all.
* **Subagent counts can drift.** Parallel subagents finishing at the same
  instant can race on the read-modify-write of one record and lose a decrement.
  The counter is clamped at zero and resets on the next `SessionStart`; it's a
  hint, not an invariant.
* **Non-local sessions are invisible.** Only sessions on this Mac writing to
  this home directory are tracked.
* **Menu bar counts, not identities.** Two sessions in the same directory look
  identical in the dropdown apart from their tty.

## Files

| Path | Role |
|---|---|
| `hook.sh` | Writes session state records (bash + jq, ~20 ms, always exits 0) |
| `plugins/claude-agents.5s.sh` | SwiftBar plugin, refreshes every 5 s |
| `focus-tab.sh` | Focuses the terminal tab for a given tty (Terminal.app / iTerm2) |
| `install.sh` | Idempotent installer |
| `uninstall.sh` | Removes hooks, plugin link, and status directory |
| `~/.claude/agent-status/*.json` | One record per live session |

## License

MIT — see [LICENSE](LICENSE).

---

Built by Kasmira Stockton.
