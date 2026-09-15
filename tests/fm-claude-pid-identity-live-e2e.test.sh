#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the CLAUDE_PID identity signal
# bin/fm-session-lock-lib.sh trusts as a reparented-bg-pty-host fallback (see
# fm_harness_ancestry_pids there and docs/verification/supervision.md "Session
# lock - reparented Claude bg-pty-host").
#
# This is deliberately narrower than tests/fm-claude-stop-autoarm-live-e2e.test.sh:
# it proves only the harness-dependent fact that check depends on - that the
# real installed Claude Code exports a stable, numeric CLAUDE_PID naming the
# true top-level session pid to SessionStart, PreToolUse, and Stop hook
# children alike - without the multi-turn rapid-rewake choreography the other
# suite needs for its own broader continuity claims. That choreography is
# sensitive to model turn-taking and Claude Code version drift in ways
# unrelated to this identity signal, so keeping this proof isolated means a
# real regression here is never masked by, or mistaken for, drift there.
# The project is isolated under a throwaway directory; Claude keeps using its
# existing managed authentication. No live fleet home, worktree, or session is
# touched.
set -u

if [ "${FM_CLAUDE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CLAUDE_LIVE_E2E=1 to run the CLAUDE_PID identity regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v claude >/dev/null 2>&1 || fail "claude not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

LAB="$ROOT/.claude-pid-identity-live-e2e.$$"
CLAUDE_VERSION=$(claude --version)

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB/.claude"
git init -q "$LAB"

# One hook per event type, each recording its own CLAUDE_PID and the delivered
# payload's session_id so the two independent signals can be cross-checked.
cat > "$LAB/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "{ printf '%s\\n' \"${CLAUDE_PID:-}\" > \"$PWD/sessionstart-pid\"; cat | jq -r '.session_id // empty' > \"$PWD/sessionstart-session-id\"; } 2>/dev/null" } ] }
    ],
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "{ printf '%s\\n' \"${CLAUDE_PID:-}\" > \"$PWD/pretool-pid\"; cat | jq -r '.session_id // empty' > \"$PWD/pretool-session-id\"; } 2>/dev/null" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "{ printf '%s\\n' \"${CLAUDE_PID:-}\" > \"$PWD/stop-pid\"; cat | jq -r '.session_id // empty' > \"$PWD/stop-session-id\"; } 2>/dev/null", "asyncRewake": true, "timeout": 30 } ] }
    ]
  }
}
JSON

(
  cd "$LAB" || exit 1
  claude -p "Run the shell command 'true' with the Bash tool, then reply with exactly OK and stop." \
    --dangerously-skip-permissions --output-format stream-json --verbose
) > "$LAB/transcript.log" 2>&1 || fail "Claude credentialed session failed: $(tail -20 "$LAB/transcript.log")"

# The async Stop hook fires in the background after the CLI process returns;
# give it a bounded moment to land before reading its output.
i=0
while [ "$i" -lt 60 ] && [ ! -s "$LAB/stop-pid" ]; do
  sleep 0.5
  i=$((i + 1))
done

for stage in sessionstart pretool stop; do
  [ -s "$LAB/$stage-pid" ] || fail "$stage hook never recorded CLAUDE_PID at all"
  pid=$(tr -d '[:space:]' < "$LAB/$stage-pid")
  case "$pid" in
    ''|*[!0-9]*) fail "$stage hook saw a non-numeric CLAUDE_PID: '$pid'" ;;
  esac
done

SESSIONSTART_PID=$(tr -d '[:space:]' < "$LAB/sessionstart-pid")
PRETOOL_PID=$(tr -d '[:space:]' < "$LAB/pretool-pid")
STOP_PID=$(tr -d '[:space:]' < "$LAB/stop-pid")
[ "$SESSIONSTART_PID" = "$PRETOOL_PID" ] && [ "$PRETOOL_PID" = "$STOP_PID" ] \
  || fail "CLAUDE_PID was not stable across hook types: sessionstart=$SESSIONSTART_PID pretool=$PRETOOL_PID stop=$STOP_PID"

# session_id is the independent signal fm-turnend-guard.sh already reads for
# logging; cross-checking it against CLAUDE_PID's own stability corroborates
# that both name the same real session rather than each drifting separately.
SESSIONSTART_SID=$(tr -d '[:space:]' < "$LAB/sessionstart-session-id" 2>/dev/null || true)
STOP_SID=$(tr -d '[:space:]' < "$LAB/stop-session-id" 2>/dev/null || true)
[ -n "$SESSIONSTART_SID" ] && [ "$SESSIONSTART_SID" = "$STOP_SID" ] \
  || fail "session_id was not stable across hook types: sessionstart='$SESSIONSTART_SID' stop='$STOP_SID'"

printf 'ok - Claude %s live E2E: CLAUDE_PID=%s (session_id=%s) reached SessionStart, PreToolUse, and Stop hook children with a stable value\n' \
  "$CLAUDE_VERSION" "$SESSIONSTART_PID" "$SESSIONSTART_SID"
