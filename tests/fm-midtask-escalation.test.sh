#!/usr/bin/env bash
# Tests for fm-midtask-escalation.sh: the mid-task model-class suggestion.
#
# Every case drives the real script through FM_HOME and a fixture worktree,
# with a fake `no-mistakes` on PATH and a stubbed bin/fm-crew-state.sh (via
# FM_MIDTASK_CREW_STATE_BIN), so no case depends on a real no-mistakes
# install or a real running crew.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-midtask-escalation.sh"
TMP_ROOT=$(fm_test_tmproot fm-midtask-escalation)

fm_git_identity fmtest fmtest@example.invalid

# make_worktree: a scratch git repo/worktree fixture cases can point a task's
# meta at. No case actually drives no-mistakes against it; the fake
# no-mistakes binary answers every call, so the directory only has to exist.
make_worktree() {
  local dir="$TMP_ROOT/wt"
  [ -d "$dir" ] || {
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" commit -q --allow-empty -m init
  }
  printf '%s' "$dir"
}

# make_home <name>: a fresh FM_HOME with state/.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s' "$home"
}

# write_meta <home> <id> <k=v>...: kind=ship, branch=fm/demo, and worktree
# already set; extra k=v pairs override or add fields.
write_meta() {
  local home=$1 id=$2 wt
  shift 2
  wt=$(make_worktree)
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$wt" \
    "project=$wt" \
    "harness=claude" \
    "model=claude-opus-5-5" \
    "effort=high" \
    "kind=ship" \
    "branch=fm/demo" \
    "$@"
}

# write_status <home> <id> <line>...: one status line per argument, each
# already carrying its own [at=...] tag.
write_status() {
  local home=$1 id=$2
  shift 2
  : > "$home/state/$id.status"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$home/state/$id.status"
  done
}

now() { date +%s; }

# stub_crew_state <bindir> <state-line>: a fake fm-crew-state.sh that always
# prints the given line regardless of the id it is asked about.
stub_crew_state() {
  local bindir=$1 line=$2
  mkdir -p "$bindir"
  cat > "$bindir/crew-state-stub.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' $(printf '%q' "$line")
SH
  chmod +x "$bindir/crew-state-stub.sh"
  printf '%s/crew-state-stub.sh' "$bindir"
}

# stub_no_mistakes <bindir> <worktree> <run-id> <ledger-status> <detail-status>
#   <outcome> <rounds-table-file>: a fake `no-mistakes` on PATH answering the
# three calls fm-midtask-escalation.sh makes (axi, axi status --run, stats
# --agents --run) for exactly one run on branch fm/demo.
stub_no_mistakes() {
  local bindir=$1 wt=$2 run_id=$3 ledger_status=$4 detail_status=$5 outcome=$6 rounds_file=$7
  mkdir -p "$bindir"
  cat > "$bindir/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\$1" = axi ] && [ "\$2" = status ] && [ "\$3" = --run ]; then
  printf 'id: "%s"\nbranch: fm/demo\nstatus: %s\noutcome: %s\n' "$run_id" "$detail_status" "$outcome"
  exit 0
fi
if [ "\$1" = axi ]; then
  printf 'repo: "%s"\ncurrent_branch: fm/demo\nruns_on_current_branch: 1\ncount: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  "%s",fm/demo,%s,deadbeef,""\n' "$wt" "$run_id" "$ledger_status"
  exit 0
fi
if [ "\$1" = stats ]; then
  cat "$rounds_file"
  exit 0
fi
exit 1
SH
  chmod +x "$bindir/no-mistakes"
}

no_nm_path() { printf '/usr/bin:/bin'; }

test_help_and_usage() {
  local out
  out=$("$TOOL" --help 2>&1)
  assert_contains "$out" "fm-midtask-escalation.sh" "help names the tool"
  assert_contains "$out" "check <task-id>" "help documents the check verb"

  "$TOOL" >/tmp/fm-mte-usage-out.$$ 2>&1
  local rc=$?
  assert_equals 2 "$rc" "no arguments is a usage error"
  rm -f "/tmp/fm-mte-usage-out.$$"
  pass "fm-midtask-escalation: help and bare usage behave as documented"
}

test_missing_meta_prints_nothing() {
  local home out
  home=$(make_home missing-meta)
  out=$(FM_HOME="$home" PATH="$(no_nm_path)" "$TOOL" check ghost 2>&1)
  assert_equals '' "$out" "a task with no recorded meta prints nothing"
  pass "fm-midtask-escalation: an unrecorded task id is silently skipped"
}

test_secondmate_is_skipped() {
  local home out
  home=$(make_home secondmate)
  fm_write_meta "$home/state/mate.meta" "kind=secondmate" "worktree=$(make_worktree)" "branch=fm/demo"
  out=$(FM_HOME="$home" PATH="$(no_nm_path)" "$TOOL" check mate 2>&1)
  assert_equals '' "$out" "a persistent secondmate is never suggested a model-class move"
  pass "fm-midtask-escalation: a secondmate task id is skipped"
}

test_repeated_blocked_reports_suggest_up_and_rate_limit() {
  local home crew out record
  home=$(make_home blocked)
  write_meta "$home" demo
  write_status "$home" demo \
    "working [at=$(($(now) - 900))]: setup done" \
    "blocked [at=$(($(now) - 500))]: obstacle A" \
    "blocked [at=$(now)]: obstacle A again"
  crew=$(stub_crew_state "$TMP_ROOT/bin1" "state: blocked · source: pane · idle")

  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew" PATH="$(no_nm_path)" "$TOOL" check demo)
  assert_contains "$out" "midtask-escalation: demo suggests moving up a model class" "two blocked reports suggest moving up"
  assert_contains "$out" "reported blocked 2 time(s)" "the evidence names the blocked count"
  assert_contains "$out" "bin/fm-control.sh demo relaunch" "the suggestion carries the one relaunch command"
  record="$home/state/.midtask-escalation-demo"
  assert_present "$record" "a suggestion persists its rate-limit signature"

  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew" PATH="$(no_nm_path)" "$TOOL" check demo)
  assert_equals '' "$out" "unchanged evidence is not re-suggested"

  printf 'blocked [at=%s]: obstacle B\n' "$(now)" >> "$home/state/demo.status"
  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew" PATH="$(no_nm_path)" "$TOOL" check demo)
  assert_contains "$out" "reported blocked 3 time(s)" "a new blocked report is new evidence and re-suggests"
  pass "fm-midtask-escalation: repeated blocked reports suggest up, once per new count"
}

test_a_later_blocked_episode_with_the_same_count_re_suggests() {
  local home crew out
  home=$(make_home blocked-episodes)
  write_meta "$home" demo "branch=fm/no-run"
  write_status "$home" demo \
    "blocked [at=$(now)]: obstacle A" \
    "blocked [at=$(now)]: obstacle A again"
  crew=$(stub_crew_state "$TMP_ROOT/bin-episodes" "state: blocked · source: pane · idle")

  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew" PATH="$(no_nm_path)" "$TOOL" check demo)
  assert_contains "$out" "reported blocked 2 time(s)" "the first episode suggests up"

  printf 'resolved [at=%s]: fixed\nblocked [at=%s]: obstacle B\nblocked [at=%s]: obstacle B again\n' \
    "$(now)" "$(now)" "$(now)" >> "$home/state/demo.status"
  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew" PATH="$(no_nm_path)" "$TOOL" check demo)
  assert_contains "$out" "reported blocked 2 time(s)" "a later episode reaching the same count is new evidence"

  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew" PATH="$(no_nm_path)" "$TOOL" check demo)
  assert_equals '' "$out" "the later episode is still reported only once"
  pass "fm-midtask-escalation: a later blocked episode with the same count earns its own suggestion"
}

test_resolved_clears_the_blocked_streak() {
  local home crew out
  home=$(make_home resolved)
  write_meta "$home" demo
  write_status "$home" demo \
    "blocked [at=$(($(now) - 900))]: obstacle A" \
    "blocked [at=$(($(now) - 800))]: obstacle A again" \
    "resolved [at=$(($(now) - 700))]: fixed" \
    "working [at=$(now)]: back at it"
  crew=$(stub_crew_state "$TMP_ROOT/bin2" "state: working · source: run-step · running")

  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew" PATH="$(no_nm_path)" "$TOOL" check demo)
  assert_equals '' "$out" "a resolved obstacle does not carry the blocked count forward"
  pass "fm-midtask-escalation: resolved: clears the blocked streak"
}

test_declared_pause_does_not_count_as_stall() {
  local home crew out
  home=$(make_home paused)
  write_meta "$home" demo "branch=fm/no-run"
  write_status "$home" demo "paused [at=$(($(now) - 7200))]: waiting on CI"
  crew=$(stub_crew_state "$TMP_ROOT/bin3" "state: paused · source: status-log · declared wait")

  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew" PATH="$(no_nm_path)" "$TOOL" check demo)
  assert_equals '' "$out" "a declared pause, however old, is never read as a stall"
  pass "fm-midtask-escalation: a declared paused: wait is exempt from the stall signal"
}

test_old_failed_state_suggests_up() {
  local home crew out
  home=$(make_home stalled)
  write_meta "$home" demo "branch=fm/no-run"
  write_status "$home" demo "failed [at=$(($(now) - 7200))]: tests keep breaking"
  crew=$(stub_crew_state "$TMP_ROOT/bin4" "state: failed · source: status-log · failed")

  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew" PATH="$(no_nm_path)" "$TOOL" check demo)
  assert_contains "$out" "suggests moving up a model class" "a long-idle failed state suggests up"
  assert_contains "$out" "no status update for" "the evidence names the stall duration"
  pass "fm-midtask-escalation: a long-idle failed state suggests up"
}

test_parked_and_unknown_do_not_count_as_stall() {
  local home crew out state
  for state in parked unknown; do
    home=$(make_home "stall-exempt-$state")
    write_meta "$home" demo "branch=fm/no-run"
    write_status "$home" demo "needs-decision [at=$(($(now) - 86400))]: pick an approach"
    crew=$(stub_crew_state "$TMP_ROOT/bin4-$state" "state: $state · source: none · waiting")
    out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew" PATH="$(no_nm_path)" "$TOOL" check demo)
    assert_equals '' "$out" "a very old $state state is never read as a worker struggle"
  done
  pass "fm-midtask-escalation: parked and unknown states are exempt from the stall signal"
}

test_unfired_evidence_drift_does_not_re_suggest() {
  local home crew_blocked crew_working out
  home=$(make_home drift)
  write_meta "$home" demo "branch=fm/no-run"
  write_status "$home" demo \
    "blocked [at=$(($(now) - 7200))]: obstacle A" \
    "blocked [at=$(($(now) - 3700))]: obstacle A again"
  crew_blocked=$(stub_crew_state "$TMP_ROOT/bin8a" "state: blocked · source: pane · idle")
  crew_working=$(stub_crew_state "$TMP_ROOT/bin8b" "state: working · source: pane · running")

  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew_working" PATH="$(no_nm_path)" "$TOOL" check demo)
  assert_contains "$out" "reported blocked 2 time(s)" "two blocked reports suggest up while working"
  assert_not_contains "$out" "no status update for" "the stall rule does not fire while working"

  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew_working" FM_MIDTASK_STALL_SECONDS=60 \
    PATH="$(no_nm_path)" "$TOOL" check demo)
  assert_equals '' "$out" "a stall interval elapsing without the stall rule firing is not new evidence"

  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew_blocked" FM_MIDTASK_STALL_SECONDS=999999 \
    PATH="$(no_nm_path)" "$TOOL" check demo)
  assert_equals '' "$out" "a crew-state change alone, with the same firing evidence, is not re-suggested"
  pass "fm-midtask-escalation: drift in evidence that did not fire never forces a repeat suggestion"
}

test_nm_round_threshold_suggests_up() {
  local home wt crew out bindir
  home=$(make_home rounds)
  write_meta "$home" demo >/dev/null
  wt=$(sed -n 's/^worktree=//p' "$home/state/demo.meta" | head -1)
  write_status "$home" demo "working [at=$(now)]: still fixing"
  crew=$(stub_crew_state "$TMP_ROOT/bin5" "state: working · source: run-step · fixing")
  bindir="$TMP_ROOT/bin5-nm"
  printf 'STEP   ROUND  PURPOSE     AGENT  MODEL  SESSION  KEY  DURATION  MODEL  SUBPROC  RT  TOOLS  FIND  WORK  FALLBACK  EXIT\nreview 1      review      claude opus   cold     x    1s        -      -        -   -      1     -/-   -         ok\nreview 2      review-fix  claude opus   started  y    1s        -      -        -   -      -     -/-   -         ok\nreview 2      review      claude opus   cold     z    1s        -      -        -   -      1     -/-   -         ok\nreview 3      review-fix  claude opus   resumed  w    1s        -      -        -   -      -     -/-   -         ok\nreview 3      review      claude opus   cold     v    1s        -      -        -   -      0     -/-   -         ok\n' \
    > "$TMP_ROOT/rounds.txt"
  stub_no_mistakes "$bindir" "$wt" 01RUNDEMO000000000000000 running fixing "" "$TMP_ROOT/rounds.txt"

  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew" PATH="$bindir:/usr/bin:/bin" "$TOOL" check demo)
  assert_contains "$out" "suggests moving up a model class" "reaching the fix-round cap suggests up"
  assert_contains "$out" "no-mistakes used 3 fix round(s)" "the evidence names the round count"
  pass "fm-midtask-escalation: reaching the no-mistakes fix-round threshold suggests up"
}

# write_rounds <file> <step>:<rounds>...: a `no-mistakes stats --agents` table
# in which each named step ran the given number of rounds.
write_rounds() {
  local file=$1 spec step rounds n
  shift
  printf 'STEP   ROUND  PURPOSE     AGENT  MODEL  SESSION  KEY  DURATION  MODEL  SUBPROC  RT  TOOLS  FIND  WORK  FALLBACK  EXIT\n' > "$file"
  for spec in "$@"; do
    step=${spec%%:*}
    rounds=${spec##*:}
    n=1
    while [ "$n" -le "$rounds" ]; do
      printf '%s %s      %s      claude opus   cold     k%s   1s        -      -        -   -      1     -/-   -         ok\n' \
        "$step" "$n" "$step" "$n" >> "$file"
      n=$((n + 1))
    done
  done
}

# check_with_rounds <name> <step>:<rounds>...: the `check` output for a
# healthy working task whose selected run used those rounds.
check_with_rounds() {
  local name=$1 home wt crew bindir
  shift
  home=$(make_home "$name")
  write_meta "$home" demo >/dev/null
  wt=$(sed -n 's/^worktree=//p' "$home/state/demo.meta" | head -1)
  write_status "$home" demo "working [at=$(now)]: validation running"
  crew=$(stub_crew_state "$TMP_ROOT/bin-$name" "state: working · source: run-step · fixing")
  bindir="$TMP_ROOT/bin-$name-nm"
  write_rounds "$TMP_ROOT/rounds-$name.txt" "$@"
  stub_no_mistakes "$bindir" "$wt" 01RUNDEMO000000000000000 running fixing "" "$TMP_ROOT/rounds-$name.txt"
  FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew" PATH="$bindir:/usr/bin:/bin" "$TOOL" check demo
}

test_ci_only_rounds_never_suggest_up() {
  local out
  out=$(check_with_rounds ci-only review:1 ci:3)
  assert_equals '' "$out" "three ci fix rounds alone are not worker difficulty"
  out=$(check_with_rounds ci-many review:1 ci:6)
  assert_equals '' "$out" "any number of ci fix rounds stays silent"
  pass "fm-midtask-escalation: ci-step fix rounds never trigger the suggestion"
}

test_mixed_rounds_count_only_the_review_rounds() {
  local out
  out=$(check_with_rounds mixed-below review:2 ci:5)
  assert_equals '' "$out" "ci rounds do not lift review rounds over the threshold"
  out=$(check_with_rounds mixed-over review:3 ci:5)
  assert_contains "$out" "suggests moving up a model class" "review rounds at the threshold still suggest up beside ci rounds"
  assert_contains "$out" "no-mistakes used 3 fix round(s)" "the evidence names the review count, not the larger ci count"
  pass "fm-midtask-escalation: a mixed run is judged on its review rounds only"
}

test_clean_healthy_task_gets_no_suggestion() {
  local home wt crew done_crew out bindir
  home=$(make_home clean)
  write_meta "$home" demo >/dev/null
  wt=$(sed -n 's/^worktree=//p' "$home/state/demo.meta" | head -1)
  write_status "$home" demo "working [at=$(now)]: review running"
  crew=$(stub_crew_state "$TMP_ROOT/bin6" "state: working · source: run-step · reviewing")
  done_crew=$(stub_crew_state "$TMP_ROOT/bin6-done" "state: done · source: run-step · passed")
  bindir="$TMP_ROOT/bin6-nm"
  printf 'STEP    ROUND  PURPOSE  AGENT  MODEL  SESSION  KEY  DURATION  MODEL  SUBPROC  RT  TOOLS  FIND  WORK  FALLBACK  EXIT\nreview  1      review   claude opus   cold     x    1s        -      -        -   -      0     -/-   -         ok\n' \
    > "$TMP_ROOT/rounds-clean.txt"
  stub_no_mistakes "$bindir" "$wt" 01RUNCLEAN0000000000000 running reviewing "" "$TMP_ROOT/rounds-clean.txt"

  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$crew" PATH="$bindir:/usr/bin:/bin" "$TOOL" check demo)
  assert_equals '' "$out" "a clean, still-working, zero-blocked task gets no suggestion"
  out=$(FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$done_crew" PATH="$bindir:/usr/bin:/bin" "$TOOL" check demo)
  assert_equals '' "$out" "a clean finished task gets no suggestion"
  assert_absent "$home/state/.midtask-escalation-demo" "no suggestion means no rate-limit record"
  pass "fm-midtask-escalation: a clean healthy task is never suggested a model-class move"
}

test_arm_uses_a_distinct_check_id_and_disarm_removes_everything() {
  local home out shim trust record
  home=$(make_home arm)
  write_meta "$home" demo >/dev/null

  out=$(FM_HOME="$home" "$TOOL" arm demo)
  assert_contains "$out" "armed: state/midtask-demo.check.sh" "arm reports the registered path"
  shim="$home/state/midtask-demo.check.sh"
  trust="$home/state/midtask-demo.check-trust"
  assert_present "$shim" "arm writes the per-task shim"
  assert_present "$trust" "arm registers a trust binding for the shim"
  assert_absent "$home/state/demo.check.sh" "the registered id is never the bare task id (that path is the PR-poll shim's own)"
  local mode
  mode=$(stat -c '%a' "$shim" 2>/dev/null || stat -f '%Lp' "$shim" 2>/dev/null)
  assert_equals 700 "$mode" "the shim is written mode 700"
  assert_contains "$(cat "$shim")" "check demo" "the shim's action targets the real task id"

  printf 'blocked [at=%s]: a\nblocked [at=%s]: b\n' "$(now)" "$(now)" > "$home/state/demo.status"
  FM_HOME="$home" FM_MIDTASK_CREW_STATE_BIN="$(stub_crew_state "$TMP_ROOT/bin7" "state: blocked · source: pane · idle")" \
    PATH="$(no_nm_path)" "$shim" >/dev/null 2>&1
  record="$home/state/.midtask-escalation-demo"
  assert_present "$record" "running the armed shim produces the same rate-limit record as check"

  out=$(FM_HOME="$home" "$TOOL" disarm demo)
  assert_contains "$out" "disarmed: state/midtask-demo.check.sh" "disarm reports the removed path"
  assert_absent "$shim" "disarm removes the shim"
  assert_absent "$trust" "disarm removes the trust binding"
  assert_absent "$record" "disarm removes the rate-limit record"
  pass "fm-midtask-escalation: arm registers a collision-free per-task check; disarm removes everything it wrote"
}

test_arm_refuses_without_a_recorded_task() {
  local home err rc
  home=$(make_home noarm)
  err=$(FM_HOME="$home" "$TOOL" arm ghost 2>&1 >/dev/null)
  rc=$?
  assert_not_equals 0 "$rc" "arm refuses a task id with no recorded meta"
  assert_contains "$err" "no recorded task" "the refusal names the reason"
  assert_absent "$home/state/midtask-ghost.check.sh" "no shim is left behind by a refused arm"
  pass "fm-midtask-escalation: arm refuses to watch a task that was never recorded"
}

test_arm_refuses_a_secondmate() {
  local home err rc
  home=$(make_home armmate)
  fm_write_meta "$home/state/mate.meta" "kind=secondmate" "worktree=$(make_worktree)" "branch=fm/demo"
  err=$(FM_HOME="$home" "$TOOL" arm mate 2>&1 >/dev/null)
  rc=$?
  assert_not_equals 0 "$rc" "arm refuses a secondmate"
  assert_contains "$err" "secondmate" "the refusal names the reason"
  assert_absent "$home/state/midtask-mate.check.sh" "no shim is left behind for a secondmate"
  pass "fm-midtask-escalation: arm refuses to watch a secondmate"
}

test_bad_threshold_env_is_a_usage_error() {
  local home err rc
  home=$(make_home badenv)
  write_meta "$home" demo >/dev/null
  err=$(FM_HOME="$home" FM_MIDTASK_ROUND_THRESHOLD=nope PATH="$(no_nm_path)" "$TOOL" check demo 2>&1 >/dev/null)
  rc=$?
  assert_equals 2 "$rc" "a non-numeric threshold override is a usage error, not a silent default"
  assert_contains "$err" "FM_MIDTASK_ROUND_THRESHOLD" "the error names the offending setting"
  pass "fm-midtask-escalation: malformed threshold overrides are refused, not guessed around"
}

test_help_and_usage
test_missing_meta_prints_nothing
test_secondmate_is_skipped
test_repeated_blocked_reports_suggest_up_and_rate_limit
test_a_later_blocked_episode_with_the_same_count_re_suggests
test_resolved_clears_the_blocked_streak
test_declared_pause_does_not_count_as_stall
test_old_failed_state_suggests_up
test_parked_and_unknown_do_not_count_as_stall
test_unfired_evidence_drift_does_not_re_suggest
test_nm_round_threshold_suggests_up
test_ci_only_rounds_never_suggest_up
test_mixed_rounds_count_only_the_review_rounds
test_clean_healthy_task_gets_no_suggestion
test_arm_uses_a_distinct_check_id_and_disarm_removes_everything
test_arm_refuses_without_a_recorded_task
test_arm_refuses_a_secondmate
test_bad_threshold_env_is_a_usage_error
