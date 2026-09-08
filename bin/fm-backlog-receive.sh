#!/usr/bin/env bash
# Receive one delivered remote-secondmate outbox into this home's backlog.
#
# Usage:
#   fm-backlog-receive.sh state/handoff/<secondmate-id>.outbox.md <bytes> <sha256> <generation>
#   < dispatch-restriction-payload
#
# The delivered file must be a non-symlink backlog-format scratch file confined
# to FM_HOME/state/handoff. Every item must be Queued. Keys already present in
# data/backlog.md are skipped; every remaining key moves in one dependency-closed
# `tasks-axi mv` transaction under tasks-axi's own locks. On an ambiguous caller
# retry, destination-present classification makes this operation idempotent.
#
# The dispatch-restriction payload on stdin is `FM-DISPATCH-RESTRICTIONS 1`, then
# one `present\t<task-id>\t<base64 record>` line per RESTRICTED delivered id, then
# `FM-DISPATCH-RESTRICTIONS-END`. Absent ids are simply not listed, so a handoff
# never lifts a restriction this home already holds; the terminator is what
# distinguishes "not restricted" from a truncated payload.
#
# If tasks-axi reports a lock failure, this host may remove and retry once only
# for its own backlog or delivered lock whose pid is dead and whose mtime is at
# least 30 seconds old. No live or uncertain lock is touched. On confirmed
# receipt the delivered scratch file is removed; no other path is deletable.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DEST="$FM_HOME/data/backlog.md"
LOCK_STALE_SECS=30

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

base64_decode_to() { # <encoded> <destination>
  local encoded=$1 destination=$2
  if printf '%s' "$encoded" | base64 --decode > "$destination" 2>/dev/null; then return 0; fi
  if printf '%s' "$encoded" | base64 -D > "$destination" 2>/dev/null; then return 0; fi
  return 1
}

base64_encode_file() { # <file>
  base64 < "$1" | tr -d '\n'
}

backlog_key_section() { # <file> <key>
  awk -v key="$2" '
    BEGIN { section = "## Queued" }
    /^##[[:space:]]+/ { section=$0; sub(/^##[[:space:]]+/, "## ", section); sub(/[[:space:]]+$/, "", section); next }
    /^- \[[ x]\] / {
      rest=$0; sub(/^- \[[ x]\] +/, "", rest); id=rest; sub(/[ \t].*/, "", id)
      if (id == key) { print section; found=1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

list_keys() { # <file>
  awk '
    /^- \[[ x]\] / {
      rest=$0; sub(/^- \[[ x]\] +/, "", rest); id=rest; sub(/[ \t].*/, "", id)
      if (id != "" && !seen[id]++) print id
    }
  ' "$1"
}

lock_age() {
  local modified now
  if [ "$(uname 2>/dev/null)" = Darwin ]; then
    modified=$(stat -f '%m' "$1" 2>/dev/null) || return 1
  else
    modified=$(stat -c '%Y' "$1" 2>/dev/null) || return 1
  fi
  now=$(date +%s) || return 1
  case "$modified$now" in *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((now - modified))"
}

remove_dead_stale_lock() { # <lock-path>
  local lock=$1 token pid age
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  IFS= read -r token < "$lock" || return 1
  pid=${token%%:*}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && return 1
  age=$(lock_age "$lock") || return 1
  [ "$age" -ge "$LOCK_STALE_SECS" ] || return 1
  rm -f -- "$lock"
}

run_move() { # <keys...>
  tasks-axi mv "$@" --file "$DELIVERED" --to "$DEST"
}

[ "$#" -eq 4 ] || usage
REL=$1
EXPECTED_BYTES=$2
EXPECTED_HASH=$3
GENERATION=$4
case "$EXPECTED_BYTES" in ''|*[!0-9]*) die "expected bytes must be a nonnegative integer" ;; esac
[ "${#EXPECTED_BYTES}" -le 10 ] || die "expected bytes are outside the supported range"
[ "$EXPECTED_BYTES" -le 1048576 ] || die "expected bytes are outside the supported range"
case "$EXPECTED_HASH" in ''|*[!A-Fa-f0-9]*) die "expected SHA-256 is invalid" ;; esac
[ "${#EXPECTED_HASH}" -eq 64 ] || die "expected SHA-256 has the wrong length"
EXPECTED_HASH=$(printf '%s' "$EXPECTED_HASH" | tr 'A-F' 'a-f')
case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
[ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"
case "$REL" in state/handoff/*.outbox.md) ;; *) die "delivered outbox path is outside state/handoff: $REL" ;; esac
case "/$REL/" in */../*|*/./*) die "delivered outbox path contains traversal" ;; esac
case "$REL" in *'//'*) die "delivered outbox path is malformed" ;; esac
[ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
  || die "FM_HOME is not a seeded secondmate home"
[ -f "$FM_HOME/AGENTS.md" ] && [ -d "$FM_HOME/bin" ] || die "FM_HOME is not a Firstmate home"
HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME cannot be resolved"
PARENT=$(dirname "$FM_HOME/$REL")
PARENT_REAL=$(CDPATH='' cd -- "$PARENT" 2>/dev/null && pwd -P) || die "delivered outbox parent is unavailable"
case "$PARENT_REAL" in "$HOME_REAL/state/handoff") ;; *) die "delivered outbox escapes the remote scratch directory" ;; esac
DELIVERED="$PARENT_REAL/$(basename "$REL")"
NAME=$(basename "$REL")
ID=${NAME%.outbox.md}
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "delivered outbox id is unsafe" ;; esac
TRANSFER_LOCK="$PARENT_REAL/.$ID.upload.lock"
fm_lock_acquire_wait "$TRANSFER_LOCK" || die "cannot lock delivered outbox"
RESTRICTION_STAGE=$(umask 077; mktemp -d "$PARENT_REAL/.restrictions.XXXXXX") \
  || die "cannot stage dispatch restrictions"
cleanup_receive() {
  local lock
  for lock in "${ACTIVE_TASK_LOCKS[@]}"; do
    [ -n "$lock" ] || continue
    fm_lock_release "$lock" || true
  done
  rm -rf -- "$RESTRICTION_STAGE"
  fm_lock_release "$TRANSFER_LOCK" || true
}
ACTIVE_TASK_LOCKS=("")
trap cleanup_receive EXIT
[ -f "$DELIVERED" ] && [ ! -L "$DELIVERED" ] || die "delivered outbox is not a non-symlink regular file"
GENERATION_FILE="$PARENT_REAL/.$ID.upload-generation"
[ -f "$GENERATION_FILE" ] && [ ! -L "$GENERATION_FILE" ] || die "delivered outbox generation is unavailable or unsafe"
{
  IFS= read -r STORED_GENERATION \
    && IFS= read -r STORED_BYTES \
    && IFS= read -r STORED_HASH \
    && ! IFS= read -r
} < "$GENERATION_FILE" || die "delivered outbox generation is malformed"
case "$STORED_GENERATION" in ''|*[!0-9]*) die "delivered outbox generation is malformed" ;; esac
[ "${#STORED_GENERATION}" -le 18 ] || die "delivered outbox generation is malformed"
case "$STORED_BYTES" in ''|*[!0-9]*) die "delivered outbox generation is malformed" ;; esac
case "$STORED_HASH" in ''|*[!A-Fa-f0-9]*) die "delivered outbox generation is malformed" ;; esac
[ "${#STORED_HASH}" -eq 64 ] || die "delivered outbox generation is malformed"
[ "$STORED_GENERATION" = "$GENERATION" ] \
  && [ "$STORED_BYTES" = "$EXPECTED_BYTES" ] \
  && [ "$STORED_HASH" = "$EXPECTED_HASH" ] \
  || die "delivered outbox generation is superseded or conflicting"
ACTUAL_BYTES=$(LC_ALL=C wc -c < "$DELIVERED" | tr -d ' ')
[ "$ACTUAL_BYTES" -eq "$EXPECTED_BYTES" ] || die "delivered outbox length does not match its commitment"
ACTUAL_HASH=$(sha256_file "$DELIVERED") || die "cannot hash delivered outbox"
[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || die "delivered outbox digest does not match its commitment"
[ ! -L "$DEST" ] || die "destination backlog must not be a symlink"
if [ -e "$DEST" ] && [ ! -f "$DEST" ]; then die "destination backlog is not a regular file"; fi

KEYS=()
while IFS= read -r key; do
  [ -n "$key" ] && KEYS+=("$key")
done < <(list_keys "$DELIVERED")
while IFS= read -r key; do
  case "$key" in ''|.*|*[!A-Za-z0-9._-]*) die "delivered outbox has an unsafe task id" ;; esac
  task_lock="$FM_HOME/state/.spawn-$key.lock"
  fm_lock_acquire_wait "$task_lock" || die "cannot lock destination task $key"
  ACTIVE_TASK_LOCKS+=("$task_lock")
done < <(printf '%s\n' "${KEYS[@]}" | LC_ALL=C sort -u)
for key in "${KEYS[@]}"; do
  section=$(backlog_key_section "$DELIVERED" "$key") || die "delivered key disappeared during classification: $key"
  [ "$section" = '## Queued' ] || die "delivered outbox contains non-Queued item $key under $section"
done

IFS= read -r RESTRICTION_HEADER || die "dispatch restriction payload is missing"
[ "$RESTRICTION_HEADER" = 'FM-DISPATCH-RESTRICTIONS 1' ] || die "dispatch restriction payload is malformed"
RESTRICTIONS_TERMINATED=0
while IFS=$'\t' read -r presence key encoded extra; do
  [ -n "$presence$key$encoded$extra" ] || continue
  [ "$RESTRICTIONS_TERMINATED" -eq 0 ] || die "dispatch restriction payload continues past its terminator"
  if [ "$presence" = 'FM-DISPATCH-RESTRICTIONS-END' ]; then
    [ -z "$key$encoded$extra" ] || die "dispatch restriction payload is malformed"
    RESTRICTIONS_TERMINATED=1
    continue
  fi
  [ "$presence" = present ] && [ -n "$encoded" ] && [ -z "$extra" ] \
    || die "dispatch restriction payload is malformed"
  case "$key" in ''|.*|*[!A-Za-z0-9._-]*) die "dispatch restriction payload has an unsafe task id" ;; esac
  backlog_key_section "$DELIVERED" "$key" >/dev/null 2>&1 \
    || die "dispatch restriction payload names an item outside the delivered outbox"
  [ ! -e "$RESTRICTION_STAGE/$key.present" ] \
    || die "dispatch restriction payload repeats task $key"
  case "$encoded" in ''|*[!A-Za-z0-9+/=]*) die "dispatch restriction payload encoding is malformed" ;; esac
  base64_decode_to "$encoded" "$RESTRICTION_STAGE/$key.present" \
    || die "dispatch restriction payload could not be decoded"
  normalized=$(base64_encode_file "$RESTRICTION_STAGE/$key.present") \
    || die "dispatch restriction payload could not be verified"
  [ "$normalized" = "$encoded" ] || die "dispatch restriction payload encoding is malformed"
done
# The payload carries only present records, so an absent record and a lost
# record look identical. Requiring the sender's terminator is what proves the
# whole restriction set arrived before any delivered item becomes dispatchable.
[ "$RESTRICTIONS_TERMINATED" -eq 1 ] || die "dispatch restriction payload is truncated"

mkdir -p "$FM_HOME/data"
[ -d "$FM_HOME/data" ] && [ ! -L "$FM_HOME/data" ] || die "destination data directory is unsafe"
if find "$RESTRICTION_STAGE" -type f -print -quit | grep -q .; then
  RESTRICTION_DEST="$FM_HOME/data/dispatch-restrictions"
  mkdir -p "$RESTRICTION_DEST" || die "cannot create destination dispatch restriction directory"
  [ -d "$RESTRICTION_DEST" ] && [ ! -L "$RESTRICTION_DEST" ] \
    || die "destination dispatch restriction directory is unsafe"
  for staged in "$RESTRICTION_STAGE"/*; do
    [ -f "$staged" ] || continue
    name=$(basename "$staged")
    key=${name%.*}
    destination="$RESTRICTION_DEST/$key"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      if [ ! -f "$destination" ] || [ -L "$destination" ]; then
        die "destination dispatch restriction for $key is unsafe"
      fi
    fi
    tmp=$(umask 077; mktemp "$RESTRICTION_DEST/.restriction.XXXXXX") \
      || die "cannot stage destination dispatch restriction for $key"
    if ! cp -p -- "$staged" "$tmp" || ! mv -f -- "$tmp" "$destination"; then
      rm -f -- "$tmp"
      die "cannot install destination dispatch restriction for $key"
    fi
  done
fi
DEST_CREATED=0
if [ ! -f "$DEST" ]; then
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$DEST"
  DEST_CREATED=1
fi
TO_MOVE=()
ALREADY=()
for key in "${KEYS[@]}"; do
  if backlog_key_section "$DEST" "$key" >/dev/null 2>&1; then
    ALREADY+=("$key")
  else
    TO_MOVE+=("$key")
  fi
done

if [ "${#TO_MOVE[@]}" -gt 0 ]; then
  fm_tasks_axi_compatible || die "a compatible tasks-axi is required for atomic backlog receipt; run bin/fm-bootstrap.sh for the required version"
  if ! MOVE_OUT=$(run_move "${TO_MOVE[@]}" 2>&1); then
    recovered=0
    for lock in "$DELIVERED.lock" "$DEST.lock"; do
      if remove_dead_stale_lock "$lock"; then recovered=1; fi
    done
    if [ "$recovered" -ne 1 ] || ! MOVE_OUT=$(run_move "${TO_MOVE[@]}" 2>&1); then
      [ "$DEST_CREATED" -eq 0 ] || rm -f -- "$DEST"
      [ -z "$MOVE_OUT" ] || printf '%s\n' "$MOVE_OUT" >&2
      die "atomic backlog receipt failed; delivered outbox is preserved for retry"
    fi
  fi
fi

for key in "${KEYS[@]}"; do
  backlog_key_section "$DEST" "$key" >/dev/null 2>&1 \
    || die "receipt verification failed for $key; delivered outbox is preserved"
done
rm -f -- "$DELIVERED" || die "receipt succeeded but delivered scratch cleanup failed"
for task_lock in "${ACTIVE_TASK_LOCKS[@]}"; do
  [ -n "$task_lock" ] || continue
  fm_lock_release "$task_lock" || die "receipt succeeded but task lock cleanup failed"
done
ACTIVE_TASK_LOCKS=("")
fm_lock_release "$TRANSFER_LOCK" || die "receipt succeeded but transfer lock cleanup failed"
rm -rf -- "$RESTRICTION_STAGE"
trap - EXIT
printf 'received: %s moved=%s already=%s\n' "$(basename "$REL" .outbox.md)" "${#TO_MOVE[@]}" "${#ALREADY[@]}"
