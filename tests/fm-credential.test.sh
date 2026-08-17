#!/usr/bin/env bash
# Behavior and sentinel leak tests for the credential policy and Wrangler adapter.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CREDENTIAL="$ROOT/bin/fm-credential.sh"
TMP_ROOT=$(fm_test_tmproot fm-credential)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
RUN_RC=0
RUN_OUT=
RUN_ERR=

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/config" "$dir/home/state" "$dir/home/data" \
    "$dir/home/projects/dash.lifelinevending.com" "$dir/worktree" \
    "$dir/fakebin" "$dir/backend" "$dir/ambient/.config/.wrangler/config"
  chmod 0700 "$dir/home/config" "$dir/home/state" "$dir/home/data" "$dir/backend"
  printf 'ambient oauth must not be visible\n' > "$dir/ambient/.config/.wrangler/config/default.toml"
  : > "$dir/provider.log"
  : > "$dir/broker.log"
  : > "$dir/argv.log"
  : > "$dir/pane.log"
  printf 'ok\n' > "$dir/behavior"
  cat > "$dir/fakebin/op" <<'SH'
#!/usr/bin/env bash
case_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd -P)
[ "${OP_SERVICE_ACCOUNT_TOKEN:-}" = broker-bootstrap-marker ] || exit 96
[ -z "${OP_SESSION:-}" ] && [ -z "${FM_TEST_CASE:-}" ] || exit 97
printf 'restricted-broker-identity\n' >> "$case_dir/broker.log"
case "${1:-}" in
  read)
    [ "$(cat "$case_dir/behavior")" != missing ] || exit 44
    cat "$case_dir/backend/secret"
    ;;
  whoami) exit 0 ;;
  *) exit 2 ;;
esac
SH
  cat > "$dir/fakebin/wrangler" <<'SH'
#!/usr/bin/env bash
case_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd -P)
token=${CLOUDFLARE_API_TOKEN:-}
expected=$(cat "$case_dir/backend/secret")
argv=$(ps -ww -p $$ -o command= 2>/dev/null || true)
case "$argv" in
  *"$token"*) printf 'token-in-argv\n' >> "$case_dir/provider.log"; exit 90 ;;
esac
[ -n "$token" ] && [ "$token" = "$expected" ] || exit 91
[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && [ -z "${OP_SESSION:-}" ] || exit 92
[ "${CLOUDFLARE_ENV:-}" = production ] || exit 93
[ ! -e "$HOME/.config/.wrangler/config/default.toml" ] || exit 94
[ -z "${CLOUDFLARE_API_BASE_URL:-}" ] && [ -z "${WRANGLER_LOG_PATH:-}" ] || exit 95
[ -z "${WRANGLER_LOG_SANITIZE:-}" ] && [ -z "${FM_TEST_CASE:-}" ] || exit 98
printf 'argv-clean token-present isolated-home operation=%s\n' "${1:-}" >> "$case_dir/provider.log"
printf '%s\n' "$*" >> "$case_dir/argv.log"
behavior=$(cat "$case_dir/behavior")
case "$behavior" in
  invalid) printf 'Invalid API Token\n' >&2; exit 41 ;;
  revoked) printf 'API token revoked or expired\n' >&2; exit 45 ;;
  insufficient) printf 'insufficient scope for deployment\n' >&2; exit 42 ;;
  outage) printf 'network connection refused\n' >&2; exit 43 ;;
  leak)
    printf 'provider stdout %s\n' "$token"
    printf 'provider stderr %s\n' "$token" >&2
    ;;
  boundary)
    head -c 65530 /dev/zero | tr '\0' x
    printf '%s\n' "$token"
    ;;
  compression-boundary)
    repeats=300
    index=0
    while [ "$index" -lt "$repeats" ]; do
      printf '%s' "$token"
      index=$((index + 1))
    done
    repeated_bytes=$((repeats * ${#token}))
    fill=$((65536 + 8192 - 5 - repeated_bytes))
    head -c "$fill" /dev/zero | tr '\0' x
    printf '%s\n' "$token"
    ;;
  large)
    head -c 70000 /dev/zero | tr '\0' x
    printf '\n'
    ;;
  actual-fail)
    if [ "${1:-}" = deploy ]; then
      printf 'deployment failed\n' >&2
      exit 37
    fi
    printf 'whoami ok\n'
    ;;
  concurrent) sleep 0.2 ;;
  *) printf '%s ok\n' "${1:-unknown}" ;;
esac
SH
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd -P)
printf '%s\n' "$*" >> "$case_dir/pane.log"
exit 99
SH
  chmod +x "$dir/fakebin/op" "$dir/fakebin/wrangler" "$dir/fakebin/tmux"
  write_policy "$dir"
  write_task "$dir" ship dash.lifelinevending.com
  printf '%s\n' "$dir"
}

write_policy() {
  local dir=$1 operations=${2:-'"deploy", "deploy-dry-run", "whoami"'} expires=${3:-null}
  cat > "$dir/home/config/credentials.json" <<JSON
{
  "version": 1,
  "aliases": {
    "dash.cloudflare.deploy": {
      "adapter": "cloudflare-wrangler",
      "project": "dash.lifelinevending.com",
      "environment": "production",
      "reference": "op://vault-id/item-id/field-id",
      "delivery": "env:CLOUDFLARE_API_TOKEN",
      "operations": [$operations],
      "expires_at": $expires,
      "captain_only_rotation": true
    }
  }
}
JSON
  chmod 0600 "$dir/home/config/credentials.json"
}

write_task() {
  local dir=$1 kind=$2 project=$3
  mkdir -p "$dir/home/projects/$project"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "project=$dir/home/projects/$project" \
    "kind=$kind" \
    "worktree=$dir/worktree"
  chmod 0600 "$dir/home/state/task-a.meta"
}

set_secret() {
  local dir=$1
  SENTINEL="cf-sentinel-$RANDOM-$$-$(date +%s%N)"
  printf '%s\n' "$SENTINEL" > "$dir/backend/secret"
  chmod 0600 "$dir/backend/secret"
}

run_case() {
  local dir=$1
  shift
  RUN_OUT_FILE="$dir/run.stdout"
  RUN_ERR_FILE="$dir/run.stderr"
  FM_HOME="$dir/home" HOME="$dir/ambient" FM_TEST_CASE="$dir" \
    OP_SERVICE_ACCOUNT_TOKEN=broker-bootstrap-marker \
    CLOUDFLARE_API_BASE_URL=https://attacker.invalid \
    WRANGLER_LOG_PATH="$dir/hostile.log" WRANGLER_LOG_SANITIZE=false \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$CREDENTIAL" "$@" > "$RUN_OUT_FILE" 2> "$RUN_ERR_FILE"
  RUN_RC=$?
  RUN_OUT=$(cat "$RUN_OUT_FILE")
  RUN_ERR=$(cat "$RUN_ERR_FILE")
}

assert_no_runtime_residue() {
  local dir=$1
  if find "$dir/home/state" -maxdepth 1 -name '.fm-credential.*' -print | grep . >/dev/null; then
    fail "credential runtime residue remained after command completion"
  fi
}

assert_sentinel_absent_after_backend_cleanup() {
  local dir=$1
  rm -f "$dir/backend/secret"
  ! grep -R -F -- "$SENTINEL" "$dir/home" "$dir/worktree" "$dir/provider.log" \
      "$dir/argv.log" "$dir/run.stdout" "$dir/run.stderr" >/dev/null 2>&1 \
    || fail "sentinel leaked into task records, logs, output, or residue"
  ! grep -R -F -- "$SENTINEL" "$ROOT" >/dev/null 2>&1 \
    || fail "sentinel leaked into a repository file"
}

test_doctor_status_and_command_scoped_delivery() {
  local dir identity_dir missing_project_dir project_provider_dir
  dir=$(make_case ready)
  set_secret "$dir"
  run_case "$dir" doctor
  expect_code 0 "$RUN_RC" "doctor should report a valid ready policy"
  assert_contains "$RUN_OUT" "credential dash.cloudflare.deploy: available" \
    "doctor did not report the ready alias"
  assert_not_contains "$RUN_OUT$RUN_ERR" "$SENTINEL" "doctor printed the sentinel"
  run_case "$dir" status dash.cloudflare.deploy
  expect_code 0 "$RUN_RC" "status should report an available credential"
  assert_contains "$RUN_OUT" "credential dash.cloudflare.deploy: available" \
    "status did not report availability"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- deploy-dry-run
  expect_code 0 "$RUN_RC" "approved dry-run should execute"
  assert_grep 'argv-clean token-present isolated-home operation=deploy' "$dir/provider.log" \
    "Wrangler did not receive the exact scoped environment in an isolated auth home"
  assert_grep 'deploy --dry-run' "$dir/argv.log" "adapter did not own the dry-run argv"
  assert_grep 'exit_class=success' "$dir/home/state/credential-audit.log" \
    "successful execution did not append non-secret audit metadata"
  [ ! -e "$dir/hostile.log" ] || fail "Wrangler inherited the caller's log path"
  [ ! -s "$dir/pane.log" ] || fail "credential broker used a pane or terminal transport"
  assert_no_runtime_residue "$dir"
  assert_sentinel_absent_after_backend_cleanup "$dir"
  identity_dir=$(make_case missing-identity)
  set_secret "$identity_dir"
  RUN_OUT_FILE="$identity_dir/run.stdout"
  RUN_ERR_FILE="$identity_dir/run.stderr"
  env -u OP_SERVICE_ACCOUNT_TOKEN FM_HOME="$identity_dir/home" HOME="$identity_dir/ambient" \
    OP_SESSION=ambient-personal-session PATH="$identity_dir/fakebin:$BASE_PATH" \
    "$CREDENTIAL" status dash.cloudflare.deploy > "$RUN_OUT_FILE" 2> "$RUN_ERR_FILE"
  RUN_RC=$?
  expect_code 5 "$RUN_RC" "ambient 1Password identity must not satisfy the broker"
  assert_contains "$(cat "$RUN_OUT_FILE")" ': missing-backend' \
    "missing broker identity was not classified as unavailable"
  [ ! -s "$identity_dir/broker.log" ] || fail "ambient identity reached the 1Password adapter"
  rm -f "$identity_dir/backend/secret"
  missing_project_dir=$(make_case missing-project)
  set_secret "$missing_project_dir"
  rmdir "$missing_project_dir/home/projects/dash.lifelinevending.com"
  run_case "$missing_project_dir" status dash.cloudflare.deploy
  expect_code 5 "$RUN_RC" "status should reject an unregistered alias project"
  assert_contains "$RUN_OUT" ': missing-project' "status reported a missing project as available"
  [ ! -s "$missing_project_dir/broker.log" ] || fail "status probed a credential before project binding"
  run_case "$missing_project_dir" doctor
  expect_code 1 "$RUN_RC" "doctor should not be ready with an unregistered alias project"
  assert_contains "$RUN_OUT" ': missing-project' "doctor omitted the missing project classification"
  rm -f "$missing_project_dir/backend/secret"
  project_provider_dir=$(make_case project-provider)
  set_secret "$project_provider_dir"
  mkdir -p "$project_provider_dir/home/projects/dash.lifelinevending.com/node_modules/.bin"
  cp "$project_provider_dir/fakebin/wrangler" "$project_provider_dir/backend/wrangler-provider"
  cat > "$project_provider_dir/home/projects/dash.lifelinevending.com/node_modules/.bin/wrangler" <<'SH'
#!/usr/bin/env bash
case_dir=$(CDPATH='' cd -- "$(dirname "$0")/../../../../.." && pwd -P)
exec "$case_dir/backend/wrangler-provider" "$@"
SH
  chmod +x "$project_provider_dir/home/projects/dash.lifelinevending.com/node_modules/.bin/wrangler"
  rm "$project_provider_dir/fakebin/wrangler"
  run_case "$project_provider_dir" status dash.cloudflare.deploy
  expect_code 0 "$RUN_RC" "status should discover Wrangler in the registered project"
  assert_contains "$RUN_OUT" ': available' "project-local Wrangler did not satisfy readiness"
  assert_sentinel_absent_after_backend_cleanup "$project_provider_dir"
  pass "doctor, status, and dry-run use command-scoped delivery without leaks or OAuth fallback"
}

test_output_redaction_bound_and_exit_status() {
  local dir size sentinel_prefix
  dir=$(make_case output)
  set_secret "$dir"
  printf 'leak\n' > "$dir/behavior"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- deploy
  expect_code 0 "$RUN_RC" "redacted provider command should preserve success"
  assert_contains "$RUN_OUT$RUN_ERR" '[REDACTED]' "provider output was not redacted"
  assert_not_contains "$RUN_OUT$RUN_ERR" "$SENTINEL" "provider output leaked the sentinel"
  printf 'boundary\n' > "$dir/behavior"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- deploy
  expect_code 0 "$RUN_RC" "boundary redaction should preserve success"
  sentinel_prefix=${SENTINEL:0:8}
  assert_contains "$RUN_OUT" '[output truncated at 65536 bytes]' \
    "boundary output did not retain the truncation marker"
  assert_not_contains "$RUN_OUT" "$sentinel_prefix" "token prefix leaked at the output boundary"
  printf 'compression-boundary\n' > "$dir/behavior"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- deploy
  expect_code 0 "$RUN_RC" "compressed boundary redaction should preserve success"
  assert_contains "$RUN_OUT" '[REDACTED]' "compressed boundary tokens were not redacted"
  assert_not_contains "$RUN_OUT" "${SENTINEL:0:5}" \
    "token prefix leaked after earlier redactions compressed the stream"
  printf 'large\n' > "$dir/behavior"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- whoami
  expect_code 0 "$RUN_RC" "large provider output should preserve success"
  assert_contains "$RUN_OUT" '[output truncated at 65536 bytes]' "large output was not bounded"
  size=$(wc -c < "$dir/run.stdout" | tr -d '[:space:]')
  [ "$size" -lt 66000 ] || fail "bounded provider output exceeded the expected cap"
  printf 'actual-fail\n' > "$dir/behavior"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- deploy
  expect_code 37 "$RUN_RC" "broker must preserve the real provider exit status"
  assert_grep 'exit_class=provider-failure' "$dir/home/state/credential-audit.log" \
    "provider failure was not classified in the audit"
  assert_no_runtime_residue "$dir"
  assert_sentinel_absent_after_backend_cleanup "$dir"
  pass "output is bounded and redacted without masking the real provider status"
}

test_policy_file_safety_and_schema() {
  local dir outside
  dir=$(make_case policy-safety)
  set_secret "$dir"
  chmod 0644 "$dir/home/config/credentials.json"
  run_case "$dir" status dash.cloudflare.deploy
  [ "$RUN_RC" -ne 0 ] || fail "unsafe policy mode was accepted"
  chmod 0600 "$dir/home/config/credentials.json"
  outside="$dir/outside-policy"
  cp "$dir/home/config/credentials.json" "$outside"
  rm "$dir/home/config/credentials.json"
  ln -s "$outside" "$dir/home/config/credentials.json"
  run_case "$dir" status dash.cloudflare.deploy
  [ "$RUN_RC" -ne 0 ] || fail "symlink policy was accepted"
  rm "$dir/home/config/credentials.json"
  cp "$outside" "$dir/home/config/credentials.json"
  chmod 0600 "$dir/home/config/credentials.json"
  ln "$dir/home/config/credentials.json" "$dir/policy-hardlink"
  run_case "$dir" status dash.cloudflare.deploy
  [ "$RUN_RC" -ne 0 ] || fail "hardlinked policy was accepted"
  rm "$dir/policy-hardlink"
  cat > "$dir/home/config/credentials.json" <<'JSON'
{"version":1,"aliases":{"same":{"adapter":"cloudflare-wrangler"},"same":{"adapter":"cloudflare-wrangler"}}}
JSON
  chmod 0600 "$dir/home/config/credentials.json"
  run_case "$dir" doctor
  [ "$RUN_RC" -ne 0 ] || fail "duplicate alias was accepted"
  assert_contains "$RUN_ERR" 'duplicate key' "duplicate alias refusal was not actionable"
  write_policy "$dir"
  python3 - "$dir/home/config/credentials.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["aliases"]["dash.cloudflare.deploy"]["command"] = "sh -c anything"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
  chmod 0600 "$dir/home/config/credentials.json"
  run_case "$dir" doctor
  [ "$RUN_RC" -ne 0 ] || fail "free-form command key was accepted"
  assert_sentinel_absent_after_backend_cleanup "$dir"
  pass "policy validation rejects unsafe files, duplicate aliases, and free-form command data"
}

test_policy_scope_and_secret_heuristic() {
  local dir
  dir=$(make_case policy-scope)
  set_secret "$dir"
  python3 - "$dir/home/config/credentials.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["aliases"]["dash.cloudflare.deploy"]["adapter"] = "unknown-adapter"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
  chmod 0600 "$dir/home/config/credentials.json"
  run_case "$dir" doctor
  [ "$RUN_RC" -ne 0 ] || fail "unknown adapter was accepted"
  write_policy "$dir"
  python3 - "$dir/home/config/credentials.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
data["aliases"]["dash.cloudflare.deploy"]["reference"] = "op://vault/item/sk-test_abcdefghijklmnopqrstuvwxyz"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
  chmod 0600 "$dir/home/config/credentials.json"
  run_case "$dir" doctor
  [ "$RUN_RC" -ne 0 ] || fail "secret-looking inline value was accepted"
  write_policy "$dir"
  printf 'secondmate-a\n' > "$dir/home/.fm-secondmate-home"
  chmod 0600 "$dir/home/.fm-secondmate-home"
  printf -- '- another.project - mode: no-mistakes\n' > "$dir/home/data/projects.md"
  chmod 0600 "$dir/home/data/projects.md"
  run_case "$dir" doctor
  [ "$RUN_RC" -ne 0 ] || fail "secondmate policy escaped its registered projects"
  assert_contains "$RUN_ERR" 'unregistered project' "secondmate scope refusal was not actionable"
  assert_sentinel_absent_after_backend_cleanup "$dir"
  pass "policy validation rejects unknown adapters, inline tokens, and secondmate scope escape"
}

test_task_and_operation_denials() {
  local dir rejected_operation
  dir=$(make_case denials)
  set_secret "$dir"
  run_case "$dir" exec task-a unknown.alias -- whoami
  [ "$RUN_RC" -ne 0 ] || fail "unknown alias was accepted"
  write_task "$dir" ship another.project
  run_case "$dir" exec task-a dash.cloudflare.deploy -- whoami
  [ "$RUN_RC" -ne 0 ] || fail "wrong task project was accepted"
  write_task "$dir" scout dash.lifelinevending.com
  run_case "$dir" exec task-a dash.cloudflare.deploy -- whoami
  [ "$RUN_RC" -ne 0 ] || fail "wrong task kind was accepted"
  write_task "$dir" ship dash.lifelinevending.com
  write_policy "$dir" '"whoami"'
  run_case "$dir" exec task-a dash.cloudflare.deploy -- deploy
  expect_code 2 "$RUN_RC" "ungranted operation should be a policy denial"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- env
  expect_code 2 "$RUN_RC" "env must not be an adapter operation"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- get
  expect_code 2 "$RUN_RC" "raw get must not be an adapter operation"
  assert_grep $'operation=invalid\t' "$dir/home/state/credential-audit.log" \
    "unrecognized operation was not canonicalized in the audit"
  rejected_operation=$'unrecognized\tsecret-looking-input\nforged=true'
  run_case "$dir" exec task-a dash.cloudflare.deploy -- "$rejected_operation"
  expect_code 2 "$RUN_RC" "unsafe operation text must be rejected"
  assert_not_contains "$(cat "$dir/home/state/credential-audit.log")" "$rejected_operation" \
    "caller-controlled operation text entered the audit"
  assert_not_contains "$(cat "$dir/home/state/credential-audit.log")" 'forged=true' \
    "caller-controlled operation text forged an audit entry"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- whoami --env staging
  expect_code 2 "$RUN_RC" "caller must not override the policy environment"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- deploy -e staging
  expect_code 2 "$RUN_RC" "Wrangler's environment alias must be rejected"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- deploy -c alternate.toml
  expect_code 2 "$RUN_RC" "Wrangler's config alias must be rejected"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- deploy --name other-worker
  expect_code 2 "$RUN_RC" "caller must not override the worker name"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- deploy-dry-run --no-dry-run
  expect_code 2 "$RUN_RC" "caller must not negate the adapter-owned dry-run flag"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- whoami sh -c printenv
  expect_code 2 "$RUN_RC" "shell and environment escape arguments must be denied"
  assert_no_runtime_residue "$dir"
  assert_sentinel_absent_after_backend_cleanup "$dir"
  pass "task identity, environment, and adapter allowlists fail closed"
}

test_missing_expired_and_provider_failures() {
  local dir no_backend expires_soon
  dir=$(make_case failures)
  set_secret "$dir"
  write_policy "$dir" '"deploy", "whoami"' '"2000-01-01T00:00:00Z"'
  run_case "$dir" status dash.cloudflare.deploy
  expect_code 4 "$RUN_RC" "expired policy metadata should fail before backend use"
  assert_contains "$RUN_OUT" ': expired' "expired status was not classified"
  expires_soon=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=10)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
  write_policy "$dir" '"deploy", "whoami"' "\"$expires_soon\""
  run_case "$dir" status dash.cloudflare.deploy
  expect_code 0 "$RUN_RC" "approaching static-token expiry should remain usable"
  assert_contains "$RUN_OUT" ': available-expiring' "approaching expiry did not alert ahead"
  write_policy "$dir" '"deploy", "whoami"'
  printf 'missing\n' > "$dir/behavior"
  run_case "$dir" status dash.cloudflare.deploy
  expect_code 44 "$RUN_RC" "missing 1Password value should preserve backend status"
  assert_contains "$RUN_OUT" ': missing' "missing credential was not classified"
  printf 'invalid\n' > "$dir/behavior"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- deploy
  expect_code 41 "$RUN_RC" "invalid token preflight should preserve provider status"
  assert_contains "$RUN_ERR" 'credential-invalid' "invalid token was not distinguished"
  printf 'revoked\n' > "$dir/behavior"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- deploy
  expect_code 45 "$RUN_RC" "revoked token preflight should preserve provider status"
  assert_contains "$RUN_ERR" 'credential-revoked-or-expired' "revoked token was not distinguished"
  printf 'insufficient\n' > "$dir/behavior"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- deploy
  expect_code 42 "$RUN_RC" "insufficient scope should preserve provider status"
  assert_contains "$RUN_ERR" 'insufficient-scope' "insufficient scope was not distinguished"
  printf 'outage\n' > "$dir/behavior"
  run_case "$dir" exec task-a dash.cloudflare.deploy -- deploy
  expect_code 43 "$RUN_RC" "provider outage should preserve provider status"
  assert_contains "$RUN_ERR" 'network-failure' "provider outage was not distinguished"
  no_backend=$(make_case no-backend)
  set_secret "$no_backend"
  rm "$no_backend/fakebin/op"
  run_case "$no_backend" status dash.cloudflare.deploy
  expect_code 5 "$RUN_RC" "missing 1Password executable should be a backend refusal"
  assert_contains "$RUN_OUT" ': missing-backend' "missing backend was not classified"
  rm -f "$no_backend/backend/secret"
  assert_no_runtime_residue "$dir"
  assert_sentinel_absent_after_backend_cleanup "$dir"
  pass "missing, expired, invalid, insufficient-scope, and outage states stay distinct"
}

test_concurrent_uses_and_cleanup() {
  local dir rc1 rc2
  dir=$(make_case concurrent)
  set_secret "$dir"
  printf 'concurrent\n' > "$dir/behavior"
  FM_HOME="$dir/home" HOME="$dir/ambient" FM_TEST_CASE="$dir" \
    OP_SERVICE_ACCOUNT_TOKEN=broker-bootstrap-marker PATH="$dir/fakebin:$BASE_PATH" \
    CLOUDFLARE_API_BASE_URL=https://attacker.invalid WRANGLER_LOG_PATH="$dir/hostile.log" \
    "$CREDENTIAL" exec task-a dash.cloudflare.deploy -- whoami > "$dir/one.out" 2> "$dir/one.err" &
  pid1=$!
  FM_HOME="$dir/home" HOME="$dir/ambient" FM_TEST_CASE="$dir" \
    OP_SERVICE_ACCOUNT_TOKEN=broker-bootstrap-marker PATH="$dir/fakebin:$BASE_PATH" \
    CLOUDFLARE_API_BASE_URL=https://attacker.invalid WRANGLER_LOG_PATH="$dir/hostile.log" \
    "$CREDENTIAL" exec task-a dash.cloudflare.deploy -- whoami > "$dir/two.out" 2> "$dir/two.err" &
  pid2=$!
  wait "$pid1"; rc1=$?
  wait "$pid2"; rc2=$?
  expect_code 0 "$rc1" "first concurrent credential use"
  expect_code 0 "$rc2" "second concurrent credential use"
  [ "$(grep -c 'exit_class=success' "$dir/home/state/credential-audit.log")" -eq 2 ] \
    || fail "concurrent audit appends were incomplete or interleaved"
  assert_not_contains "$(cat "$dir/one.out" "$dir/one.err" "$dir/two.out" "$dir/two.err")" \
    "$SENTINEL" "concurrent output leaked the sentinel"
  assert_no_runtime_residue "$dir"
  RUN_OUT_FILE="$dir/one.out"
  RUN_ERR_FILE="$dir/one.err"
  assert_sentinel_absent_after_backend_cleanup "$dir"
  pass "concurrent uses retain separate runtimes, complete audit lines, and no residue"
}

test_doctor_status_and_command_scoped_delivery
test_output_redaction_bound_and_exit_status
test_policy_file_safety_and_schema
test_policy_scope_and_secret_heuristic
test_task_and_operation_denials
test_missing_expired_and_provider_failures
test_concurrent_uses_and_cleanup
