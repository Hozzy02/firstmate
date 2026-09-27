#!/usr/bin/env bash
# Exercise the task transition ledger through its executable writer and a
# read-only JSON consumer, including replay after a lost cursor update.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-events)
STATE_DIR="$TMP_ROOT/state"
mkdir -p "$STATE_DIR"
STATUS="$STATE_DIR/task-one.status"
LEDGER="$STATE_DIR/events.ndjson"

capture() {
  FM_STATE_OVERRIDE="$STATE_DIR" "$ROOT/bin/fm-events.sh" capture
}

cat > "$STATUS" <<'EOF'
working [at=1790000100]: implementation started
needs-decision [key=api] [at=1790000110]: choose API
resolved [key=api] [at=1790000150]: REST chosen
done [at=1790000200]: PR https://example.test/acme/repo/pull/8 checks green
EOF
printf 'paused [at=1790000210]: waiting on release' >> "$STATUS"
capture || fail 'initial transition capture failed'
assert_equals 4 "$(wc -l < "$LEDGER" | tr -d ' ')" 'complete lines captured'

before=$(shasum -a 256 "$LEDGER" | awk '{print $1}')
summary=$(jq -s -c '
  {task: .[0].task,
   duration: (.[-1].ts - .[0].ts),
   captain_wait: ((map(select(.state == "resolved"))[0].ts) - (map(select(.state == "needs-decision"))[0].ts)),
   pr: (map(select(.line | contains("checks green")))[0].line | split("PR ")[1] | split(" ")[0])}
' "$LEDGER") || fail 'read-only consumer failed'
assert_equals '{"task":"task-one","duration":100,"captain_wait":40,"pr":"https://example.test/acme/repo/pull/8"}' "$summary" 'read-only duration consumer'
after=$(shasum -a 256 "$LEDGER" | awk '{print $1}')
assert_equals "$before" "$after" 'consumer did not mutate the ledger'
jq -e -s 'length == 4 and (map(.id) | unique | length) == 4 and all(.[]; .time_source == "status" and (.ts | type) == "number")' "$LEDGER" >/dev/null \
  || fail 'the records lack stable ids or source times'

capture || fail 'repeated capture failed'
printf '0\n' > "$STATE_DIR/.task-one.events-cursor"
capture || fail 'replay after cursor loss failed'
assert_equals 4 "$(wc -l < "$LEDGER" | tr -d ' ')" 'retry and restart replay deduplication'

printf '\nlegacy line without a source stamp\n' >> "$STATUS"
capture || fail 'completion of the partial line failed'
assert_equals 6 "$(wc -l < "$LEDGER" | tr -d ' ')" 'partial line and legacy line captured once complete'
jq -e -s '.[4].state == "paused" and .[4].ts == 1790000210 and .[5].time_source == "capture" and (.[5].ts | type) == "number"' "$LEDGER" >/dev/null \
  || fail 'partial or legacy line time attribution is wrong'

rm "$STATUS"
printf 'working [at=1790000300]: reused task id\n' > "$STATUS"
capture || fail 'task-id reuse capture failed'
assert_equals 7 "$(wc -l < "$LEDGER" | tr -d ' ')" 'reused task id has a new event identity'

FM_STATE_OVERRIDE="$STATE_DIR" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  . "$1/bin/fm-classify-lib.sh"
  status_retire_presentation_task "$2" task-one
' _ "$ROOT" "$STATE_DIR" || fail 'task retirement failed'
[ ! -e "$STATE_DIR/.task-one.events-cursor" ] || fail 'task retirement left the events cursor for a reused id'
printf 'working [at=1790000400]: second reuse\n' > "$STATUS"
capture || fail 'post-retirement capture failed'
assert_equals 8 "$(wc -l < "$LEDGER" | tr -d ' ')" 'retired task id starts capture from the first line'

PR=https://example.test/acme/repo/pull/8
FM_STATE_OVERRIDE="$STATE_DIR" "$ROOT/bin/fm-events.sh" pr_ready task-one "$PR" || fail 'PR registration event failed'
FM_STATE_OVERRIDE="$STATE_DIR" "$ROOT/bin/fm-events.sh" merged task-one "$PR" || fail 'PR merge event failed'
FM_STATE_OVERRIDE="$STATE_DIR" "$ROOT/bin/fm-events.sh" merged task-one "$PR" || fail 'repeated PR merge event failed'
assert_equals 10 "$(wc -l < "$LEDGER" | tr -d ' ')" 'one record per PR event'
jq -e -s --arg pr "$PR" '
  (map(select(.event == "task.pr_ready" and .pr == $pr)) | length) == 1 and
  (map(select(.event == "task.merged" and .pr == $pr)) | length) == 1 and
  ((map(select(.event == "task.merged"))[0].ts - map(select(.event == "task.pr_ready"))[0].ts) >= 0)
' "$LEDGER" >/dev/null || fail 'read-only PR cycle consumer failed'
pass 'source times, read-only durations, PR cycle, partial lines, replay, and task-id reuse'
