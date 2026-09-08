# shellcheck shell=bash
# Durable per-task-id dispatch restriction record. Single owner of the
# storage format and the read/write/list mechanics shared by
# bin/fm-dispatch-restrict.sh (set/list/lift) and bin/fm-spawn.sh's ship/scout
# dispatch gate.
#
# A restriction is one regular file at
# <data-dir>/dispatch-restrictions/<task-id>. Its presence alone means the
# task id is restricted; nothing else (task completion, teardown, tasks-axi
# hold/done/reopen, manual backlog edits, re-queueing) touches this
# directory, so a restriction set here is independent of - and survives -
# every ordinary backlog and task lifecycle event, including the tasks-axi
# hold flag that AGENTS.md notes gets cleared on completion. Only
# fm_dispatch_restrict_lift (bin/fm-dispatch-restrict.sh lift) removes it.
#
# Record format, one `key=value` line per field, read with fm_meta_get
# (bin/fm-backend.sh), the same convention state/<id>.meta already uses:
#   by=<who authorized the restriction, e.g. "captain">
#   at=<ISO 8601 UTC timestamp the restriction was set>
#   reason=<single-line free-text reason>
#
# Usage: . bin/fm-dispatch-restrict-lib.sh
#   fm_dispatch_restrict_active <data-dir> <task-id>   - 0 if restricted, sets
#     FM_DISPATCH_RESTRICT_BY / _AT / _REASON; 1 and clears them otherwise.
#   fm_dispatch_restrict_write <data-dir> <task-id> <by> <at> <reason>
#     - atomically creates or overwrites the record.
#   fm_dispatch_restrict_lift <data-dir> <task-id>     - removes the record;
#     1 if there was nothing to lift.
#   fm_dispatch_restrict_list <data-dir>               - prints one
#     "<task-id>\tby=...\tat=...\treason=..." line per active restriction,
#     sorted by task id.

SCRIPT_DIR_FM_DISPATCH_RESTRICT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR_FM_DISPATCH_RESTRICT/fm-backend.sh"

fm_dispatch_restrict_dir() {  # <data-dir>
  printf '%s/dispatch-restrictions\n' "$1"
}

fm_dispatch_restrict_path() {  # <data-dir> <task-id>
  printf '%s/%s\n' "$(fm_dispatch_restrict_dir "$1")" "$2"
}

fm_dispatch_restrict_active() {  # <data-dir> <task-id>
  local data_dir=$1 id=$2 path
  FM_DISPATCH_RESTRICT_BY=
  FM_DISPATCH_RESTRICT_AT=
  FM_DISPATCH_RESTRICT_REASON=
  path=$(fm_dispatch_restrict_path "$data_dir" "$id")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  FM_DISPATCH_RESTRICT_BY=$(fm_meta_get "$path" by)
  FM_DISPATCH_RESTRICT_AT=$(fm_meta_get "$path" at)
  FM_DISPATCH_RESTRICT_REASON=$(fm_meta_get "$path" reason)
  return 0
}

fm_dispatch_restrict_write() {  # <data-dir> <task-id> <by> <at> <reason>
  local data_dir=$1 id=$2 by=$3 at=$4 reason=$5 dir path tmp
  dir=$(fm_dispatch_restrict_dir "$data_dir")
  mkdir -p "$dir" || return 1
  path=$(fm_dispatch_restrict_path "$data_dir" "$id")
  tmp="$path.tmp.$$"
  {
    printf 'by=%s\n' "$by"
    printf 'at=%s\n' "$at"
    printf 'reason=%s\n' "$reason"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

fm_dispatch_restrict_lift() {  # <data-dir> <task-id>
  local data_dir=$1 id=$2 path
  path=$(fm_dispatch_restrict_path "$data_dir" "$id")
  [ -e "$path" ] || [ -L "$path" ] || return 1
  rm -f -- "$path"
}

fm_dispatch_restrict_list() {  # <data-dir>
  local data_dir=$1 dir entry id
  dir=$(fm_dispatch_restrict_dir "$data_dir")
  [ -d "$dir" ] || return 0
  for entry in "$dir"/*; do
    [ -f "$entry" ] && [ ! -L "$entry" ] || continue
    id=$(basename "$entry")
    fm_dispatch_restrict_active "$data_dir" "$id" || continue
    printf '%s\tby=%s\tat=%s\treason=%s\n' \
      "$id" "$FM_DISPATCH_RESTRICT_BY" "$FM_DISPATCH_RESTRICT_AT" "$FM_DISPATCH_RESTRICT_REASON"
  done | sort
}
