#!/usr/bin/env bash
# fm-context-cap.sh - bounded-context restart policy for long-lived Firstmate
# conversations: a home's own primary session and its persistent second mates.
#
# WHY THIS EXISTS. A supervision conversation re-sends its whole history on
# every model request, so a session that lives for days pays for its full
# context on every wake. This command measures that context at each turn end and,
# once it crosses a cap, restarts the conversation at a safe boundary so recovery
# from durable records resumes in a fresh one. It restarts nothing itself: a
# second mate goes through bin/fm-secondmate-restart.sh (persist-gated, then
# bin/fm-control.sh relaunch), and a primary is reset with its harness's own
# context-reset command, whose session-open hook re-emits the session-start
# digest (bin/fm-sessionstart-run.sh). Nothing here stops an agent without a
# replacement path, tears anything down, or touches a worktree.
#
# Usage: fm-context-cap.sh record --claude
#          Turn-end hook entry. Reads the hook payload on stdin and records the
#          lock-owning primary session's current context size. Always exits 0
#          and prints nothing; an unreadable payload or transcript records
#          nothing rather than a guess.
#        fm-context-cap.sh reset
#          Drop the recorded size. bin/fm-sessionstart-run.sh calls this on every
#          session open that does not restore the prior conversation, because the
#          recorded size describes a context that no longer exists.
#        fm-context-cap.sh status [<secondmate-id>]
#          Print one line: the cap, the recorded size, and the verdict
#          (off|unknown|under|over) for this home's primary or the named local
#          second mate. Exits 1 on an unusable cap configuration.
#        fm-context-cap.sh tick
#          The watcher's cadence entry (bin/fm-watch.sh). Acts once per over-cap
#          session, prints each queued `check:` wake reason, and returns.
#        fm-context-cap.sh restart-primary --persisted
#          Run by the primary itself, after it wrote down its open work, to
#          schedule its own context reset. Returns at once; the reset happens
#          after the turn ends. --persisted is the caller's attestation that the
#          open-record persistence is done, and is required.
#
# THE SIGNAL. state/.context-size, one line:
#   v1 tokens=<n> ts=<epoch> session=<id> lock=<pid> harness=<name>
# <n> is the input side of the session's latest main-conversation model request
# (fresh input plus cache writes plus cache reads), which is the context that
# request re-sent. state/.context-size-baseline keeps the first size recorded
# for a session id. Only the session that owns the home's session lock records,
# and a record whose lock= no longer matches state/.lock reads as unknown, so a
# size left behind by an earlier process is never acted on.
# Only Claude Code is measured: its Stop payload names the session transcript,
# whose assistant entries carry the API usage. Every other harness has no
# verified source, records nothing, and reads `unknown`, which never restarts.
#
# THE CAP. config/context-cap holds one line: a positive integer token count, or
# `off`. FM_CONTEXT_CAP_TOKENS overrides the file. Absent means 150000. An
# unusable value is an error that restarts nothing. A parent applies its own cap
# to its second mates; a second mate's home never restarts its own primary.
#
# WHAT A TICK DOES, at most once per over-cap session id:
#   - A second mate: starts bin/fm-secondmate-restart.sh --reason context-cap
#     detached. Its persist request queues behind any turn the mate is in and
#     only the mate's own correlated answer releases the restart, which is the
#     safe boundary. A clean restart is silent. Anything else queues one
#     `check: secondmate <id> context-cap restart not completed: ...` wake.
#     The pass holds that mate's liveness lock (bin/fm-secondmate-liveness-lib.sh)
#     so the watcher's liveness tick cannot read the mate dead mid-restart and
#     relaunch a second agent beside the replacement.
#     A remote second mate is skipped: its home's record is not readable here.
#   - This home's primary: queues one `check: context-cap primary ...` wake
#     asking it to write down open work and run restart-primary --persisted.
#     The primary stays in the loop because only it knows what its conversation
#     still holds. While an away or quiet record exists (state/.afk-contract or
#     state/.afk) nothing is queued and nothing is marked: those wakes can be
#     handled outside the primary conversation, by a session that does not own
#     this home and so could not reset it. The ask is made once the record
#     clears.
#   - Either, when the session's FIRST recorded size was already above four
#     fifths of the cap: queues one wake saying a restart would free too little
#     and restarts nothing, so a cap set at or near the fresh-session floor can
#     never loop or thrash.
#
# THE PRIMARY RESET. restart-primary requires a Claude primary that owns this
# home's session lock and a discoverable terminal endpoint
# (bin/fm-supervisor-target-lib.sh). Its detached worker waits for the endpoint
# to read idle with a confirmed-empty composer twice in a row, submits `/clear`,
# takes the session-open hook's `reset` as the confirmation, then submits one
# operational session-start prompt so a turn runs and its turn-end hook re-arms
# supervision. A captain's half-typed line, a busy turn, or a vanished endpoint
# defers and, past the bound, ends in one `check: context-cap primary restart
# not completed: ...` wake; the conversation is left as it was.
#
# Environment knobs:
#   FM_CONTEXT_CAP_TOKENS       cap override (positive integer or `off`)
#   FM_CONTEXT_CAP_IDLE_WAIT    seconds to wait for an idle, empty prompt (600)
#   FM_CONTEXT_CAP_CLEAR_WAIT   seconds to wait for the reset confirmation (90)
#   FM_CONTEXT_CAP_POLL         seconds between endpoint reads (3)
#
# Exit status: 0 done (record, reset, and tick always); 1 refused or unusable
# configuration; 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

FM_CONTEXT_CAP_DEFAULT=150000
RECORD_FILE="$STATE/.context-size"
BASELINE_FILE="$STATE/.context-size-baseline"
# Transcript lines read from the tail when measuring. A long session's
# transcript runs to many megabytes, and the latest main-conversation request is
# always near its end.
TAIL_LINES=400

usage() {
  sed -n '2,95{s/^# \{0,1\}//;p;}' "$0"
}

# --- cap ---------------------------------------------------------------------

# Resolve the cap into CAP (`off` or a positive integer). Fails with CAP_ERROR
# set when the configured value is unusable.
CAP=
CAP_ERROR=
resolve_cap() {
  local raw source
  CAP=
  CAP_ERROR=
  if [ -n "${FM_CONTEXT_CAP_TOKENS:-}" ]; then
    raw=$FM_CONTEXT_CAP_TOKENS
    source=FM_CONTEXT_CAP_TOKENS
  elif [ -e "$CONFIG/context-cap" ] || [ -L "$CONFIG/context-cap" ]; then
    source=$CONFIG/context-cap
    if [ ! -f "$CONFIG/context-cap" ] || [ -L "$CONFIG/context-cap" ]; then
      CAP_ERROR="$source is not a regular file"
      return 1
    fi
    IFS= read -r raw < "$CONFIG/context-cap" 2>/dev/null || true
    raw=${raw//[[:space:]]/}
  else
    CAP=$FM_CONTEXT_CAP_DEFAULT
    return 0
  fi
  case "$raw" in
    off) CAP=off ;;
    ''|*[!0-9]*|0*) CAP_ERROR="$source must hold a positive integer token count or 'off': '${raw}'"; return 1 ;;
    *) CAP=$raw ;;
  esac
}

# --- the record --------------------------------------------------------------

# Parse one record or baseline file into R_* globals. Fails on anything that is
# not exactly the v1 shape, so a truncated write reads as no record.
R_TOKENS=
R_TS=
R_SESSION=
R_LOCK=
read_record() {  # <file>
  local file=$1 line word key value
  R_TOKENS=
  R_TS=
  R_SESSION=
  R_LOCK=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  IFS= read -r line < "$file" 2>/dev/null || return 1
  case "$line" in 'v1 '*) ;; *) return 1 ;; esac
  for word in ${line#v1 }; do
    key=${word%%=*}
    value=${word#*=}
    case "$key" in
      tokens) R_TOKENS=$value ;;
      ts) R_TS=$value ;;
      session) R_SESSION=$value ;;
      lock) R_LOCK=$value ;;
    esac
  done
  case "$R_TOKENS" in ''|*[!0-9]*) return 1 ;; esac
  case "$R_SESSION" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

write_atomic() {  # <file> <line>
  local file=$1 tmp
  tmp="$file.$$.tmp"
  printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}

# The input side of the latest main-conversation request in a Claude transcript.
# Prints nothing when the tail holds no such entry.
claude_transcript_tokens() {  # <transcript>
  tail -n "$TAIL_LINES" "$1" 2>/dev/null | jq -R -r -s '
    [ split("\n")[]
      | (fromjson? // empty)
      | select(type == "object" and .type == "assistant" and .isSidechain != true)
      | .message.usage
      | select(type == "object")
      | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
      | select(type == "number" and . > 0)
    ] | last // empty | floor' 2>/dev/null
}

cmd_record() {
  local payload transcript session tokens lock_pid
  [ "${1:-}" = --claude ] || { echo "usage: $(basename "$0") record --claude" >&2; exit 2; }
  payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh"
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  # Cursor loads the tracked Claude settings too; its payload is not a Claude
  # transcript and must record nothing.
  fm_hook_payload_is_foreign_host "$payload" && exit 0
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
  transcript=$(printf '%s' "$payload" | jq -r '(.transcript_path // "") | strings' 2>/dev/null) || exit 0
  session=$(printf '%s' "$payload" | jq -r '(.session_id // "") | strings' 2>/dev/null) || exit 0
  case "$session" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
  # pi-code replays Claude hooks with its own session file, which carries no
  # Claude usage entries (bin/fm-claude-stop-autoarm.sh owns that distinction).
  case "$transcript" in ''|*/.pi/*) exit 0 ;; esac
  [ -f "$transcript" ] || exit 0
  tokens=$(claude_transcript_tokens "$transcript")
  case "$tokens" in ''|*[!0-9]*) exit 0 ;; esac
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) exit 0 ;; esac
  write_atomic "$RECORD_FILE" \
    "v1 tokens=$tokens ts=$(date +%s) session=$session lock=$lock_pid harness=claude" || exit 0
  if ! read_record "$BASELINE_FILE" || [ "$R_SESSION" != "$session" ]; then
    write_atomic "$BASELINE_FILE" "v1 tokens=$tokens session=$session" || true
  fi
  exit 0
}

cmd_reset() {
  rm -f "$RECORD_FILE" 2>/dev/null || true
  exit 0
}

# True when a session that started at <baseline> tokens is too close to CAP for
# a restart to be worth its persist and resume turns.
near_floor() {  # <baseline>
  [ -n "$1" ] && [ "$1" -gt $((CAP * 4 / 5)) ]
}

# Verdict for one home's state dir against CAP. Sets V_VERDICT and leaves the
# record in R_*; V_BASELINE is that session's first recorded size, when known.
V_VERDICT=
V_BASELINE=
evaluate() {  # <state-dir>
  local state=$1 lock_pid tokens session ts lock
  V_VERDICT=unknown
  V_BASELINE=
  if [ "$CAP" = off ]; then
    V_VERDICT=off
    return 0
  fi
  read_record "$state/.context-size" || return 0
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  [ -n "$R_LOCK" ] && [ "$R_LOCK" = "$lock_pid" ] || return 0
  tokens=$R_TOKENS session=$R_SESSION ts=$R_TS lock=$R_LOCK
  if read_record "$state/.context-size-baseline" && [ "$R_SESSION" = "$session" ]; then
    V_BASELINE=$R_TOKENS
  fi
  R_TOKENS=$tokens R_SESSION=$session R_TS=$ts R_LOCK=$lock
  if [ "$R_TOKENS" -ge "$CAP" ]; then
    V_VERDICT=over
  else
    V_VERDICT=under
  fi
}

# --- second mates ------------------------------------------------------------

# Resolve a LOCAL second mate's home state dir from this home's record of it,
# under the same marker proof the watcher's foreign-queue observation uses.
SM_STATE=
SM_SKIP=
secondmate_state() {  # <id>
  local id=$1 meta="$STATE/$1.meta" home
  SM_STATE=
  SM_SKIP=
  [ -f "$meta" ] && [ ! -L "$meta" ] || { SM_SKIP="no durable record for this second mate in this home"; return 1; }
  [ "$(fm_meta_get "$meta" kind)" = secondmate ] || { SM_SKIP="the durable record is not a second mate's"; return 1; }
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || { SM_SKIP="a remote second mate's context size is not readable from this home"; return 1; }
  home=$(fm_meta_get "$meta" home)
  [ -n "$home" ] || { SM_SKIP="the durable record names no home"; return 1; }
  if [ ! -f "$home/.fm-secondmate-home" ] || [ -L "$home/.fm-secondmate-home" ] \
    || [ "$(cat "$home/.fm-secondmate-home" 2>/dev/null || true)" != "$id" ]; then
    SM_SKIP="the recorded home does not carry this second mate's marker"
    return 1
  fi
  SM_STATE="$home/state"
}

cmd_status() {
  local id=${1:-} subject=primary state=$STATE
  if ! resolve_cap; then
    echo "error: $CAP_ERROR" >&2
    exit 1
  fi
  if [ -n "$id" ]; then
    id=${id#fm-}
    case "$id" in *[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $1" >&2; exit 2 ;; esac
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh"
    secondmate_state "$id" || { echo "error: $SM_SKIP" >&2; exit 1; }
    subject=$id
    state=$SM_STATE
  fi
  evaluate "$state"
  case "$V_VERDICT" in
    off|unknown) printf 'context-cap: subject=%s cap=%s tokens=unknown verdict=%s\n' "$subject" "$CAP" "$V_VERDICT" ;;
    *) printf 'context-cap: subject=%s cap=%s tokens=%s verdict=%s\n' "$subject" "$CAP" "$R_TOKENS" "$V_VERDICT" ;;
  esac
  exit 0
}

# --- the tick ----------------------------------------------------------------

# One marker per subject holds the session id last acted on, so each over-cap
# session is acted on once however many ticks observe it. A `restarting` marker
# older than RESTARTING_STALE_SECS belongs to a worker that died without
# recording an outcome (a reboot, a kill), and reads as no marker so the session
# is not left over the cap for good.
RESTARTING_STALE_SECS=7200
marker_session() {  # <marker-file>
  local line session state ts
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  IFS= read -r line < "$1" 2>/dev/null || return 1
  session=${line#session=}
  session=${session%% *}
  state=${line#* state=}
  state=${state%% *}
  ts=${line##* ts=}
  if [ "$state" = restarting ]; then
    case "$ts" in ''|*[!0-9]*) return 1 ;; esac
    [ $(($(date +%s) - ts)) -lt "$RESTARTING_STALE_SECS" ] || return 1
  fi
  printf '%s' "$session"
}

queue_check() {  # <key> <reason>
  local queued
  queued=$(fm_wake_queued_keys check 2>/dev/null || true)
  printf '%s\n' "$queued" | grep -Fx -- "$1" >/dev/null 2>&1 && return 0
  fm_wake_append check "$1" "$2"
}

# Start one worker that outlives the watcher cycle that asked for it: nohup,
# stdio detached, its own process group (the shape bin/fm-startup-network.sh
# uses and explains).
launch_detached() {  # <subcommand> <args>...
  local monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
    nohup "$SCRIPT_DIR/fm-context-cap.sh" "$@" >/dev/null 2>&1 </dev/null &
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
}

tick_primary() {
  local marker="$STATE/.context-cap-primary" reason key
  # A second mate's parent restarts it; its own home never does.
  fm_root_is_secondmate_home "$FM_HOME" && return 0
  # Away and quiet wakes may be handled outside the primary conversation.
  if [ -e "$STATE/.afk-contract" ] || [ -e "$STATE/.afk" ]; then
    return 0
  fi
  evaluate "$STATE"
  [ "$V_VERDICT" = over ] || return 0
  [ "$(marker_session "$marker" || true)" != "$R_SESSION" ] || return 0
  if near_floor "$V_BASELINE"; then
    key="context-cap-primary-floor-$R_SESSION"
    reason="check: context-cap primary conversation already started at $V_BASELINE tokens, too close to the $CAP-token cap for a restart to help - raise config/context-cap or trim what loads at startup; nothing was restarted"
  else
    key="context-cap-primary-$R_SESSION"
    reason="check: context-cap primary conversation is at $R_TOKENS tokens, over the $CAP-token cap - write down the open work held only in this conversation (the stow skill's \"Open-record persistence\" section and nothing else from it), then run $FM_ROOT/bin/fm-context-cap.sh restart-primary --persisted and end the turn"
  fi
  queue_check "$key" "$reason" || return 0
  write_atomic "$marker" "session=$R_SESSION state=notified ts=$(date +%s)" || true
  printf '%s\n' "$reason"
}

tick_secondmates() {
  local meta id marker reason
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    [ "$(fm_meta_get "$meta" kind 2>/dev/null || true)" = secondmate ] || continue
    id=${meta##*/}
    id=${id%.meta}
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    secondmate_state "$id" || continue
    evaluate "$SM_STATE"
    [ "$V_VERDICT" = over ] || continue
    marker="$STATE/.context-cap-secondmate-$id"
    [ "$(marker_session "$marker" || true)" != "$R_SESSION" ] || continue
    if near_floor "$V_BASELINE"; then
      reason="check: secondmate $id context-cap: its conversation already started at $V_BASELINE tokens, too close to the $CAP-token cap for a restart to help - raise config/context-cap or trim what its home loads at startup; nothing was restarted"
      queue_check "context-cap-secondmate-floor-$id-$R_SESSION" "$reason" || continue
      write_atomic "$marker" "session=$R_SESSION state=floor ts=$(date +%s)" || true
      printf '%s\n' "$reason"
      continue
    fi
    # Marker first: a tick that cannot record the attempt must not start one,
    # or every later tick would start another.
    write_atomic "$marker" "session=$R_SESSION state=restarting ts=$(date +%s)" || continue
    launch_detached restart-secondmate "$id" "$R_SESSION"
  done
}

cmd_tick() {
  if ! resolve_cap; then
    echo "fm-context-cap: $CAP_ERROR; nothing restarted" >&2
    exit 0
  fi
  [ "$CAP" != off ] || exit 0
  [ -d "$STATE" ] || exit 0
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  tick_primary
  tick_secondmates
  exit 0
}

# Internal: the detached second-mate restart. The restart command owns the
# persist gate and the restart; this only turns its outcome into the marker and,
# when the mate was not restarted, one wake.
cmd_restart_secondmate() {  # <id> <session>
  local id=${1:-} session=${2:-} marker out rc why
  case "$id" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
  case "$session" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
  marker="$STATE/.context-cap-secondmate-$id"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-secondmate-liveness-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"
  if ! fm_secondmate_liveness_lock "$id"; then
    # A liveness episode owns this mate right now. Leave no marker, so a later
    # tick decides again from whatever that episode left.
    rm -f "$marker" 2>/dev/null || true
    exit 0
  fi
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-secondmate-restart.sh" --reason context-cap "$id" 2>&1)
  rc=$?
  fm_secondmate_liveness_unlock "$id"
  if [ "$rc" -eq 0 ]; then
    write_atomic "$marker" "session=$session state=restarted ts=$(date +%s)" || true
    exit 0
  fi
  why=$(printf '%s\n' "$out" | sed -n '/^unreached: /{s/^unreached: [^:]*: //;p;q;}')
  [ -n "$why" ] || why=$(printf '%s\n' "$out" | sed -n '/./{s/^error: //;p;q;}')
  [ -n "$why" ] || why="the restart command exited $rc without a reported reason"
  write_atomic "$marker" "session=$session state=failed ts=$(date +%s)" || true
  queue_check "context-cap-secondmate-failed-$id-$session" \
    "check: secondmate $id context-cap restart not completed: $why" || true
  exit 0
}

# --- the primary reset -------------------------------------------------------

FM_CONTEXT_RESUME_PROMPT='The context cap reset this conversation. The session-start digest already in this conversation is your recovery input: confirm it is present as AGENTS.md section 3 requires, then resume supervision from the durable records.'

cmd_restart_primary() {
  local harness target backend
  [ "${1:-}" = --persisted ] || {
    echo "error: restart-primary requires --persisted, your statement that the open work held only in this conversation is written down" >&2
    exit 2
  }
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$SCRIPT_DIR/fm-primary-scope-lib.sh"
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  if fm_root_is_secondmate_home "$FM_HOME"; then
    echo "error: a second mate's conversation is restarted by its parent home, not from here" >&2
    exit 1
  fi
  if ! fm_session_lock_owned_by_self "$STATE"; then
    echo "error: this session does not own this home's session lock, so it cannot reset the primary conversation" >&2
    exit 1
  fi
  harness=$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || true)
  if [ "$harness" != claude ]; then
    echo "error: no verified context reset exists for a '${harness:-unknown}' primary; restart the session by hand" >&2
    exit 1
  fi
  if ! read_record "$RECORD_FILE"; then
    echo "error: no context size is recorded for this session, so there is nothing to confirm a reset against" >&2
    exit 1
  fi
  if ! target=$(discover_supervisor_target); then
    echo "error: this session's terminal endpoint could not be discovered (set FM_SUPERVISOR_TARGET); reset the conversation by hand with /clear" >&2
    exit 1
  fi
  backend=$(discover_supervisor_backend)
  if ! fm_backend_target_exists "$backend" "$target"; then
    echo "error: terminal endpoint $target was not found on $backend; reset the conversation by hand with /clear" >&2
    exit 1
  fi
  write_atomic "$STATE/.context-cap-primary" "session=$R_SESSION state=restarting ts=$(date +%s)" || true
  launch_detached clear-primary "$backend" "$target" "$R_SESSION"
  echo "context reset scheduled: end this turn now; the conversation resets once the prompt is idle and empty, and resumes from the session-start digest"
  exit 0
}

endpoint_busy() {  # <backend> <target>
  local native tail40
  native=$(fm_backend_busy_state "$1" "$2" 2>/dev/null)
  [ "$native" != busy ] || return 0
  tail40=$(fm_backend_capture "$1" "$2" 40 2>/dev/null) || return 0
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match claude
}

# Internal: the detached primary reset worker.
cmd_clear_primary() {  # <backend> <target> <session>
  local backend=${1:-} target=${2:-} session=${3:-}
  local idle_wait=${FM_CONTEXT_CAP_IDLE_WAIT:-600} clear_wait=${FM_CONTEXT_CAP_CLEAR_WAIT:-90} poll=${FM_CONTEXT_CAP_POLL:-3}
  local marker="$STATE/.context-cap-primary" deadline quiet=0 prompt verdict
  [ -n "$backend" ] && [ -n "$target" ] || exit 2
  case "$session" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
  case "$idle_wait" in ''|*[!0-9]*) idle_wait=600 ;; esac
  case "$clear_wait" in ''|*[!0-9]*) clear_wait=90 ;; esac
  case "$poll" in ''|*[!0-9]*|0) poll=3 ;; esac
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  # shellcheck source=bin/fm-composer-lib.sh
  . "$SCRIPT_DIR/fm-composer-lib.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh"

  give_up() {  # <why>
    write_atomic "$marker" "session=$session state=failed ts=$(date +%s)" || true
    queue_check "context-cap-primary-failed-$session" \
      "check: context-cap primary restart not completed: $1" || true
    exit 0
  }
  # Two consecutive idle reads with a confirmed-empty composer. Anything else -
  # a running turn, a half-typed line, an unreadable pane - resets the count.
  wait_idle_empty() {  # <deadline>
    quiet=0
    while :; do
      fm_backend_target_exists "$backend" "$target" || return 2
      if ! endpoint_busy "$backend" "$target" \
        && [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" = empty ]; then
        quiet=$((quiet + 1))
        [ "$quiet" -lt 2 ] || return 0
      else
        quiet=0
      fi
      [ "$(date +%s)" -lt "$1" ] || return 1
      sleep "$poll"
    done
  }

  deadline=$(($(date +%s) + idle_wait))
  wait_idle_empty "$deadline"
  case $? in
    1) give_up "the session did not reach an idle, empty prompt within ${idle_wait}s; the conversation was left as it was" ;;
    2) give_up "its terminal endpoint $target is gone; the conversation was left as it was" ;;
  esac
  # The record is this worker's proof of which conversation it is resetting. One
  # that is gone or names another session means a reset already happened.
  if ! read_record "$RECORD_FILE" || [ "$R_SESSION" != "$session" ]; then
    write_atomic "$marker" "session=$session state=superseded ts=$(date +%s)" || true
    exit 0
  fi
  fm_backend_send_text_submit "$backend" "$target" "/clear" 3 1 1 >/dev/null 2>&1 || true
  deadline=$(($(date +%s) + clear_wait))
  while read_record "$RECORD_FILE" && [ "$R_SESSION" = "$session" ]; do
    [ "$(date +%s)" -lt "$deadline" ] \
      || give_up "the reset command was sent but no new session opened within ${clear_wait}s; check the primary's prompt"
    sleep 1
  done
  # A reset conversation runs no turn on its own, and supervision is re-armed by
  # a turn end. Submit one operational prompt so that turn happens.
  if fm_operational_harness_needs_record claude; then
    fm_operational_record_write "$STATE" session-start "$FM_CONTEXT_RESUME_PROMPT" prompt \
      || give_up "the conversation was reset but the resume prompt could not be published; send the primary any message to resume supervision"
  else
    fm_operational_input_encode session-start "$FM_CONTEXT_RESUME_PROMPT" prompt \
      || give_up "the conversation was reset but the resume prompt could not be built; send the primary any message to resume supervision"
  fi
  deadline=$(($(date +%s) + clear_wait))
  wait_idle_empty "$deadline" \
    || give_up "the conversation was reset but its prompt did not read idle and empty within ${clear_wait}s, so the resume prompt was not sent; send the primary any message to resume supervision"
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$prompt" 3 1 1 2>/dev/null)
  [ "$verdict" = empty ] \
    || give_up "the conversation was reset but the resume prompt was not confirmed submitted; send the primary any message to resume supervision"
  write_atomic "$marker" "session=$session state=restarted ts=$(date +%s)" || true
  exit 0
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  record) shift; cmd_record "$@" ;;
  reset) cmd_reset ;;
  status) shift; cmd_status "$@" ;;
  tick) cmd_tick ;;
  restart-primary) shift; cmd_restart_primary "$@" ;;
  restart-secondmate) shift; cmd_restart_secondmate "$@" ;;
  clear-primary) shift; cmd_clear_primary "$@" ;;
  *) usage >&2; exit 2 ;;
esac
