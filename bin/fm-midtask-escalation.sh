#!/usr/bin/env bash
# fm-midtask-escalation.sh - suggest moving one task up a model class, from
# signals firstmate already has, so a struggling worker gets noticed without
# a person watching every task by hand.
#
# Usage:
#   fm-midtask-escalation.sh check <task-id>    print one suggestion line when
#                                                due, nothing otherwise
#   fm-midtask-escalation.sh arm <task-id>      write and register
#                                                state/midtask-<task-id>.check.sh
#   fm-midtask-escalation.sh disarm <task-id>   remove the shim, its trust
#                                                binding, and the rate-limit
#                                                record
#   fm-midtask-escalation.sh --help
#
# `check` composes with the existing watcher state-check contract
# (bin/fm-check-register.sh, AGENTS.md section 2): it prints one line when
# firstmate should wake and nothing otherwise, so `arm` registers it once per
# task and the watcher dispatches it on its normal FM_CHECK_INTERVAL cadence.
# The registered id is `midtask-<task-id>`, never the bare task id, because
# state/<task-id>.check.sh is already the merge-poll shim's own path
# (bin/fm-pr-check.sh): reusing that exact path for a second, unrelated check
# would let one clobber the other on any task that ever gets both.
#
# This never relaunches, edits, or steers anything. bin/fm-control.sh <id>
# relaunch --harness --model --effort --note is the one relaunch path, and
# only firstmate decides to run it, with values it chooses. The suggestion
# names the task, the evidence, the ready-to-run
# relaunch command, and - when TypeSafe Jev resolves one - a concrete
# profile to fill that command's flags with.
#
# Evidence, deliberately drawn only from signals that are already public:
#   - bin/fm-crew-state.sh's one authoritative current-state line.
#   - no-mistakes fix-round counts for the task's own branch, read the same
#     way bin/fm-crew-state.sh itself selects a run (bin/fm-nm-run-lib.sh's
#     fm_nm_select_run) and then from `no-mistakes stats --agents --run`,
#     whose ROUND column is the only place a fix-round count is exposed.
#   - the task's own state/<id>.status log: how many `blocked:` reports it
#     has appended since its last `resolved:`/`done:`/`failed:` line (its own
#     worker rules already require appending `blocked:` on a repeated
#     obstacle), and how long ago its last event was stamped.
# This script never reads the watcher's own stale/wedge bookkeeping
# (state/.wedge-escalations-*, state/.stale-since-*, and the rest of that
# family). AGENTS.md section 2 reserves those to their owning scripts, and
# their key is a backend window identity that is not guaranteed to equal the
# task id, so a second reader would be guessing at a private, unstable
# format instead of reusing a real interface.
#
# Suggest up (struggling) when ANY of
#     - no-mistakes used FM_MIDTASK_ROUND_THRESHOLD (default 3) or more fix
#       rounds on any step of its selected run (no-mistakes chains up to
#       three rounds per step, so reaching the threshold means the chain the
#       gate allows is spent)
#     - the status log carries FM_MIDTASK_BLOCKED_THRESHOLD (default 2) or
#       more `blocked:` reports since its last resolved/done/failed event
#     - the last status event is FM_MIDTASK_STALL_SECONDS (default 1800)
#       seconds old or older while bin/fm-crew-state.sh reports blocked or
#       failed (parked waits on the captain and unknown means the tooling
#       cannot see the worker, so neither is read as a struggle)
# Otherwise `check` prints nothing. There is no down suggestion: no existing
# state tells a task that proved simpler apart from an ordinary healthy one,
# so that direction is deferred until such a signal exists.
#
# Rate limiting: state/.midtask-escalation-<task-id> records the evidence
# signature behind the last suggestion this printed, built only from the
# triggers that actually fired. A `check` run whose signature has not changed
# since prints nothing, so a task stuck in the same state is reported once,
# not on every poll; a new blocked report, a higher fix-round count, or
# another stall interval elapsing on a firing stall is new evidence and earns
# a fresh suggestion, while drift in evidence that did not fire does not.
#
# Optional target profile: when TYPESAFE_API_KEY is set - in the
# environment, or in FM_HOME/.env, the same opt-in bin/fm-dispatch-resolve.sh
# already reads - `check` asks that exact script to resolve a profile for a
# brief it synthesizes describing the move, instead of reimplementing its
# opt-in gate or its typesafe.ai call. Only a `clear` result's `profile:`
# line is used; an unset key, no configured rules, an ambiguous or escalated
# answer, or a network/API error all leave the suggestion with no profile,
# exactly as fm-dispatch-resolve.sh's other callers already treat those
# outcomes.
#
# Out of scope (left to firstmate's judgment and to other work): automatic
# relaunch, quota-policy changes, and skill/harness routing rules.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

CREW_STATE_BIN="${FM_MIDTASK_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
DISPATCH_RESOLVE_BIN="${FM_MIDTASK_DISPATCH_RESOLVE_BIN:-$SCRIPT_DIR/fm-dispatch-resolve.sh}"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() { printf 'fm-midtask-escalation: %s\n' "$1" >&2; exit 2; }

# Checked inline rather than through a command substitution: die's exit would
# only end that subshell, leaving the caller's assignment empty instead of
# stopping the script.
require_positive_int() { case "$2" in ''|*[!0-9]*|0) die "$1 must be a whole positive number" ;; esac; }

ROUND_THRESHOLD=${FM_MIDTASK_ROUND_THRESHOLD:-3}
require_positive_int FM_MIDTASK_ROUND_THRESHOLD "$ROUND_THRESHOLD"
BLOCKED_THRESHOLD=${FM_MIDTASK_BLOCKED_THRESHOLD:-2}
require_positive_int FM_MIDTASK_BLOCKED_THRESHOLD "$BLOCKED_THRESHOLD"
STALL_THRESHOLD=${FM_MIDTASK_STALL_SECONDS:-1800}
require_positive_int FM_MIDTASK_STALL_SECONDS "$STALL_THRESHOLD"
NM_TIMEOUT=${FM_MIDTASK_NM_TIMEOUT:-10}
require_positive_int FM_MIDTASK_NM_TIMEOUT "$NM_TIMEOUT"

check_id_for() { printf 'midtask-%s\n' "$1"; }  # <task-id> -> registered check id

# --- evidence gathering -----------------------------------------------------

# Sets ROUNDS_USED (highest ROUND any step needed, or empty when unknown) and
# NM_RUN_ID (the selected run it was read from). Never fails the caller: any
# unreadable step just leaves ROUNDS_USED empty.
nm_evidence() {  # <worktree> <branch>
  ROUNDS_USED=''
  NM_RUN_ID=''
  local worktree=$1 branch=$2 overview choice selected_id detail stats round
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 0
  [ -n "$branch" ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  overview=$(fm_nm_run_checked "$worktree" "$NM_TIMEOUT" axi) || return 0
  [ -n "$overview" ] || return 0
  choice=$(fm_nm_select_run "$branch" "$overview" "$worktree" "$NM_TIMEOUT")
  case "$choice" in selected\|*) ;; *) return 0 ;; esac
  IFS='|' read -r _ selected_id _ _ <<<"$choice"
  [ -n "$selected_id" ] || return 0
  detail=$(fm_nm_run_checked "$worktree" "$NM_TIMEOUT" axi status --run "$selected_id") || return 0
  [ "$(fm_nm_field "$detail" branch)" = "$branch" ] || return 0
  stats=$(fm_nm_run_checked "$worktree" "$NM_TIMEOUT" stats --agents --run "$selected_id") || return 0
  round=$(printf '%s\n' "$stats" \
    | awk '$1 ~ /^(intent|rebase|review|test|document|lint|push|pr|ci)$/ && $2 ~ /^[0-9]+$/ {print $2}' \
    | sort -n | tail -1)
  case "$round" in ''|*[!0-9]*) ;; *) ROUNDS_USED=$round; NM_RUN_ID=$selected_id ;; esac
}

# Sets BLOCKED_COUNT (blocked: reports since the last resolved:/done:/failed:
# event), BLOCKED_LINE (the status-log line number of the latest of those
# reports, so a later episode reaching the same count is told apart), and
# STALL_SECONDS (age of the last event's [at=] stamp, empty when unknown).
status_evidence() {  # <status-file>
  BLOCKED_COUNT=0
  BLOCKED_LINE=0
  STALL_SECONDS=''
  local file=$1 line verb epoch last_epoch='' n=0
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      [ -n "$line" ] || continue
      verb=$(status_line_verb "$line")
      if epoch=$(status_line_at_epoch "$line" 2>/dev/null); then
        last_epoch=$epoch
      fi
      case "$verb" in
        blocked) BLOCKED_COUNT=$((BLOCKED_COUNT + 1)); BLOCKED_LINE=$n ;;
        resolved|done|failed) BLOCKED_COUNT=0 ;;
      esac
    done < "$file"
  fi
  if [ -n "$last_epoch" ]; then
    local now
    now=$(date +%s) || return 0
    STALL_SECONDS=$((now - last_epoch))
    [ "$STALL_SECONDS" -ge 0 ] || STALL_SECONDS=0
  fi
}

crew_state_word() {  # <task-id> -> state word, or "unknown"
  local line
  line=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_NO_FORGE=1 \
    "$CREW_STATE_BIN" "$1" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'unknown'; return ;; esac
  line=${line#state: }
  printf '%s' "${line%% *}"
}

# --- decision ----------------------------------------------------------------

# Sets REASON (empty when no up move is due) and TRIGGERS (the evidence
# values of only the rules that fired, for the rate-limit signature).
decide() {  # <crew-state>
  local crew_state=$1
  REASON=''
  TRIGGERS=''
  local reasons=() triggers=() joined

  if [ -n "$ROUNDS_USED" ] && [ "$ROUNDS_USED" -ge "$ROUND_THRESHOLD" ]; then
    reasons+=("no-mistakes used $ROUNDS_USED fix round(s) on a step (cap ~$ROUND_THRESHOLD)")
    triggers+=("rounds=$ROUNDS_USED@$NM_RUN_ID")
  fi
  if [ "$BLOCKED_COUNT" -ge "$BLOCKED_THRESHOLD" ]; then
    reasons+=("reported blocked $BLOCKED_COUNT time(s) since its last resolved/done event")
    triggers+=("blocked=$BLOCKED_COUNT@line$BLOCKED_LINE")
  fi
  if [ -n "$STALL_SECONDS" ] && [ "$STALL_SECONDS" -ge "$STALL_THRESHOLD" ]; then
    case "$crew_state" in
      blocked|failed)
        reasons+=("no status update for ${STALL_SECONDS}s while state=$crew_state")
        triggers+=("stall_bucket=$((STALL_SECONDS / STALL_THRESHOLD))")
        ;;
    esac
  fi

  [ "${#reasons[@]}" -gt 0 ] || return 0
  joined=$(printf '%s; ' "${reasons[@]}")
  REASON=${joined%; }
  TRIGGERS=${triggers[*]}
}

# --- optional TypeSafe Jev profile --------------------------------------------

# Prints a "--harness ... [--model ...] [--effort ...]" line on stdout when
# fm-dispatch-resolve.sh resolves one for the synthesized up move; prints
# nothing otherwise (off, no rules, ambiguous, escalate, or error). Never
# fails the caller.
jev_profile() {  # <id> <harness> <model> <effort> <project> <reason>
  local id=$1 harness=$2 model=$3 effort=$4 project=$5 reason=$6
  [ -x "$DISPATCH_RESOLVE_BIN" ] || return 0
  local tmp out status line
  tmp=$(mktemp 2>/dev/null) || return 0
  {
    printf '## Captain'"'"'s intent\n'
    printf 'Mid-task escalation: move task %s up a model class because %s.\n' \
      "$id" "$reason"
    printf '\n## Firstmate spec\n'
    printf 'Task %s currently runs harness=%s model=%s effort=%s. Pick the configured dispatch profile that best fits moving it up a model class from there.\n' \
      "$id" "${harness:-unknown}" "${model:-default}" "${effort:-default}"
  } > "$tmp"
  out=$(FM_HOME="$FM_HOME" "$DISPATCH_RESOLVE_BIN" "$tmp" --project "$project" 2>/dev/null)
  rm -f -- "$tmp"
  status=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1)
  [ "$status" = clear ] || return 0
  line=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*profile:[[:space:]]*//p' | head -1)
  [ -n "$line" ] || return 0
  printf '%s' "$line"
}

# --- check -------------------------------------------------------------------

action_check() {
  local id=$1 meta status_file worktree branch harness model effort kind project
  fm_pr_task_id_valid "$id" || die "invalid task id: $id"
  meta="$STATE/$id.meta"
  status_file="$STATE/$id.status"
  [ -f "$meta" ] || return 0
  kind=$(fm_meta_get "$meta" kind)
  [ "$kind" != secondmate ] || return 0
  worktree=$(fm_meta_get "$meta" worktree)
  branch=$(fm_meta_get "$meta" branch)
  harness=$(fm_meta_get "$meta" harness)
  model=$(fm_meta_get "$meta" model)
  effort=$(fm_meta_get "$meta" effort)
  project=$(fm_meta_get "$meta" project)
  project=$(basename "${project:-$id}")

  local crew_state
  crew_state=$(crew_state_word "$id")

  nm_evidence "$worktree" "$branch"
  status_evidence "$status_file"
  decide "$crew_state"
  [ -n "$REASON" ] || return 0

  local signature=$TRIGGERS

  local record="$STATE/.midtask-escalation-$id" prev=''
  [ -f "$record" ] && prev=$(cat "$record" 2>/dev/null)
  [ "$signature" != "$prev" ] || return 0

  local profile
  profile=$(jev_profile "$id" "$harness" "$model" "$effort" "$project" "$REASON")

  local relaunch_cmd="bin/fm-control.sh $id relaunch"
  [ -z "$profile" ] || relaunch_cmd="$relaunch_cmd $profile"
  relaunch_cmd="$relaunch_cmd --note \"mid-task escalation: $REASON\""

  printf 'midtask-escalation: %s suggests moving up a model class (current %s:%s:%s) - %s - relaunch: %s\n' \
    "$id" "${harness:--}" "${model:--}" "${effort:--}" "$REASON" "$relaunch_cmd"

  local tmp
  tmp=$(umask 077; mktemp "$STATE/.fm-midtask-escalation.XXXXXX" 2>/dev/null) || return 0
  if printf '%s' "$signature" > "$tmp" && chmod 0600 "$tmp"; then
    mv -f -- "$tmp" "$record" || rm -f -- "$tmp"
  else
    rm -f -- "$tmp"
  fi
}

# --- arm / disarm --------------------------------------------------------------

shim_content() {  # <task-id> <home>
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-midtask-escalation.sh - per-task mid-task escalation poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$2")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-midtask-escalation.sh") check $(printf '%q' "$1")"
}

action_arm() {
  local id=$1 check_id shim trust home want device
  fm_pr_task_id_valid "$id" || die "invalid task id: $id"
  [ -f "$STATE/$id.meta" ] || die "no recorded task: $id"
  [ "$(fm_meta_get "$STATE/$id.meta" kind)" != secondmate ] || die "a secondmate is never watched: $id"
  check_id=$(check_id_for "$id")
  shim="$STATE/$check_id.check.sh"
  trust="$STATE/$check_id.check-trust"
  mkdir -p "$STATE" || die "could not create $STATE"
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "cannot resolve FM_HOME $FM_HOME" ;;
  esac
  device=$(fm_pr_file_device "$STATE") || die "state directory is unavailable"
  fm_pr_regular_destination_on_device_or_absent "$shim" "$device" \
    || die "custom check path is unavailable: state/$check_id.check.sh"
  want=$(shim_content "$id" "$home")
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.fm-midtask-escalation-check.XXXXXX" 2>/dev/null) || die "mktemp failed"
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    die "could not write state/$check_id.check.sh"
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$shim" "$device" || ! mv -f -- "$tmp" "$shim"; then
    rm -f -- "$tmp"
    die "could not install state/$check_id.check.sh"
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$check_id" >/dev/null; then
    rm -f -- "$shim" "$trust"
    die "could not register state/$check_id.check.sh"
  fi
  printf 'armed: state/%s.check.sh (task %s)\n' "$check_id" "$id"
}

action_disarm() {
  local id=$1 check_id
  fm_pr_task_id_valid "$id" || die "invalid task id: $id"
  check_id=$(check_id_for "$id")
  rm -f -- "$STATE/$check_id.check.sh" "$STATE/$check_id.check-trust" "$STATE/.midtask-escalation-$id"
  printf 'disarmed: state/%s.check.sh (task %s)\n' "$check_id" "$id"
}

# --- entry ---------------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -eq 2 ] || die "usage: fm-midtask-escalation.sh {check|arm|disarm} <task-id>"
case "$1" in
  check) action_check "$2" ;;
  arm) action_arm "$2" ;;
  disarm) action_disarm "$2" ;;
  *) die "unknown action: $1" ;;
esac
