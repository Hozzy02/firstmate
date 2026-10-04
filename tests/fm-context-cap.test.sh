#!/usr/bin/env bash
# bin/fm-context-cap.sh: the turn-end size record, the cap, and what one tick
# does about an over-cap conversation.
#
# Real processes, no harness. The record path runs the real command as a child
# of a fake harness (a bash symlink named "claude") whose pid holds the fixture
# home's session lock, the shape tests/fm-claude-stop-autoarm.test.sh uses. The
# second-mate restart is observed through a recording stand-in for
# bin/fm-secondmate-restart.sh in a copied bin/, so the test pins what the tick
# asks for and how it reports the outcome, not the restart itself
# (tests/fm-secondmate-restart.test.sh owns that).
# The primary reset's terminal half is harness-dependent and is proven by
# tests/fm-context-cap-live-e2e.test.sh.
# shellcheck disable=SC2016 # single quotes are deliberate: variables expand inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-context-cap)
fm_git_identity fmtest fmtest@example.invalid
CAP="$ROOT/bin/fm-context-cap.sh"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
unset FM_CONTEXT_CAP_TOKENS FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

make_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  : > "$dir/AGENTS.md"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
}

# One Claude transcript whose main conversation's latest request re-sent
# <tokens> tokens, followed by a larger sidechain request and non-JSON noise
# that must both be ignored.
write_transcript() {  # <file> <tokens>
  local file=$1 tokens=$2
  {
    printf '{"type":"user","message":{"role":"user","content":"hi"}}\n'
    printf '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":7,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":999999}}}\n'
    printf '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":%s,"output_tokens":888888}}}\n' "$((tokens - 105))"
    printf '{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":900000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}\n'
    printf 'not json at all\n'
  } > "$file"
}

# Run `record --claude` as the lock-owning session of <home>.
record_as_owner() {  # <home> <transcript> <session-id>
  local home=$1 payload
  payload=$(printf '{"session_id":"%s","transcript_path":"%s","hook_event_name":"Stop"}' "$3" "$2")
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" CAP_CMD="$CAP" PAYLOAD="$payload" \
    "$FAKE_CLAUDE" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; printf "%s" "$PAYLOAD" | "$CAP_CMD" record --claude'
}

status_of() {  # <home> [args]
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$CAP" status "$@" 2>&1
}

# --- the record --------------------------------------------------------------

HOME1="$TMP_ROOT/home1"
make_home "$HOME1"
TRANSCRIPT="$TMP_ROOT/t1.jsonl"

out=$(status_of "$HOME1")
[ "$out" = "context-cap: subject=primary cap=150000 tokens=unknown verdict=unknown" ] \
  || fail "a home with no record reads unknown at the default cap: $out"
pass "no record reads unknown at the default 150000 cap"

write_transcript "$TRANSCRIPT" 90000
record_as_owner "$HOME1" "$TRANSCRIPT" sess-a
out=$(status_of "$HOME1")
[ "$out" = "context-cap: subject=primary cap=150000 tokens=90000 verdict=under" ] \
  || fail "the latest main-conversation request's input side is the recorded size: $out"
pass "record measures the latest main-conversation request, ignoring output, sidechain, and noise"

write_transcript "$TRANSCRIPT" 180000
record_as_owner "$HOME1" "$TRANSCRIPT" sess-a
out=$(status_of "$HOME1")
[ "$out" = "context-cap: subject=primary cap=150000 tokens=180000 verdict=over" ] \
  || fail "a size at or past the cap reads over: $out"
pass "a recorded size past the cap reads over"

# A record whose lock no longer matches the home's session lock is another
# process's leftover.
echo 1 > "$HOME1/state/.lock"
out=$(status_of "$HOME1")
case "$out" in *"verdict=unknown") ;; *) fail "a record from a previous lock owner must read unknown: $out" ;; esac
pass "a record left by a previous lock owner reads unknown"

# A session that does not own the lock records nothing.
HOME2="$TMP_ROOT/home2"
make_home "$HOME2"
echo 1 > "$HOME2/state/.lock"
printf '{"session_id":"sess-x","transcript_path":"%s"}' "$TRANSCRIPT" \
  | FM_ROOT_OVERRIDE="$HOME2" FM_HOME="$HOME2" "$CAP" record --claude
[ ! -e "$HOME2/state/.context-size" ] || fail "a session that does not own the lock recorded a size"
pass "a session that does not own the session lock records nothing"

# A transcript with no usage entry leaves the earlier record alone.
# Both records run in one owning process, so the lock the first one stamped is
# still the home's lock when the verdict is read.
printf '{"type":"user"}\n' > "$TMP_ROOT/empty.jsonl"
FM_ROOT_OVERRIDE="$HOME1" FM_HOME="$HOME1" CAP_CMD="$CAP" T1="$TRANSCRIPT" T2="$TMP_ROOT/empty.jsonl" \
  "$FAKE_CLAUDE" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    for t in "$T1" "$T2"; do
      printf "{\"session_id\":\"sess-a\",\"transcript_path\":\"%s\"}" "$t" | "$CAP_CMD" record --claude
    done'
out=$(status_of "$HOME1")
case "$out" in *"tokens=180000 verdict=over") ;; *) fail "an unmeasurable transcript must not overwrite the record: $out" ;; esac
pass "an unmeasurable transcript records nothing"

# --- the cap -----------------------------------------------------------------

echo 200000 > "$HOME1/config/context-cap"
out=$(status_of "$HOME1")
case "$out" in *"cap=200000 tokens=180000 verdict=under") ;; *) fail "config/context-cap sets the cap: $out" ;; esac
echo off > "$HOME1/config/context-cap"
out=$(status_of "$HOME1")
case "$out" in *"cap=off tokens=unknown verdict=off") ;; *) fail "off disables the policy: $out" ;; esac
out=$(FM_CONTEXT_CAP_TOKENS=1000 status_of "$HOME1")
case "$out" in *"cap=1000 tokens=180000 verdict=over") ;; *) fail "the environment overrides the file: $out" ;; esac
echo "150k" > "$HOME1/config/context-cap"
if out=$(status_of "$HOME1"); then fail "an unusable cap must be an error, got: $out"; fi
case "$out" in *"positive integer token count or 'off'"*) ;; *) fail "the cap error must say what is accepted: $out" ;; esac
pass "the cap comes from config/context-cap, the environment overrides it, off disables it, and a bad value is an error"

# A bad cap restarts nothing and queues nothing.
out=$(FM_ROOT_OVERRIDE="$HOME1" FM_HOME="$HOME1" "$CAP" tick 2>/dev/null)
[ -z "$out" ] && [ ! -s "$HOME1/state/.wake-queue" ] || fail "a tick under an unusable cap must do nothing: $out"
pass "a tick under an unusable cap does nothing"
rm -f "$HOME1/config/context-cap"

# --- the primary tick --------------------------------------------------------

tick() {  # <home>
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "${2:-$CAP}" tick 2>&1
}

# While an away record exists the primary is not asked, and the ask is not
# spent: it is made once the record clears.
: > "$HOME1/state/.afk-contract"
out=$(tick "$HOME1")
[ -z "$out" ] && [ ! -s "$HOME1/state/.wake-queue" ] || fail "an away home's primary must not be asked to reset: $out"
rm -f "$HOME1/state/.afk-contract"
pass "an away or quiet record defers the primary ask without spending it"

# sess-a's first recorded size was under the cap, so it is restartable.
out=$(tick "$HOME1")
case "$out" in
  "check: context-cap primary conversation is at 180000 tokens, over the 150000-token cap"*"restart-primary --persisted"*) ;;
  *) fail "an over-cap primary must be asked to persist and restart: $out" ;;
esac
grep -Fq "context-cap-primary-sess-a" "$HOME1/state/.wake-queue" || fail "the primary wake row was not queued"
pass "an over-cap primary gets one persist-and-restart wake"

out=$(tick "$HOME1")
[ -z "$out" ] || fail "the same over-cap session must be acted on once: $out"
[ "$(grep -c "context-cap-primary" "$HOME1/state/.wake-queue")" -eq 1 ] || fail "a second tick queued a second row"
pass "the same session is not asked twice"

# A new session whose first size is already past the cap cannot be helped.
: > "$HOME1/state/.wake-queue"
record_as_owner "$HOME1" "$TRANSCRIPT" sess-b
out=$(tick "$HOME1")
case "$out" in
  "check: context-cap primary conversation already started at 180000 tokens, too close to the 150000-token cap"*"nothing was restarted") ;;
  *) fail "a session that starts past the cap must be reported, not restarted: $out" ;;
esac
out=$(tick "$HOME1")
[ -z "$out" ] || fail "the floor report must not repeat: $out"
pass "a session that starts at or past the cap is reported once and never restarted"

# So is one that starts under the cap but within a fifth of it, where every
# restart would buy almost nothing.
: > "$HOME1/state/.wake-queue"
write_transcript "$TRANSCRIPT" 130000
record_as_owner "$HOME1" "$TRANSCRIPT" sess-c
write_transcript "$TRANSCRIPT" 180000
record_as_owner "$HOME1" "$TRANSCRIPT" sess-c
out=$(tick "$HOME1")
case "$out" in
  "check: context-cap primary conversation already started at 130000 tokens, too close to the 150000-token cap"*) ;;
  *) fail "a session that starts within a fifth of the cap must be reported, not restarted: $out" ;;
esac
pass "a session that starts within a fifth of the cap is reported, not restarted"

# Session opens that do not restore the conversation drop the record.
FM_ROOT_OVERRIDE="$HOME1" FM_HOME="$HOME1" "$CAP" reset
out=$(status_of "$HOME1")
case "$out" in *"verdict=unknown") ;; *) fail "reset must drop the record: $out" ;; esac
pass "reset drops the record"

out=$(FM_ROOT_OVERRIDE="$HOME1" FM_HOME="$HOME1" "$CAP" restart-primary 2>&1) && fail "restart-primary without --persisted must refuse"
case "$out" in *"requires --persisted"*) ;; *) fail "the refusal must name the attestation: $out" ;; esac
pass "restart-primary refuses without the persistence attestation"

# --- the second-mate tick ----------------------------------------------------

# A parent home with a copied bin/ whose restart command is a recorder, and one
# local second mate whose own home holds the size record.
PARENT="$TMP_ROOT/parent"
make_home "$PARENT"
cp "$ROOT"/bin/*.sh "$PARENT/bin/"
mkdir -p "$PARENT/bin/backends"
cp "$ROOT"/bin/backends/*.sh "$PARENT/bin/backends/"
cat > "$PARENT/bin/fm-secondmate-restart.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/state/restart-calls"
[ ! -e "$FM_HOME/state/restart-fails" ] || { echo "unreached: $3: it did not confirm that its open work is written down"; exit 3; }
echo "restarted: $3 (claude)"
SH
chmod +x "$PARENT/bin/fm-secondmate-restart.sh"
PCAP="$PARENT/bin/fm-context-cap.sh"

MATE="$TMP_ROOT/mate"
make_home "$MATE"
echo alpha > "$MATE/.fm-secondmate-home"
printf 'kind=secondmate\nhome=%s\nwindow=fm-alpha\nharness=claude\n' "$MATE" > "$PARENT/state/alpha.meta"
# A ship in the same home must never be considered.
printf 'kind=ship\nwindow=fm-ship\nharness=claude\n' > "$PARENT/state/ship1.meta"

wait_for_file_text() {  # <file> <text>
  local i=0
  while [ "$i" -lt 100 ]; do
    grep -Fq -- "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

write_transcript "$TRANSCRIPT" 60000
record_as_owner "$MATE" "$TRANSCRIPT" mate-1
out=$(tick "$PARENT" "$PCAP")
[ -z "$out" ] && [ ! -e "$PARENT/state/restart-calls" ] || fail "an under-cap second mate must be left alone: $out"
pass "an under-cap second mate is left alone"

out=$(FM_ROOT_OVERRIDE="$PARENT" FM_HOME="$PARENT" "$PCAP" status alpha 2>&1)
[ "$out" = "context-cap: subject=alpha cap=150000 tokens=60000 verdict=under" ] || fail "status names a second mate's size: $out"
pass "status reads a local second mate's size from its own home"

write_transcript "$TRANSCRIPT" 170000
record_as_owner "$MATE" "$TRANSCRIPT" mate-1
out=$(tick "$PARENT" "$PCAP")
[ -z "$out" ] || fail "a clean second-mate restart must queue no wake: $out"
wait_for_file_text "$PARENT/state/restart-calls" "--reason context-cap alpha" \
  || fail "the tick did not start the persist-gated restart for the over-cap mate"
wait_for_file_text "$PARENT/state/.context-cap-secondmate-alpha" "state=restarted" \
  || fail "a clean restart was not recorded"
[ ! -s "$PARENT/state/.wake-queue" ] || fail "a clean restart must not wake the parent: $(cat "$PARENT/state/.wake-queue")"
pass "an over-cap second mate is restarted through the persist-gated restart, silently"

tick "$PARENT" "$PCAP" >/dev/null
sleep 0.5
[ "$(wc -l < "$PARENT/state/restart-calls" | tr -d ' ')" -eq 1 ] || fail "the same session was restarted twice"
pass "the same second-mate session is not restarted twice"

# A restart worker that died without an outcome leaves a `restarting` marker;
# once it is old the session is decided again instead of being left over the cap.
printf 'session=mate-1 state=restarting ts=1000\n' > "$PARENT/state/.context-cap-secondmate-alpha"
tick "$PARENT" "$PCAP" >/dev/null
wait_for_file_text "$PARENT/state/.context-cap-secondmate-alpha" "state=restarted" \
  || fail "an abandoned restart was never retried"
[ "$(wc -l < "$PARENT/state/restart-calls" | tr -d ' ')" -eq 2 ] || fail "an abandoned restart must be retried exactly once"
: > "$PARENT/state/restart-calls"
pass "a restart abandoned without an outcome is retried once its marker is stale"

# While a liveness episode holds the mate, the pass stands aside and decides
# again later.
mkdir "$PARENT/state/.secondmate-liveness-alpha.lock"
printf '%s\n' "$$" > "$PARENT/state/.secondmate-liveness-alpha.lock/pid"
rm -f "$PARENT/state/.context-cap-secondmate-alpha"
tick "$PARENT" "$PCAP" >/dev/null
i=0
while [ "$i" -lt 50 ] && [ -e "$PARENT/state/.context-cap-secondmate-alpha" ]; do sleep 0.1; i=$((i + 1)); done
[ ! -e "$PARENT/state/.context-cap-secondmate-alpha" ] && [ ! -s "$PARENT/state/restart-calls" ] \
  || fail "the pass restarted a mate a liveness episode was holding"
rm -rf "$PARENT/state/.secondmate-liveness-alpha.lock"
pass "a mate held by a liveness episode is left for a later tick"

# A restart that does not happen wakes the parent once with the reason.
: > "$PARENT/state/restart-fails"
record_as_owner "$MATE" "$TRANSCRIPT" mate-2
write_transcript "$TRANSCRIPT" 20000
record_as_owner "$MATE" "$TRANSCRIPT" mate-3
write_transcript "$TRANSCRIPT" 170000
record_as_owner "$MATE" "$TRANSCRIPT" mate-3
tick "$PARENT" "$PCAP" >/dev/null
wait_for_file_text "$PARENT/state/.wake-queue" \
  "check: secondmate alpha context-cap restart not completed: it did not confirm that its open work is written down" \
  || fail "a failed restart did not queue its wake: $(cat "$PARENT/state/.wake-queue" 2>/dev/null)"
wait_for_file_text "$PARENT/state/.context-cap-secondmate-alpha" "state=failed" || fail "a failed restart was not recorded"
pass "a second mate that was not restarted wakes the parent once with the reason"

# A second mate's own home never acts on its own primary.
out=$(tick "$MATE")
[ -z "$out" ] && [ ! -s "$MATE/state/.wake-queue" ] || fail "a second mate's home acted on its own primary: $out"
pass "a second mate's own home leaves its restart to its parent"

# A remote mate, and a home that does not carry the mate's marker, are skipped.
: > "$PARENT/state/restart-calls"
rm -f "$PARENT/state/restart-fails" "$PARENT/state/.context-cap-secondmate-alpha"
printf 'kind=secondmate\nhome=%s\nwindow=fm-alpha\nharness=claude\nremote_host=elsewhere\n' "$MATE" > "$PARENT/state/alpha.meta"
tick "$PARENT" "$PCAP" >/dev/null
printf 'kind=secondmate\nhome=%s\nwindow=fm-alpha\nharness=claude\n' "$MATE" > "$PARENT/state/alpha.meta"
echo other > "$MATE/.fm-secondmate-home"
tick "$PARENT" "$PCAP" >/dev/null
sleep 0.5
[ ! -s "$PARENT/state/restart-calls" ] || fail "a remote or unproven second-mate home was restarted"
pass "a remote second mate and an unproven home are skipped"

echo '# all fm-context-cap tests passed'
