#!/usr/bin/env bash
# tests/fm-watch-beacon.test.sh - the watcher liveness beacon
# (state/.last-watcher-beat) must keep advancing inside a single long cycle,
# not only once at the top of the loop. Regression for
# data/firstmate-watcher-slow-cycle/report.md: a herdr control-socket RPC with
# no wall-clock timeout could block the per-window stale-pane capture for
# however long a wedged shared herdr server stayed silent, and the sum of a
# check sweep's per-check work could walk the beacon's age past its stale
# grace even when no single step hung. A third mechanism froze it before either
# of those phases ran: the pending-reply tick paid a lock and several
# subprocesses for every retained, already-resolved record. These drive a real
# fm-watch.sh subprocess against fixtures that reproduce each mechanism and assert the
# beacon keeps advancing well inside the grace window instead of only once
# per whole cycle. The herdr-side unit for the RPC bound itself
# (FM_BACKEND_HERDR_CLI_TIMEOUT) lives in tests/fm-backend-herdr.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-beacon-tests)

# Portable mtime in epoch seconds (see fm-watch.sh on why never `stat -f || stat -c`).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Launch a real watcher against <state> with the herdr fake first on PATH.
# Tight poll, no check or heartbeat cadence beyond what a case opts into, event
# push disabled so the ordinary poll loop (and its check sweep / stale-pane
# scan) is what runs.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 \
    FM_BACKEND_HERDR_EVENTS_FORCE=0 \
    env "$@" "$WATCH" > "$out" 2> "$out.err" &
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Count how many DISTINCT beacon mtimes are observed for <state>'s beacon
# while <pid> stays alive, polling for up to <limit> ticks (0.1s each). Used
# to prove more than one beat happened inside a single long cycle, not just
# the one at the top of the loop.
count_beat_advances() {  # <state> <pid> <limit-ticks>
  local state=$1 pid=$2 limit=$3 beat seen="" cur n=0 i=0
  beat="$state/.last-watcher-beat"
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || break
    cur=$(file_mtime "$beat")
    if [ -n "$cur" ]; then
      case "|$seen|" in
        *"|$cur|"*) ;;
        *) seen="$seen|$cur"; n=$((n + 1)) ;;
      esac
    fi
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s' "$n"
}

# One herdr-backed task window in <state> named <id>, so the watcher's
# per-window stale scan routes its capture through the fake herdr.
seed_herdr_window() {  # <state> <id> <window>
  local state=$1 id=$2 window=$3
  fm_write_meta "$state/$id.meta" "window=$window" "backend=herdr" "kind=ship"
}

# test_beacon_advances_promptly_when_herdr_capture_hangs: four herdr-backed
# windows whose backend hangs on every pane read (the wedged-server shape a
# shared herdr process can hit under host load). FM_POLL is long enough that
# the observation window sees only ONE top-of-cycle beat, so every further
# distinct beacon mtime must come from a beat inside that single cycle's
# stale-pane sweep - even though each bound-killed capture fails. Without the
# RPC bound in bin/backends/herdr.sh and the per-window beat (taken whether or
# not the capture succeeded) in bin/fm-watch.sh, the beacon stays frozen at its
# top-of-loop touch for the whole sweep.
test_beacon_advances_promptly_when_herdr_capture_hangs() {
  local dir state fakebin out pid start elapsed n
  dir=$(make_case beacon-herdr-capture-hangs); state="$dir/state"; fakebin="$dir/fakebin"
  seed_herdr_window "$state" tsk1 "sess:w1:p1"
  seed_herdr_window "$state" tsk2 "sess:w1:p2"
  seed_herdr_window "$state" tsk3 "sess:w1:p3"
  seed_herdr_window "$state" tsk4 "sess:w1:p4"
  # The session's server answers `status` immediately (the incident shape: one
  # shared herdr server process stays up for days); every OTHER call - the
  # pane reads the stale-pane capture actually needs - hangs far past the RPC
  # bound, reproducing a wedged socket for the calls report.md identifies.
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
  exit 0
fi
exec sleep 60
SH
  chmod +x "$fakebin/herdr"
  out="$dir/out"
  start=$(date +%s)
  watch_bg "$state" "$fakebin" "$out" FM_POLL=60 FM_CHECK_INTERVAL=999999 FM_BACKEND_HERDR_CLI_TIMEOUT=1
  pid=$!
  n=$(count_beat_advances "$state" "$pid" 150)
  elapsed=$(( $(date +%s) - start ))
  reap "$pid"
  [ "$n" -ge 3 ] \
    || fail "expected at least 3 distinct beacon advances inside one cycle's sweep of 4 hanging herdr windows within ${elapsed}s, got $n"
  [ "$elapsed" -lt 60 ] \
    || fail "beacon advances against 4 hanging herdr windows took ${elapsed}s; the RPC bound and per-window beat are not cutting the sweep short (report.md's pre-fix stalls ran 300-500s)"
  [ -s "$out" ] && fail "a hanging herdr backend alone must not produce a wake, got: $(cat "$out")"
  pass "beacon advances inside a single cycle across failed herdr captures (RPC bound + per-window beat), $n advances in ${elapsed}s"
}

# One custom watcher check in <state> that sleeps for <sleep-secs> and then
# succeeds silently (no wake), registered the same way firstmate's own tooling
# registers a real one.
seed_slow_check() {  # <state> <id> <sleep-secs>
  local state=$1 id=$2 secs=$3
  printf '#!/usr/bin/env bash\nsleep %s\nexit 0\n' "$secs" > "$state/$id.check.sh"
  chmod 700 "$state/$id.check.sh"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null \
    || fail "fm-check-register.sh could not register $id"
}

# test_beacon_advances_between_checks_in_the_sweep: three registered checks
# each individually well inside FM_CHECK_TIMEOUT, but whose SUM is not
# beaconed at all without the per-check beat - the #5421 mechanism report.md
# separately diagnosed (four checks at up to 30s each is ~120s of
# unbeaconed work under the pre-fix single top-of-loop touch).
test_beacon_advances_between_checks_in_the_sweep() {
  local dir state fakebin out pid start elapsed n
  dir=$(make_case beacon-check-sweep); state="$dir/state"; fakebin="$dir/fakebin"
  seed_slow_check "$state" chk1 2
  seed_slow_check "$state" chk2 2
  seed_slow_check "$state" chk3 2
  out="$dir/out"
  start=$(date +%s)
  watch_bg "$state" "$fakebin" "$out" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=30
  pid=$!
  n=$(count_beat_advances "$state" "$pid" 150)
  elapsed=$(( $(date +%s) - start ))
  reap "$pid"
  [ "$n" -ge 3 ] \
    || fail "expected at least 3 distinct beacon advances (one per check in the sweep) within ${elapsed}s, got $n"
  [ -s "$out" ] && fail "three quiet checks alone must not produce a wake, got: $(cat "$out")"
  pass "beacon advances at least once per check inside the sweep, $n advances in ${elapsed}s"
}

# Seed <count> pending-reply records in <state>, each delivered and then
# resolved by its correlated parent report, through the production library.
seed_resolved_pending_replies() {  # <home> <state> <count>
  (
    # shellcheck source=bin/fm-pending-reply-lib.sh
    . "$ROOT/bin/fm-pending-reply-lib.sh"
    home=$1 state=$2 count=$3 i=0
    while [ "$i" -lt "$count" ]; do
      corr=$(fm_pending_reply_create "$home" "$state" mate "request $i") || exit 1
      fm_pending_reply_mark_delivered "$state" "$corr" || exit 1
      printf 'done [corr=%s]: complete\n' "$corr" >> "$state/mate.status"
      fm_pending_reply_try_resolve "$state" "$corr" || exit 1
      i=$((i + 1))
    done
  ) || fail "could not seed resolved pending-reply records"
}

# test_beacon_advances_with_many_resolved_pending_replies: pending-reply
# records are retained after they resolve, so a long-lived home carries
# hundreds, and the watcher's pending-reply tick visits every one each cycle.
# The incident shape: under host load each subprocess is slow, and the tick
# spent several of them (plus a lock) per already-resolved record, freezing the
# beacon for the whole walk before any other phase could beat. The slow `cut`
# fake stands in for that load on the record-field reads; a settled record must
# cost none, so cycles keep turning over and the beacon keeps advancing.
test_beacon_advances_with_many_resolved_pending_replies() {
  local dir state fakebin out pid start elapsed n real_cut
  dir=$(make_case beacon-resolved-pending-replies); state="$dir/state"; fakebin="$dir/fakebin"
  seed_resolved_pending_replies "$dir" "$state" 25
  # The reports that resolved the records are history, not a fresh signal.
  rm -f "$state/mate.status"
  real_cut=$(command -v cut) || fail "cut is not available"
  printf '#!/usr/bin/env bash\nsleep 0.2\nexec %q "$@"\n' "$real_cut" > "$fakebin/cut"
  chmod +x "$fakebin/cut"
  out="$dir/out"
  start=$(date +%s)
  watch_bg "$state" "$fakebin" "$out" FM_CHECK_INTERVAL=999999
  pid=$!
  n=$(count_beat_advances "$state" "$pid" 150)
  elapsed=$(( $(date +%s) - start ))
  reap "$pid"
  [ "$n" -ge 4 ] \
    || fail "expected at least 4 distinct beacon advances across cycles with 25 resolved pending-reply records within ${elapsed}s, got $n; the tick is paying per-record cost for settled records"
  [ -s "$out" ] && fail "resolved pending-reply records alone must not produce a wake, got: $(cat "$out")"
  pass "beacon keeps advancing with 25 resolved pending-reply records under slow subprocesses, $n advances in ${elapsed}s"
}

test_beacon_advances_promptly_when_herdr_capture_hangs
test_beacon_advances_between_checks_in_the_sweep
test_beacon_advances_with_many_resolved_pending_replies

echo "fm-watch-beacon tests passed"
