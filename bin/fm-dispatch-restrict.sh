#!/usr/bin/env bash
# Set, list, or lift a durable dispatch restriction on a task id, so a
# captain instruction to keep a specific task queued and never dispatched is
# enforced by bin/fm-spawn.sh itself rather than depending on an agent
# remembering to check escalation history.
#
# Usage:
#   fm-dispatch-restrict.sh set <task-id> --reason <text> --by <who>
#   fm-dispatch-restrict.sh list
#   fm-dispatch-restrict.sh lift <task-id>
#
# `set` requires both --reason and --by so the refusal fm-spawn.sh later
# prints can always name who authorized the restriction and why; it
# overwrites an existing record for the same id (re-running set is itself a
# deliberate act). `list` prints one line per active restriction:
#   <task-id>\tby=<who>\tat=<timestamp>\treason=<reason>
# `lift` is the ONLY thing that removes a restriction; it is refused when the
# id is not currently restricted. Nothing else - task completion, teardown,
# tasks-axi hold/done/reopen, manual backlog edits, re-queueing - clears a
# restriction, which is the whole point (see bin/fm-dispatch-restrict-lib.sh
# for the storage contract and bin/fm-spawn.sh for the enforcement gate).
#
# Operates on the CURRENT home ($FM_HOME / the FM_*_OVERRIDE vars, exactly
# like every other bin/fm-*.sh script), so it reaches whichever home will
# actually dispatch the task: run it directly (optionally with an explicit
# FM_HOME=<secondmate-home>) for a LOCAL secondmate, or through
# `bin/fm-on.sh <secondmate-id> fm-dispatch-restrict.sh ...` for a REMOTE
# one - fm-on.sh already runs any bin/fm-*.sh script in a remote secondmate's
# home, so this needs no new cross-home channel of its own.
set -u

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-dispatch-restrict-lib.sh
. "$SCRIPT_DIR/fm-dispatch-restrict-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

CMD=${1:-}
case "$CMD" in
  set|list|lift) shift ;;
  '') echo "error: missing subcommand" >&2; usage >&2; exit 2 ;;
  *) echo "error: unknown subcommand '$CMD'" >&2; usage >&2; exit 2 ;;
esac

RESTRICT_LOCK="$STATE/.dispatch-restrictions.lock"

case "$CMD" in
  list)
    [ "$#" -eq 0 ] || { echo "error: list takes no arguments" >&2; exit 2; }
    fm_dispatch_restrict_list "$DATA"
    exit 0
    ;;
  set)
    ID=${1:-}
    shift || true
    REASON=
    BY=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reason) REASON=${2:-}; shift 2 || { echo "error: --reason requires a value" >&2; exit 2; } ;;
        --by) BY=${2:-}; shift 2 || { echo "error: --by requires a value" >&2; exit 2; } ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    fm_task_id_path_safe "$ID" || { echo "error: invalid task id" >&2; exit 2; }
    [ -n "$REASON" ] || { echo "error: set requires --reason <text>" >&2; exit 2; }
    [ -n "$BY" ] || { echo "error: set requires --by <who authorized this>" >&2; exit 2; }
    case "$REASON" in *$'\n'*) echo "error: --reason must be single-line" >&2; exit 2 ;; esac
    case "$BY" in *$'\n'*) echo "error: --by must be single-line" >&2; exit 2 ;; esac
    mkdir -p "$STATE" || { echo "error: could not create state directory" >&2; exit 1; }
    fm_lock_acquire_wait "$RESTRICT_LOCK"
    AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if fm_dispatch_restrict_write "$DATA" "$ID" "$BY" "$AT" "$REASON"; then
      fm_lock_release "$RESTRICT_LOCK" || true
      printf 'restricted %s (by=%s at=%s reason=%s)\n' "$ID" "$BY" "$AT" "$REASON"
      exit 0
    fi
    fm_lock_release "$RESTRICT_LOCK" || true
    echo "error: could not write dispatch restriction for $ID" >&2
    exit 1
    ;;
  lift)
    ID=${1:-}
    shift || true
    [ "$#" -eq 0 ] || { echo "error: lift takes exactly one task id" >&2; exit 2; }
    fm_task_id_path_safe "$ID" || { echo "error: invalid task id" >&2; exit 2; }
    fm_lock_acquire_wait "$RESTRICT_LOCK"
    if fm_dispatch_restrict_active "$DATA" "$ID"; then
      if fm_dispatch_restrict_lift "$DATA" "$ID"; then
        fm_lock_release "$RESTRICT_LOCK" || true
        printf 'lifted %s\n' "$ID"
        exit 0
      fi
      fm_lock_release "$RESTRICT_LOCK" || true
      echo "error: could not lift dispatch restriction for $ID" >&2
      exit 1
    fi
    fm_lock_release "$RESTRICT_LOCK" || true
    echo "error: $ID is not currently restricted; nothing to lift" >&2
    exit 1
    ;;
esac
