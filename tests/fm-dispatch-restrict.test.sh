#!/usr/bin/env bash
# Behavior tests for the captain dispatch restriction: bin/fm-dispatch-restrict.sh
# (set/list/lift), the storage format it shares with bin/fm-dispatch-restrict-lib.sh,
# and the bin/fm-spawn.sh gate that reads it.
#
# This is the fix for the vps01-workflow-count-correction incident: a captain
# "keep this queued, do not dispatch" instruction used to be only a recorded
# working practice (learnings, escalation history) that an agent had to
# remember to re-check. It is now a durable per-task-id record that
# bin/fm-spawn.sh itself refuses to spawn past, independent of tasks-axi's own
# hold flag (which clears on completion) and of the backlog backend.
#
# Every spawn attempt here fails fast: a restricted id is refused by the gate
# before any brief/project lookup, and an unrestricted id reaches the ordinary
# "no brief" refusal fm-spawn-batch.test.sh already relies on, so no worktree,
# tmux, or treehouse side effect is ever created. FM_SPAWN_NO_GUARD=1 keeps
# spawns off the live watcher guard/state.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
RESTRICT="$ROOT/bin/fm-dispatch-restrict.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-restrict)
export FM_BACKEND=tmux

# A fresh, isolated firstmate home with a project clone-shaped placeholder at
# projects/alpha (the spawn gate runs before fm-spawn.sh ever needs that
# directory to be a real git repo).
new_home() {  # <name>
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state" "$home/projects/alpha"
  printf '%s\n' "$home"
}

run_restrict() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    "$RESTRICT" "$@" 2>&1
}

run_spawn() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

run_ship_spawn() {  # <home> <id>
  local home=$1 id=$2
  run_spawn "$home" "$id" projects/alpha --mode no-mistakes --yolo off
}

run_scout_spawn() {  # <home> <id>
  local home=$1 id=$2
  run_spawn "$home" "$id" projects/alpha --scout
}

test_set_requires_reason_and_by() {
  local home out status
  home=$(new_home set-flags)

  out=$(run_restrict "$home" set nope-flags-a1)
  status=$?
  [ "$status" -ne 0 ] || fail "set without --reason/--by should exit non-zero"
  assert_contains "$out" 'requires --reason' "set without --reason did not name the missing flag"

  out=$(run_restrict "$home" set nope-flags-a1 --reason "hold it")
  status=$?
  [ "$status" -ne 0 ] || fail "set without --by should exit non-zero"
  assert_contains "$out" 'requires --by' "set without --by did not name the missing flag"

  assert_absent "$home/data/dispatch-restrictions/nope-flags-a1" \
    "an incomplete set should not have written a restriction record"
  pass "fm-dispatch-restrict.sh set refuses without --reason and --by"
}

test_set_list_lift_roundtrip() {
  local home out status
  home=$(new_home set-list-lift)

  out=$(run_restrict "$home" set nope-roundtrip-b2 --reason "keep queued pending review" --by captain) \
    || fail "set should succeed: $out"
  assert_contains "$out" 'restricted nope-roundtrip-b2' "set did not confirm the restriction"
  assert_present "$home/data/dispatch-restrictions/nope-roundtrip-b2" \
    "set did not write a durable restriction record"

  out=$(run_restrict "$home" list) || fail "list should succeed: $out"
  assert_contains "$out" 'nope-roundtrip-b2' "list did not show the restricted id"
  assert_contains "$out" 'by=captain' "list did not show who restricted it"
  assert_contains "$out" 'reason=keep queued pending review' "list did not show the reason"

  out=$(run_restrict "$home" lift nope-roundtrip-b2) || fail "lift should succeed: $out"
  assert_contains "$out" 'lifted nope-roundtrip-b2' "lift did not confirm removal"
  assert_absent "$home/data/dispatch-restrictions/nope-roundtrip-b2" \
    "lift did not remove the durable restriction record"

  out=$(run_restrict "$home" list)
  assert_not_contains "$out" 'nope-roundtrip-b2' "list still showed a lifted id"

  out=$(run_restrict "$home" lift nope-roundtrip-b2)
  status=$?
  [ "$status" -ne 0 ] || fail "lifting an already-lifted id should exit non-zero"
  assert_contains "$out" 'not currently restricted' "re-lift did not explain there was nothing to lift"

  pass "fm-dispatch-restrict.sh set/list/lift round-trip cleanly"
}

# `list` is the captain's audit surface, so a write killed before its rename must
# not be able to appear there as a restricted id. Staging is dot-prefixed for
# exactly that reason, and its leftover parses as a complete record otherwise.
test_list_ignores_an_interrupted_write() {
  local home out dir
  home=$(new_home list-interrupted-write)

  out=$(run_restrict "$home" set nope-crash-c3 --reason "real hold" --by captain) \
    || fail "set should succeed: $out"
  dir="$home/data/dispatch-restrictions"
  printf 'by=captain\nat=2026-09-08T00:00:00Z\nreason=abandoned write\n' \
    > "$dir/.restriction.abcdef"

  out=$(run_restrict "$home" list) || fail "list should succeed: $out"
  assert_contains "$out" 'nope-crash-c3' "list dropped a genuinely restricted id"
  assert_not_contains "$out" 'abandoned write' \
    "list reported an interrupted write's staging file as an active restriction"
  assert_not_contains "$out" 'restriction' \
    "list surfaced a staging file name as a restricted task id"
  pass "fm-dispatch-restrict.sh list ignores an interrupted write's staging file"
}

# The record is per home and neither subcommand reads a backlog, so the only
# safeguard against restricting the wrong home is that both name the home.
test_set_and_lift_name_the_home_they_acted_on() {
  local home out
  home=$(new_home names-home)

  out=$(run_restrict "$home" set nope-home-d4 --reason "keep queued" --by captain) \
    || fail "set should succeed: $out"
  assert_contains "$out" "in $home" "set did not name the home its record landed in"

  out=$(run_restrict "$home" lift nope-home-d4) || fail "lift should succeed: $out"
  assert_contains "$out" "in $home" "lift did not name the home it acted on"

  out=$(run_restrict "$home" lift nope-home-d4)
  assert_contains "$out" "in $home" "the nothing-to-lift refusal did not name the home checked"
  pass "fm-dispatch-restrict.sh set and lift name the home they acted on"
}

test_spawn_refuses_restricted_ship_and_scout() {
  local home out status
  home=$(new_home spawn-refuse)

  run_restrict "$home" set nope-ship-c3 --reason "captain: keep this queued" --by captain >/dev/null \
    || fail "fixture: set restriction on ship id failed"
  run_restrict "$home" set nope-scout-c4 --reason "captain: keep this queued" --by captain >/dev/null \
    || fail "fixture: set restriction on scout id failed"

  out=$(run_ship_spawn "$home" nope-ship-c3)
  status=$?
  [ "$status" -ne 0 ] || fail "ship spawn of a restricted id should be refused"
  assert_contains "$out" 'dispatch restriction' "ship refusal did not name the restriction"
  assert_contains "$out" 'set by captain' "ship refusal did not name who set it"
  assert_contains "$out" 'keep this queued' "ship refusal did not include the reason"
  assert_contains "$out" 'bin/fm-dispatch-restrict.sh lift nope-ship-c3' \
    "ship refusal did not give the exact lift command"
  assert_absent "$home/state/nope-ship-c3.meta" "a refused ship spawn must not publish task state"

  out=$(run_scout_spawn "$home" nope-scout-c4)
  status=$?
  [ "$status" -ne 0 ] || fail "scout spawn of a restricted id should be refused"
  assert_contains "$out" 'dispatch restriction' "scout refusal did not name the restriction"
  assert_contains "$out" 'bin/fm-dispatch-restrict.sh lift nope-scout-c4' \
    "scout refusal did not give the exact lift command"
  assert_absent "$home/state/nope-scout-c4.meta" "a refused scout spawn must not publish task state"

  pass "fm-spawn.sh refuses a ship and a scout spawn for a restricted id"
}

test_restricted_spawn_refuses_before_state_creation() {
  local home out status
  home=$(new_home spawn-before-state)
  run_restrict "$home" set nope-early-c5 --reason "keep queued" --by captain >/dev/null \
    || fail "fixture: set restriction failed"
  rm -rf "$home/state"

  out=$(run_ship_spawn "$home" nope-early-c5)
  status=$?
  [ "$status" -ne 0 ] || fail "restricted spawn should refuse"
  assert_contains "$out" 'dispatch restriction' "restricted spawn did not name the restriction"
  if find "$home/state" -mindepth 1 -print -quit | grep -q .; then
    fail "restricted spawn created task state or a lock before refusing"
  fi
  pass "fm-spawn.sh checks a restriction before creating task state or locks"
}

test_restriction_directory_symlink_is_refused() {
  local home target out status
  home=$(new_home symlink-directory)
  target="$home/escaped-restrictions"
  mkdir -p "$target"
  printf 'by=captain\nat=2026-09-12T00:00:00Z\nreason=outside\n' > "$target/nope-link-j1"
  ln -s "$target" "$home/data/dispatch-restrictions"

  out=$(run_restrict "$home" list)
  status=$?
  [ "$status" -ne 0 ] || fail "list should refuse a symlink restriction directory"
  assert_contains "$out" 'not a real directory' "list did not identify the unsafe directory"

  out=$(run_restrict "$home" set nope-link-j2 --reason "unsafe" --by captain)
  status=$?
  [ "$status" -ne 0 ] || fail "set should refuse a symlink restriction directory"
  assert_absent "$target/nope-link-j2" "set wrote through the restriction directory symlink"

  out=$(run_restrict "$home" lift nope-link-j1)
  status=$?
  [ "$status" -ne 0 ] || fail "lift should refuse a symlink restriction directory"
  assert_present "$target/nope-link-j1" "lift removed a record through the restriction directory symlink"
  pass "restriction operations refuse a symlink storage directory"
}

test_spawn_unaffected_when_unrestricted() {
  local home out status
  home=$(new_home spawn-unaffected)

  out=$(run_ship_spawn "$home" nope-ship-free-d5)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn with a missing brief should still fail"
  assert_contains "$out" 'no brief at' "an unrestricted ship spawn was not reached by the ordinary brief check"
  assert_not_contains "$out" 'dispatch restriction' "an unrestricted ship spawn was wrongly gated"

  out=$(run_scout_spawn "$home" nope-scout-free-d6)
  status=$?
  [ "$status" -ne 0 ] || fail "scout spawn with a missing brief should still fail"
  assert_contains "$out" 'no brief at' "an unrestricted scout spawn was not reached by the ordinary brief check"
  assert_not_contains "$out" 'dispatch restriction' "an unrestricted scout spawn was wrongly gated"

  pass "fm-spawn.sh is unaffected by the restriction gate when no restriction exists"
}

test_spawn_proceeds_after_lift() {
  local home out status
  home=$(new_home spawn-after-lift)

  run_restrict "$home" set nope-lifted-e7 --reason "temporary hold" --by captain >/dev/null \
    || fail "fixture: set restriction failed"
  out=$(run_ship_spawn "$home" nope-lifted-e7)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn while still restricted should be refused"
  assert_contains "$out" 'dispatch restriction' "spawn was not refused before lift"

  run_restrict "$home" lift nope-lifted-e7 >/dev/null || fail "fixture: lift failed"
  out=$(run_ship_spawn "$home" nope-lifted-e7)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn with a missing brief should still fail after lift"
  assert_contains "$out" 'no brief at' "spawn did not reach the ordinary brief check after lift"
  assert_not_contains "$out" 'dispatch restriction' "spawn was still gated after an explicit lift"

  pass "fm-spawn.sh allows a spawn again after an explicit lift"
}

# A --secondmate <id> names the secondmate's own persistent identity, not a
# backlog task, so a restriction record that happens to share that id string
# must never gate a secondmate launch - restricting a backlog task id and
# restricting a secondmate id are different, unrelated actions.
test_spawn_secondmate_id_namespace_is_exempt() {
  local home out status
  home=$(new_home spawn-secondmate-exempt)

  run_restrict "$home" set sm-namesake-f8 --reason "unrelated backlog hold" --by captain >/dev/null \
    || fail "fixture: set restriction failed"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" sm-namesake-f8 --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a bare --secondmate spawn against this fixture should still fail on its own terms"
  assert_not_contains "$out" 'dispatch restriction' \
    "a --secondmate spawn was wrongly gated by a same-named backlog task restriction"

  pass "fm-spawn.sh does not apply the task-id restriction gate to a --secondmate spawn"
}

test_set_requires_reason_and_by
test_set_list_lift_roundtrip
test_list_ignores_an_interrupted_write
test_set_and_lift_name_the_home_they_acted_on
test_spawn_refuses_restricted_ship_and_scout
test_restricted_spawn_refuses_before_state_creation
test_restriction_directory_symlink_is_refused
test_spawn_unaffected_when_unrestricted
test_spawn_proceeds_after_lift
test_spawn_secondmate_id_namespace_is_exempt
