#!/usr/bin/env bash
# fm-events.sh - project complete task status lines into state/events.ndjson.
#
# docs/events.md owns the record contract. This writer accepts `capture` for
# every task log, `appended <absolute-status-file>` for one log, or a recorded
# PR event with a task id and full URL.
# The worker command calls appended after its unchanged status-file append;
# the watcher calls capture to recover other writers and missed calls.
# A per-file identity and byte cursor avoid rescanning settled lines. The event
# id is derived from task, file identity, byte position, and line bytes, so a
# retry after the ledger append but before cursor replacement writes no duplicate.
# Both paths hold state/.events.lock while checking ids, appending, and saving
# cursors. A partial final line waits for its terminating newline.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

case "${1:-}:$#" in
  capture:1) ;;
  appended:2)
    case "$2" in /*/*.status) ;; *) exit 2 ;; esac
    STATE=${2%/*}
    ;;
  pr_ready:3|merged:3) ;;
  *) echo 'usage: fm-events.sh capture | appended <absolute-status-file> | pr_ready|merged <task> <PR URL>' >&2; exit 2 ;;
esac
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1
FM_STATE_OVERRIDE=$STATE

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh" || exit 1
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh" || exit 1

LEDGER="$STATE/events.ndjson"
LOCK="$STATE/.events.lock"
[ ! -L "$LEDGER" ] || exit 1

task_ok() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
case "$1" in
  pr_ready|merged) task_ok "$2" && [ -n "$3" ] || exit 2 ;;
esac

digest() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

record_line() { # <task> <identity> <byte-position> <status-line>
  local task=$1 identity=$2 position=$3 line=$4 id verb key epoch source json
  id=$(printf '%s\0%s\0%s\0%s' "$task" "$identity" "$position" "$line" | digest) || return 1
  case "$id" in *[!0-9a-f]*|'') return 1 ;; esac
  if [ -f "$LEDGER" ] && grep -Fq '"id":"'"$id"'"' "$LEDGER"; then
    return 0
  fi
  if epoch=$(status_line_at_epoch "$line"); then
    source=status
  else
    epoch=$(date -u +%s) || return 1
    source=capture
  fi
  status_line_verb "$line" verb
  case "$verb" in [a-z]*) case "$verb" in *[!a-z-]*) verb='' ;; esac ;; *) verb='' ;; esac
  key=$(_fm_decision_key "$line" 2>/dev/null) || key=''
  [ "$key" != default ] || key=''
  json=$(jq -cn --arg id "$id" --arg task "$task" --arg line "$line" \
    --arg state "$verb" --arg key "$key" --arg source "$source" --argjson ts "$epoch" \
    '{v:1,id:$id,event:"task.status",task:$task,ts:$ts,time_source:$source,state:(if $state == "" then null else $state end),key:(if $key == "" then null else $key end),line:$line}') || return 1
  printf '%s\n' "$json" >> "$LEDGER"
}

record_pr() { # <pr_ready|merged> <task> <full-URL>
  local event=$1 task=$2 url=$3 id epoch json
  id=$(printf '%s\0%s\0%s' "$event" "$task" "$url" | digest) || return 1
  case "$id" in *[!0-9a-f]*|'') return 1 ;; esac
  if [ -f "$LEDGER" ] && grep -Fq '"id":"'"$id"'"' "$LEDGER"; then
    return 0
  fi
  epoch=$(date -u +%s) || return 1
  json=$(jq -cn --arg id "$id" --arg task "$task" --arg event "task.$event" \
    --arg pr "$url" --argjson ts "$epoch" \
    '{v:1,id:$id,event:$event,task:$task,ts:$ts,time_source:"recorded",pr:$pr}') || return 1
  printf '%s\n' "$json" >> "$LEDGER"
}

capture_task() { # <status-file>; caller holds the lock
  local file=$1 task identity cursor saved_ident saved_offset=0 size data tail complete line position tmp
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  task=${file##*/}
  task=${task%.status}
  task_ok "$task" || return 0
  identity=$(_fm_open_decisions_file_ident "$file") || return 1
  size=$(_fm_status_file_size "$file") || return 1
  cursor="$STATE/.$task.events-cursor"
  if [ -f "$cursor" ] && [ ! -L "$cursor" ]; then
    IFS=$'\t' read -r saved_ident saved_offset < "$cursor" || :
    case "$saved_offset" in ''|*[!0-9]*) saved_offset=0 ;; esac
    [ "$saved_ident" = "$identity" ] && [ "$size" -ge "$saved_offset" ] || saved_offset=0
  fi
  [ "$size" -gt "$saved_offset" ] || return 0
  data=$(tail -c "+$((saved_offset + 1))" "$file"; printf x) || return 1
  data=${data%x}
  tail=${data##*$'\n'}
  complete=${data%"$tail"}
  [ -n "$complete" ] || return 0
  position=$saved_offset
  while IFS= read -r line; do
    if [ -n "${line//[[:space:]]/}" ]; then
      record_line "$task" "$identity" "$position" "$line" || return 1
    fi
    position=$((position + ${#line} + 1))
  done <<< "${complete%$'\n'}"
  tmp=$(mktemp "$STATE/.$task.events-cursor.tmp.XXXXXX") || return 1
  if ! printf '%s\t%s\n' "$identity" "$position" > "$tmp" || ! mv -f "$tmp" "$cursor"; then
    rm -f "$tmp"
    return 1
  fi
}

fm_lock_acquire_wait "$LOCK" || exit 1
trap 'fm_lock_release "$LOCK"' EXIT
rc=0
if [ "$1" = appended ]; then
  capture_task "$2" || rc=1
elif [ "$1" = pr_ready ] || [ "$1" = merged ]; then
  capture_task "$STATE/$2.status" || rc=1
  [ "$rc" -ne 0 ] || record_pr "$1" "$2" "$3" || rc=1
else
  for file in "$STATE"/*.status; do
    capture_task "$file" || rc=1
  done
fi
[ "$rc" -eq 0 ] || echo 'fm-events: some status transitions were not recorded' >&2
exit "$rc"
