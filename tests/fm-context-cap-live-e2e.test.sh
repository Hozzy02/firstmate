#!/usr/bin/env bash
# Opt-in live guard for the bounded-context restart on a real Claude Code
# primary (bin/fm-context-cap.sh).
#
# Four facts the policy stands on come from the vendor, so a stub can only
# confirm the assumption already written into the stub:
#
#   (a) the Stop payload names a transcript whose latest assistant entry carries
#       the request's usage, so the turn-end hook can record a context size,
#   (b) a worker detached from the model's own Bash call survives that turn
#       ending and can read the pane idle with an empty composer,
#   (c) a submitted `/clear` opens a new session whose session-open hook runs,
#       which is the reset confirmation, and
#   (d) the operational resume prompt submitted afterwards starts a turn, whose
#       turn-end hook records a size under a NEW session id.
#
# tests/fm-context-cap.test.sh pins the policy logic portably with real
# processes and no harness. This guard covers only what CI cannot see.
#
# It drives one interactive Claude Code session in a private tmux server, in a
# throwaway clone that is its own Firstmate home with no fleet work, so nothing
# here touches a real home, lock, or fleet. Claude keeps using its existing
# managed authentication. It costs a handful of short model turns.
#
# Run it after every Claude Code upgrade and before trusting refreshed evidence
# in docs/verification/supervision.md:
#
#   FM_CONTEXT_CAP_LIVE_E2E=1 tests/fm-context-cap-live-e2e.test.sh
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CONTEXT_CAP_LIVE_E2E claude tmux jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_CONTEXT_CAP_TOKENS
unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }

# Outside the repo on purpose: the lab is its own git repo and its own home.
LAB="$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-context-cap-live-e2e.$$"
SOCKET="fm-ctxcap-$$"
SESSION=fmctx
VERSION=$(claude --version 2>/dev/null | head -n 1)
[ -n "$VERSION" ] || VERSION=unknown

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT INT TERM

capture() { tmux -L "$SOCKET" capture-pane -p -t "$SESSION" -S -400 2>/dev/null || true; }

wait_for_text() {  # <text> [attempts]
  local expected=$1 attempts=${2:-90} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq -- "$expected" && return 0
    sleep 2
    i=$((i + 1))
  done
  return 1
}

send_line() {  # <text>
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
  sleep 2
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}

record_field() {  # <key>
  sed -n "1s/.* $1=\\([^ ]*\\).*/\\1/p" "$LAB/state/.context-size" 2>/dev/null
}

# Wait for a size record that differs from <previous-ts>:<previous-session>.
wait_for_record() {  # <previous-stamp> [attempts]
  local previous=$1 attempts=${2:-60} i=0 stamp
  while [ "$i" -lt "$attempts" ]; do
    stamp="$(record_field ts):$(record_field session)"
    [ "$stamp" != ":" ] && [ "$stamp" != "$previous" ] && return 0
    sleep 2
    i=$((i + 1))
  done
  return 1
}

# --- lab ---------------------------------------------------------------------
# A clone carries only committed state, so the working-tree surfaces under test
# are copied over it. The lab is both the checkout and its own FM_HOME, with no
# fleet work, so the turn-end guard and the auto-arm stay inert.
git clone -q "$ROOT" "$LAB" || fail "could not create the lab clone"
cp -R "$ROOT/bin/." "$LAB/bin/"
cp "$ROOT/.claude/settings.json" "$LAB/.claude/settings.json"
mkdir -p "$LAB/state" "$LAB/config" "$LAB/data"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -c "$LAB" -x 200 -y 50 \
  -e FM_HOME="$LAB" -e CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
  "claude --permission-mode bypassPermissions --effort low" \
  || fail "claude $VERSION: could not start an interactive lab session"

# A folder Claude has not seen asks for trust first. Which option the dialog
# preselects has changed between releases (2.1.289 preselects "No, exit"), so
# the selection is read off the pane and moved onto the trusting option before
# it is confirmed. The session lock appearing proves session start ran.
n=0
while [ "$n" -lt 90 ] && [ ! -s "$LAB/state/.lock" ]; do
  if capture | grep -qiE 'trust (this|the|parent)?[[:space:]]*(folder|project)'; then
    if capture | grep -E '^[[:space:]]*❯' | tail -n 1 | grep -qi 'yes'; then
      tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
      sleep 5
    else
      tmux -L "$SOCKET" send-keys -t "$SESSION" Down
    fi
  fi
  sleep 2
  n=$((n + 1))
done
[ -s "$LAB/state/.lock" ] || { capture >&2; fail "claude $VERSION: the lab session never took the helm"; }
sleep 10

# --- (a) the turn-end record -------------------------------------------------
send_line 'Reply with exactly CTXONE and stop. Use no tools.'
wait_for_text CTXONE || { capture >&2; fail "claude $VERSION: the first lab turn did not complete"; }
wait_for_record ":" || { capture >&2; fail "claude $VERSION: the Stop hook recorded no context size, so the Stop payload or transcript usage shape changed"; }
T1=$(record_field tokens)
S1=$(record_field session)
case "$T1" in ''|*[!0-9]*|0) fail "claude $VERSION: the recorded size is not a positive token count: '$T1'" ;; esac
[ "$(record_field lock)" = "$(cat "$LAB/state/.lock")" ] || fail "claude $VERSION: the record is not bound to the lock-owning session"
pass "claude $VERSION: a turn end records the session's context size ($T1 tokens) under its session id"

STAMP="$(record_field ts):$S1"
send_line 'Reply with exactly CTXTWO and stop. Use no tools.'
wait_for_text CTXTWO || { capture >&2; fail "claude $VERSION: the second lab turn did not complete"; }
wait_for_record "$STAMP" || fail "claude $VERSION: the second turn end did not refresh the record"
T2=$(record_field tokens)
[ "$T2" -gt "$T1" ] || fail "claude $VERSION: a longer conversation did not record a larger context ($T1 then $T2)"
pass "claude $VERSION: the recorded size grows with the conversation ($T1 then $T2 tokens)"

# --- the tick's verdict on that record ---------------------------------------
# A cap between a quarter above the session's first size (the fresh-session
# floor is four fifths of the cap) and its current size is over the cap without
# being too close to the baseline. Two short turns grow too little for that, so
# read a bulky file first.
awk 'BEGIN { for (i = 0; i < 3000; i++) print "context-cap filler line " i " padding padding padding padding" }' > "$LAB/filler.txt"
STAMP="$(record_field ts):$S1"
send_line 'Read the whole file filler.txt in the current directory with the Read tool (use offset and limit to read every line), then reply with exactly CTXTHREE and stop.'
wait_for_text CTXTHREE 240 || { capture >&2; fail "claude $VERSION: the bulky-read turn did not complete"; }
wait_for_record "$STAMP" || fail "claude $VERSION: the bulky-read turn end did not refresh the record"
T2=$(record_field tokens)
CAPV=$((T1 * 5 / 4 + 1))
[ "$T2" -gt "$CAPV" ] || fail "claude $VERSION: the bulky read grew the context only to $T2 tokens, not past the $CAPV-token cap"
printf '%s\n' "$CAPV" > "$LAB/config/context-cap"
TICK=$(FM_HOME="$LAB" "$LAB/bin/fm-context-cap.sh" tick 2>&1)
case "$TICK" in
  "check: context-cap primary conversation is at $T2 tokens"*"restart-primary --persisted"*) ;;
  *) fail "claude $VERSION: the tick did not ask the over-cap primary to persist and restart: $TICK" ;;
esac
pass "claude $VERSION: an over-cap primary gets the persist-and-restart wake"

# --- (b) (c) (d) the reset ---------------------------------------------------
STAMP="$(record_field ts):$S1"
send_line 'Run exactly `bin/fm-context-cap.sh restart-primary --persisted` once with Bash, then reply with exactly CTXSCHEDULED and stop.'
wait_for_text CTXSCHEDULED || { capture >&2; fail "claude $VERSION: the primary could not schedule its own reset: $(cat "$LAB/state/.context-cap-primary" 2>/dev/null)"; }

n=0
while [ "$n" -lt 150 ]; do
  grep -Eq 'state=(restarted|failed|superseded)' "$LAB/state/.context-cap-primary" 2>/dev/null && break
  sleep 2
  n=$((n + 1))
done
MARKER=$(cat "$LAB/state/.context-cap-primary" 2>/dev/null)
case "$MARKER" in
  "session=$S1 state=restarted "*) ;;
  *) capture >&2; fail "claude $VERSION: the reset did not complete: marker '$MARKER'; queued: $(cat "$LAB/state/.wake-queue" 2>/dev/null)" ;;
esac
pass "claude $VERSION: the detached worker outlived the turn, submitted /clear at an idle empty prompt, and saw the session-open hook reset the record"

wait_for_record "$STAMP" 90 || { capture >&2; fail "claude $VERSION: the resume prompt started no turn, so a reset session would sit unsupervised"; }
S2=$(record_field session)
T3=$(record_field tokens)
[ "$S2" != "$S1" ] || fail "claude $VERSION: the conversation after /clear kept session id $S1, so it was not a new context"
! grep -Fq 'context-cap primary restart not completed' "$LAB/state/.wake-queue" 2>/dev/null \
  || fail "claude $VERSION: a completed reset also queued a failure wake"
pass "claude $VERSION: the resume prompt ran a turn in a new session ($S2, $T3 tokens; the reset one ended at $T2)"

printf 'ok - Claude %s live E2E recorded context size at turn end and reset an over-cap primary through /clear into a new supervised session\n' "$VERSION"
