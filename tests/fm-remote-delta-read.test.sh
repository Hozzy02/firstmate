#!/usr/bin/env bash
# Behavior tests for bin/fm-remote-delta-read.sh, the append-only reply-log
# reader a remote lane runs as its preemptible long poll.
#
# Pins, through the executable interface:
#   * the delta schema: offsets, prefix and payload hashes, and payload bytes
#   * every continuity-break reason: truncated, prefix-changed, missing, and
#     line-exceeds-bound, plus an unsafe symlink or traversal target
#   * an incomplete tail line is withheld until a newline completes it
#   * exit 75 when the wait window closes with nothing appended
#   * the per-poll executable boundary: an unchanged log costs one stat per
#     sample, and the bounded capture/hashing path runs only when the file's
#     stat identity changed - a same-size in-place rewrite still breaks the
#     continuity hash, so statting cheaper never hides a change.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-delta-read)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
DELTA_HOME="$TMP_ROOT/home"
DELTA_LOG_REL=state/replies.status
mkdir -p "$DELTA_HOME/state"
READER="$ROOT/bin/fm-remote-delta-read.sh"

EMPTY_SHA=$(: | shasum -a 256 | awk '{print $1}')
sha() { printf '%b' "$1" | shasum -a 256 | awk '{print $1}'; }

run_reader() { # <offset> <prefix> <wait> [rel]
  FM_HOME="$DELTA_HOME" FM_REMOTE_DELTA_POLL_SECONDS=0.05 \
    "$READER" "${4:-$DELTA_LOG_REL}" "$1" "$2" "$3"
}

# A growing log returns the complete appended lines with exact boundaries.
: > "$DELTA_HOME/$DELTA_LOG_REL"
run_reader 0 "$EMPTY_SHA" 4 > "$TMP_ROOT/growth.out" &
READER_PID=$!
sleep 0.3
printf 'first line\n' >> "$DELTA_HOME/$DELTA_LOG_REL"
wait "$READER_PID" || fail "a delta on growth did not exit 0"
OUT=$(<"$TMP_ROOT/growth.out")
assert_contains "$OUT" 'status=delta' 'the grown log did not produce a delta'
assert_contains "$OUT" 'from_offset=0' 'the delta did not start at the caller cursor'
assert_contains "$OUT" 'to_offset=11' 'the delta did not stop at the complete line'
assert_contains "$OUT" "from_prefix_sha256=$EMPTY_SHA" 'the delta did not echo the caller prefix hash'
assert_contains "$OUT" 'payload_sha256='"$(sha 'first line\n')" 'the payload hash is not the appended bytes'
assert_contains "$OUT" 'payload_bytes=11' 'the payload byte count is wrong'
[ "$(tail -n 1 "$TMP_ROOT/growth.out")" = 'first line' ] || fail 'the delta did not carry the appended line'
pass 'an appended line produces a delta with exact offsets, hashes, and payload'

# An unchanged log exits 75 when the window closes and never repeats the
# snapshot path: one stat per sample is the whole per-poll cost.
DELTA_SHIM="$TMP_ROOT/delta-shim"
EXEC_LOG="$TMP_ROOT/delta-execs"
mkdir -p "$DELTA_SHIM"
for TOOL in perl shasum sha256sum od tail head wc tr date stat dirname basename; do
  REAL=$(PATH=/usr/bin:/bin command -v "$TOOL" 2>/dev/null || true)
  [ -n "$REAL" ] || continue
  if [ "$TOOL" = perl ]; then
    cat > "$DELTA_SHIM/$TOOL" <<SH
#!/bin/sh
printf '%s\n' perl >> "\$FM_TEST_EXEC_LOG"
"$REAL" "\$@"
rc=\$?
if [ "\$rc" -eq 0 ] && [ -n "\${FM_TEST_SNAPSHOT_DONE:-}" ]; then
  : > "\$FM_TEST_SNAPSHOT_DONE"
fi
exit "\$rc"
SH
    chmod +x "$DELTA_SHIM/$TOOL"
    continue
  fi
  cat > "$DELTA_SHIM/$TOOL" <<SH
#!/bin/sh
printf '%s\n' $TOOL >> "\$FM_TEST_EXEC_LOG"
exec $REAL "\$@"
SH
  chmod +x "$DELTA_SHIM/$TOOL"
done
# Model a same-second stat key without depending on how soon a loaded runner
# schedules the rewrite. The real size, inode, and device still come from the
# file; only the fractional mtime and ctime vary with the fixture contents.
REAL_STAT=$(PATH=/usr/bin:/bin command -v stat)
cat > "$DELTA_SHIM/stat" <<SH
#!/bin/sh
printf '%s\n' stat >> "\$FM_TEST_EXEC_LOG"
if [ -n "\${FM_TEST_SAME_SECOND_LOG:-}" ] && [ "\${3:-}" = "\$FM_TEST_SAME_SECOND_LOG" ]; then
  /usr/bin/perl -e '
    my \$path = shift;
    my @s = stat(\$path) or exit 1;
    open my \$fh, "<", \$path or exit 1;
    read(\$fh, my \$prefix, 5) == 5 or exit 1;
    my \$fraction = \$prefix eq "OMEGA" ? "200000000" : "100000000";
    print "\$s[7]:2000000000.\$fraction:2000000000.\$fraction:\$s[1]:\$s[0]\\n";
  ' "\$FM_TEST_SAME_SECOND_LOG"
  exit \$?
fi
exec "$REAL_STAT" "\$@"
SH
chmod +x "$DELTA_SHIM/stat"
: > "$EXEC_LOG"
: > "$DELTA_HOME/$DELTA_LOG_REL"
FM_TEST_EXEC_LOG="$EXEC_LOG" PATH="$DELTA_SHIM:/usr/bin:/bin" \
  FM_HOME="$DELTA_HOME" FM_REMOTE_DELTA_POLL_SECONDS=0.05 \
  "$READER" "$DELTA_LOG_REL" 0 "$EMPTY_SHA" 60 > /dev/null &
READER_PID=$!
# The capability probe and two gate stats show a repeated unchanged poll.
# End the reader only after observing that state, rather than hoping a fixed
# wait window admits enough polls under load.
for _ in $(seq 1 6000); do
  [ "$(grep -cx stat "$EXEC_LOG" || true)" -ge 3 ] && break
  kill -0 "$READER_PID" 2>/dev/null || break
  sleep 0.01
done
kill -TERM "$READER_PID" 2>/dev/null || true
RC=0
wait "$READER_PID" || RC=$?
[ "${RC:-0}" -eq 75 ] || fail "an unchanged log closed its window with $RC instead of 75"
perl_execs=$(grep -cx perl "$EXEC_LOG" || true)
stat_execs=$(grep -cx stat "$EXEC_LOG" || true)
# The first poll always takes one snapshot: it must validate the caller's
# cursor prefix before waiting. The gate only suppresses the repeats.
[ "$perl_execs" -eq 1 ] || fail "an unchanged log ran the bounded capture $perl_execs times"
for TOOL in od tail head wc date; do
  hits=$(grep -cx "$TOOL" "$EXEC_LOG" || true)
  [ "$hits" -eq 0 ] || fail "an unchanged log ran $TOOL $hits times in the poll loop"
done
# One capability probe plus at least two gate stats proves the unchanged gate
# ran again without recapturing or hashing the file.
[ "$stat_execs" -ge 3 ] || fail "the unchanged window did not keep polling stat ($stat_execs)"
run_reader 0 "$EMPTY_SHA" 1 > /dev/null && \
  fail 'an unchanged log did not exit 75 at the window' || RC=$?
[ "$RC" -eq 75 ] || fail "an unchanged log closed its window with $RC instead of 75"
pass 'an unchanged log costs one stat per poll and exits 75 at the window'

# Growth still pays the capture and hashing tools exactly when bytes appear.
: > "$EXEC_LOG"
FM_TEST_EXEC_LOG="$EXEC_LOG" PATH="$DELTA_SHIM:/usr/bin:/bin" run_reader 0 "$EMPTY_SHA" 4 > "$TMP_ROOT/growth2.out" &
READER_PID=$!
sleep 0.3
printf 'counted change\n' >> "$DELTA_HOME/$DELTA_LOG_REL"
wait "$READER_PID" || fail 'the shimmed growth run did not exit 0'
assert_contains "$(<"$TMP_ROOT/growth2.out")" 'status=delta' 'the shimmed run lost the delta'
[ "$(grep -cx perl "$EXEC_LOG" || true)" -ge 1 ] || fail 'growth did not run the bounded capture'
[ "$(grep -cx shasum "$EXEC_LOG" || true)" -ge 2 ] || fail 'growth did not hash prefix and payload'
pass 'the capture and hashing path runs exactly once a real change lands'

# A shrunk file reports the truncation with the hash of what actually remains.
printf 'alpha\nbeta\n' > "$DELTA_HOME/$DELTA_LOG_REL"
PREFIX_SHA=$(sha 'alpha\nbeta\n')
run_reader 11 "$PREFIX_SHA" 4 > "$TMP_ROOT/truncated.out" &
READER_PID=$!
sleep 0.3
printf 'a\n' > "$DELTA_HOME/$DELTA_LOG_REL"
wait "$READER_PID" || fail 'the truncated read did not exit 0'
OUT=$(<"$TMP_ROOT/truncated.out")
assert_contains "$OUT" 'status=continuity-broken' 'truncation did not produce a break'
assert_contains "$OUT" 'reason=truncated' 'truncation was not named'
assert_contains "$OUT" 'to_offset=2' 'the break did not report the shrunk size'
assert_contains "$OUT" "to_prefix_sha256=$(sha 'a\n')" 'the break did not hash the remaining prefix'
pass 'a shrunk log breaks continuity as truncated with the remaining hash'

# A same-size in-place rewrite changes only mtime/ctime: the stat gate must
# still take the snapshot, where the prefix hash catches the changed bytes.
# This rewrite lands in a later epoch second.
printf 'alpha\nbeta\n' > "$DELTA_HOME/$DELTA_LOG_REL"
run_reader 11 "$PREFIX_SHA" 4 > "$TMP_ROOT/rewrite.out" &
READER_PID=$!
sleep 1.1
printf 'OMEGA\nbeta\n' > "$DELTA_HOME/$DELTA_LOG_REL"
wait "$READER_PID" || fail 'the rewritten read did not exit 0'
OUT=$(<"$TMP_ROOT/rewrite.out")
assert_contains "$OUT" 'status=continuity-broken' 'a same-size rewrite did not produce a break'
assert_contains "$OUT" 'reason=prefix-changed' 'the same-size rewrite was not named prefix-changed'
assert_contains "$OUT" 'to_offset=11' 'the break did not report the current size'
pass 'a same-size in-place rewrite breaks continuity as prefix-changed'

# A same-size rewrite of the same inode has equal whole-second timestamps in
# the modeled stat response. Wait for the first snapshot to finish before
# rewriting, so the next poll must notice only the changed subsecond fields.
printf 'alpha\nbeta\n' > "$DELTA_HOME/$DELTA_LOG_REL"
SNAPSHOT_DONE="$TMP_ROOT/same-second-snapshot-done"
: > "$EXEC_LOG"
FM_TEST_EXEC_LOG="$EXEC_LOG" FM_TEST_SNAPSHOT_DONE="$SNAPSHOT_DONE" \
  FM_TEST_SAME_SECOND_LOG="$DELTA_HOME/$DELTA_LOG_REL" \
  PATH="$DELTA_SHIM:/usr/bin:/bin" run_reader 11 "$PREFIX_SHA" 60 \
  > "$TMP_ROOT/same-second.out" &
READER_PID=$!
for _ in $(seq 1 6000); do
  [ -e "$SNAPSHOT_DONE" ] && break
  kill -0 "$READER_PID" 2>/dev/null || break
  sleep 0.01
done
if [ ! -e "$SNAPSHOT_DONE" ]; then
  kill -TERM "$READER_PID" 2>/dev/null || true
  wait "$READER_PID" 2>/dev/null || true
  fail 'the first same-second snapshot did not finish'
fi
printf 'OMEGA\nbeta\n' > "$DELTA_HOME/$DELTA_LOG_REL"
wait "$READER_PID" || fail 'the same-second rewrite read did not exit 0'
OUT=$(<"$TMP_ROOT/same-second.out")
assert_contains "$OUT" 'reason=prefix-changed' 'a same-second same-size rewrite was not detected'
pass 'a same-second same-size rewrite of the same inode breaks continuity'

# A log that disappears mid-wait breaks as missing only for a nonzero cursor.
printf 'alpha\nbeta\n' > "$DELTA_HOME/$DELTA_LOG_REL"
run_reader 11 "$PREFIX_SHA" 4 > "$TMP_ROOT/missing.out" &
READER_PID=$!
sleep 0.3
rm -f -- "$DELTA_HOME/$DELTA_LOG_REL"
wait "$READER_PID" || fail 'the missing-file read did not exit 0'
OUT=$(<"$TMP_ROOT/missing.out")
assert_contains "$OUT" 'status=continuity-broken' 'a removed log did not produce a break'
assert_contains "$OUT" 'reason=missing' 'the removed log was not named missing'
pass 'a removed log breaks continuity as missing'

# A removed log is not a break for a cursor at the origin: it keeps waiting,
# which is what a first poll against a not-yet-created log relies on.
run_reader 0 "$EMPTY_SHA" 1 > /dev/null && fail 'a missing log at offset 0 did not wait' || RC=$?
[ "${RC:-0}" -eq 75 ] || fail "a missing log at offset 0 exited $RC instead of 75"
pass 'a missing log at the origin cursor keeps waiting until the window closes'

# An incomplete tail line is withheld until its newline lands, then delivered
# whole rather than as a fragment.
printf 'whole\n' > "$DELTA_HOME/$DELTA_LOG_REL"
run_reader 6 "$(sha 'whole\n')" 4 > "$TMP_ROOT/partial.out" &
READER_PID=$!
sleep 0.3
printf 'frag' >> "$DELTA_HOME/$DELTA_LOG_REL"
sleep 0.4
printf -- '-ment\n' >> "$DELTA_HOME/$DELTA_LOG_REL"
wait "$READER_PID" || fail 'the completed line did not exit 0'
OUT=$(<"$TMP_ROOT/partial.out")
assert_contains "$OUT" 'status=delta' 'the completed line did not produce a delta'
assert_contains "$OUT" 'to_offset=16' 'the delta did not stop at the completed line'
assert_contains "$OUT" 'payload_bytes=10' 'the payload did not carry the whole line'
[ "$(tail -n 1 "$TMP_ROOT/partial.out")" = 'frag-ment' ] || fail 'the payload did not join the fragment'
pass 'an unterminated tail is withheld until the newline completes it'

# The same continuity rules apply to the schema's other break and refusal
# surfaces, with the wait window never entered.
printf 'past-bound tail' > "$DELTA_HOME/$DELTA_LOG_REL"
FM_HOME="$DELTA_HOME" FM_REMOTE_DELTA_MAX_BYTES=8 \
  run_reader 0 "$EMPTY_SHA" 1 > "$TMP_ROOT/bound.out" || fail 'the bound break did not exit 0'
assert_contains "$(<"$TMP_ROOT/bound.out")" 'reason=line-exceeds-bound' \
  'a tail line longer than the payload bound did not break'
run_reader 0 "$EMPTY_SHA" 1 '../outside' > /dev/null 2>&1 && \
  fail 'a traversing path was accepted' || true
printf 'real\n' > "$DELTA_HOME/state/real.status"
ln -sfn real.status "$DELTA_HOME/state/link.status"
run_reader 0 "$EMPTY_SHA" 1 'state/link.status' > /dev/null 2>&1 && \
  fail 'a symlinked log was accepted' || true
pass 'the reader refuses traversal, symlinks, and oversized tail lines'

printf 'delta-read contract tests complete\n'
