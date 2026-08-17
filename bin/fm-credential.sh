#!/usr/bin/env bash
# Validate Firstmate's private credential policy and execute one fixed provider
# operation with a command-scoped credential.
#
# The policy contract and trust model are owned by docs/credentials.md.
# This header owns the command mechanics and exit behavior.
#
# Usage:
#   fm-credential.sh doctor
#   fm-credential.sh status <alias>
#   fm-credential.sh exec <task-id> <alias> -- <adapter-operation>
#
# There is deliberately no plaintext retrieval command.
# doctor and status print classifications only.
# exec returns the provider command's real exit status after bounded exact-value
# redaction, or a broker refusal status before the provider command starts.
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME_INPUT="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

OUTPUT_LIMIT=65536
MAX_SECRET_BYTES=8192
EXPIRY_WARNING_SECONDS=2592000
FM_CREDENTIAL_HOME=
FM_CREDENTIAL_POLICY=
FM_CREDENTIAL_RUNTIME=
FM_CREDENTIAL_SECRET=
FM_CREDENTIAL_WRANGLER=
FM_CREDENTIAL_STDOUT=
FM_CREDENTIAL_STDERR=
FM_CREDENTIAL_RC=0

usage() {
  sed -n '2,16{s/^# \{0,1\}//;p;}' "$0" >&2
}

fail() {
  printf 'fm-credential: %s\n' "$*" >&2
  return 1
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

file_owner() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %u "$1" 2>/dev/null
  else
    stat -c %u "$1" 2>/dev/null
  fi
}

file_links() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

regular_file_safe() { # <path> <policy|record>
  local path=$1 class=$2 mode owner links
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  owner=$(file_owner "$path") || return 1
  links=$(file_links "$path") || return 1
  mode=$(file_mode "$path") || return 1
  [ "$owner" = "$(id -u)" ] || return 1
  [ "$links" = 1 ] || return 1
  case "$class:$mode" in
    policy:400|policy:600) return 0 ;;
    record:400|record:600|record:640|record:644) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_home() {
  local home config config_real
  [ -d "$FM_HOME_INPUT" ] && [ ! -L "$FM_HOME_INPUT" ] || {
    fail "effective FM_HOME is not a regular directory"
    return 1
  }
  home=$(CDPATH='' cd -- "$FM_HOME_INPUT" 2>/dev/null && pwd -P) || {
    fail "effective FM_HOME cannot be resolved"
    return 1
  }
  config="$home/config"
  [ -d "$config" ] && [ ! -L "$config" ] || {
    fail "credential policy directory is missing or unsafe"
    return 1
  }
  config_real=$(CDPATH='' cd -- "$config" 2>/dev/null && pwd -P) || {
    fail "credential policy directory cannot be resolved"
    return 1
  }
  [ "$config_real" = "$home/config" ] || {
    fail "credential policy path resolves outside the effective FM_HOME"
    return 1
  }
  FM_CREDENTIAL_HOME=$home
  FM_CREDENTIAL_POLICY="$config_real/credentials.json"
}

json_has_no_duplicate_keys() {
  python3 - "$1" <<'PY'
import json
import sys


def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        json.load(handle, object_pairs_hook=reject_duplicates)
except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError):
    raise SystemExit(1)
PY
}

policy_schema_error() {
  jq -r '
    def exact_keys($wanted): (keys | sort) == ($wanted | sort);
    def atom: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
    def secret_looking:
      test("(?i)(sk[-_][A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|eyJ[A-Za-z0-9_-]{10,}\\.eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,})");
    def alias_keys:
      ["adapter", "project", "environment", "reference", "delivery", "operations", "expires_at", "captain_only_rotation"];
    if type != "object" then "top level must be an object"
    elif (exact_keys(["version", "aliases"]) | not) then "top level contains unknown or missing keys"
    elif .version != 1 then "version must be 1"
    elif (.aliases | type) != "object" then "aliases must be an object"
    elif any(.aliases | to_entries[]; (.key | atom) | not) then "alias names must be exact atoms"
    elif any(.aliases | to_entries[]; (.value | type) != "object") then "each alias must be an object"
    elif any(.aliases | to_entries[]; (.value | exact_keys(alias_keys)) | not) then "an alias contains unknown or missing keys"
    elif any(.aliases[]; .adapter != "cloudflare-wrangler") then "unknown adapter"
    elif any(.aliases[]; (.project | atom) | not) then "each alias needs an exact project"
    elif any(.aliases[]; (.environment | atom) | not) then "each alias needs an exact environment"
    elif any(.aliases[]; (.reference | type) != "string" or ((.reference | test("^op://[^/[:space:]]+/[^/[:space:]]+/[^/[:space:]]+$")) | not)) then "reference must be an exact 1Password secret reference"
    elif any(.aliases[]; .delivery != "env:CLOUDFLARE_API_TOKEN") then "unsupported delivery channel"
    elif any(.aliases[]; (.operations | type) != "array" or (.operations | length) == 0) then "operations must be a non-empty array"
    elif any(.aliases[]; any(.operations[]; . as $operation | type != "string" or (["deploy", "deploy-dry-run", "whoami"] | index($operation) | not))) then "unknown adapter operation"
    elif any(.aliases[]; (.operations | unique | length) != (.operations | length)) then "operations must not contain duplicates"
    elif any(.aliases[]; (.expires_at != null) and ((.expires_at | type) != "string" or ((.expires_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) | not) or ((try (.expires_at | fromdateiso8601) catch null) == null))) then "expires_at must be null or a UTC RFC3339 timestamp"
    elif any(.aliases[]; .captain_only_rotation != true) then "Cloudflare token rotation must remain captain-only"
    elif any(.. | strings; secret_looking) then "policy contains a secret-looking inline value"
    else ""
    end
  ' "$1" 2>/dev/null
}

secondmate_policy_valid() {
  local marker registry project
  marker="$FM_CREDENTIAL_HOME/.fm-secondmate-home"
  [ ! -e "$marker" ] && [ ! -L "$marker" ] && return 0
  regular_file_safe "$marker" record || {
    fail "secondmate identity marker is unsafe"
    return 1
  }
  registry="$FM_CREDENTIAL_HOME/data/projects.md"
  regular_file_safe "$registry" record || {
    fail "secondmate project registry is missing or unsafe"
    return 1
  }
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    awk -v wanted="$project" '$1 == "-" && $2 == wanted { found=1 } END { exit !found }' "$registry" || {
      fail "secondmate credential policy grants an unregistered project"
      return 1
    }
  done < <(jq -r '[.aliases[].project] | unique[]' "$FM_CREDENTIAL_POLICY")
}

validate_policy() {
  local error
  resolve_home || return 1
  command -v jq >/dev/null 2>&1 || {
    fail "jq is required to validate credential policy"
    return 1
  }
  command -v python3 >/dev/null 2>&1 || {
    fail "python3 is required to reject duplicate policy keys"
    return 1
  }
  regular_file_safe "$FM_CREDENTIAL_POLICY" policy || {
    fail "config/credentials.json must be an owned, single-link, mode-0400 or mode-0600 regular file"
    return 1
  }
  json_has_no_duplicate_keys "$FM_CREDENTIAL_POLICY" || {
    fail "config/credentials.json is malformed or contains a duplicate key"
    return 1
  }
  error=$(policy_schema_error "$FM_CREDENTIAL_POLICY") || {
    fail "config/credentials.json is malformed"
    return 1
  }
  [ -z "$error" ] || {
    fail "config/credentials.json is invalid: $error"
    return 1
  }
  secondmate_policy_valid
}

alias_load() { # <alias>
  local alias=$1 data
  case "$alias" in
    ''|*[!A-Za-z0-9._-]*) fail "invalid credential alias"; return 1 ;;
  esac
  data=$(jq -r --arg alias "$alias" '
    .aliases[$alias]
    | if . == null then empty else
        [.adapter, .project, .environment, .reference, .delivery,
         (.expires_at // "__NONE__"), (.captain_only_rotation | tostring)]
        | @tsv
      end
  ' "$FM_CREDENTIAL_POLICY") || return 1
  [ -n "$data" ] || {
    fail "unknown credential alias"
    return 1
  }
  IFS=$'\t' read -r ALIAS_ADAPTER ALIAS_PROJECT ALIAS_ENVIRONMENT ALIAS_REFERENCE \
    ALIAS_DELIVERY ALIAS_EXPIRES_AT ALIAS_ROTATION <<< "$data"
  [ "$ALIAS_EXPIRES_AT" != __NONE__ ] || ALIAS_EXPIRES_AT=
  [ "$ALIAS_DELIVERY" = env:CLOUDFLARE_API_TOKEN ] && [ "$ALIAS_ROTATION" = true ] || return 1
}

alias_operation_allowed() { # <alias> <operation>
  jq -e --arg alias "$1" --arg operation "$2" \
    '.aliases[$alias].operations | index($operation) != null' \
    "$FM_CREDENTIAL_POLICY" >/dev/null 2>&1
}

alias_expired() {
  local epoch now
  [ -n "$ALIAS_EXPIRES_AT" ] || return 1
  epoch=$(jq -nr --arg value "$ALIAS_EXPIRES_AT" '$value | fromdateiso8601') || return 0
  now=$(date +%s) || return 0
  [ "$now" -ge "$epoch" ]
}

alias_expiring_soon() {
  local epoch now
  [ -n "$ALIAS_EXPIRES_AT" ] || return 1
  epoch=$(jq -nr --arg value "$ALIAS_EXPIRES_AT" '$value | fromdateiso8601') || return 1
  now=$(date +%s) || return 1
  [ "$epoch" -gt "$now" ] && [ "$((epoch - now))" -le "$EXPIRY_WARNING_SECONDS" ]
}

prepare_runtime() {
  local state state_real old_umask
  state="$FM_CREDENTIAL_HOME/state"
  if [ ! -e "$state" ] && [ ! -L "$state" ]; then
    old_umask=$(umask)
    umask 077
    mkdir -p "$state" || {
      umask "$old_umask"
      fail "cannot create credential runtime state directory"
      return 1
    }
    umask "$old_umask"
  fi
  [ -d "$state" ] && [ ! -L "$state" ] || {
    fail "credential runtime state directory is unsafe"
    return 1
  }
  state_real=$(CDPATH='' cd -- "$state" 2>/dev/null && pwd -P) || return 1
  [ "$state_real" = "$FM_CREDENTIAL_HOME/state" ] || {
    fail "credential runtime path resolves outside the effective FM_HOME"
    return 1
  }
  old_umask=$(umask)
  umask 077
  FM_CREDENTIAL_RUNTIME=$(mktemp -d "$state/.fm-credential.XXXXXX") || {
    umask "$old_umask"
    fail "cannot create credential runtime directory"
    return 1
  }
  umask "$old_umask"
  chmod 0700 "$FM_CREDENTIAL_RUNTIME" || return 1
}

credential_cleanup() {
  FM_CREDENTIAL_SECRET=
  unset CLOUDFLARE_API_TOKEN CLOUDFLARE_API_KEY CLOUDFLARE_EMAIL OP_SESSION OP_SERVICE_ACCOUNT_TOKEN 2>/dev/null || true
  if [ -n "$FM_CREDENTIAL_RUNTIME" ] && [ -d "$FM_CREDENTIAL_RUNTIME" ] && [ ! -L "$FM_CREDENTIAL_RUNTIME" ]; then
    rm -rf -- "$FM_CREDENTIAL_RUNTIME"
  fi
  FM_CREDENTIAL_RUNTIME=
}

resolve_secret() {
  local secret_file error_file size rc op_path broker_token broker_home broker_xdg
  secret_file="$FM_CREDENTIAL_RUNTIME/secret"
  error_file="$FM_CREDENTIAL_RUNTIME/op.stderr"
  op_path=$(type -P op 2>/dev/null) || return 127
  broker_token=${OP_SERVICE_ACCOUNT_TOKEN:-}
  [ -n "$broker_token" ] || return 127
  case "$broker_token" in *[[:space:]]*) return 127 ;; esac
  broker_home="$FM_CREDENTIAL_RUNTIME/op-home"
  broker_xdg="$FM_CREDENTIAL_RUNTIME/op-xdg"
  mkdir -p "$broker_home" "$broker_xdg" || return 70
  if /usr/bin/env -i PATH="${PATH:-/usr/bin:/bin}" HOME="$broker_home" XDG_CONFIG_HOME="$broker_xdg" \
      /bin/bash -c '
        IFS= read -r OP_SERVICE_ACCOUNT_TOKEN <&3 || exit 70
        exec 3<&-
        export OP_SERVICE_ACCOUNT_TOKEN
        exec "$1" read "$2"
      ' _ "$op_path" "$ALIAS_REFERENCE" 3<<< "$broker_token" \
      > "$secret_file" 2> "$error_file"; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  size=$(wc -c < "$secret_file" | tr -d '[:space:]') || return 1
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$size" -gt 0 ] && [ "$size" -le "$MAX_SECRET_BYTES" ] || return 1
  FM_CREDENTIAL_SECRET=$(< "$secret_file")
  rm -f -- "$secret_file" "$error_file"
  [ -n "$FM_CREDENTIAL_SECRET" ] || return 1
  case "$FM_CREDENTIAL_SECRET" in *[[:space:]]*) return 1 ;; esac
  case "$FM_CREDENTIAL_SECRET" in *[!A-Za-z0-9._~-]*) return 1 ;; esac
}

resolve_wrangler() { # [worktree]
  local worktree=${1:-} candidate
  if [ -n "$worktree" ]; then
    candidate="$worktree/node_modules/.bin/wrangler"
    if [ -x "$candidate" ]; then
      FM_CREDENTIAL_WRANGLER=$candidate
      return 0
    fi
  fi
  FM_CREDENTIAL_WRANGLER=$(type -P wrangler 2>/dev/null) || return 1
  [ -x "$FM_CREDENTIAL_WRANGLER" ]
}

capture_bounded() { # <fifo> <destination>
  local fifo=$1 destination=$2
  {
    head -c "$((OUTPUT_LIMIT + MAX_SECRET_BYTES + 1))" > "$destination"
    cat >/dev/null
  } < "$fifo"
}

run_wrangler_capture() { # <cwd> <operation> [args...]
  local worktree=$1 operation=$2 stdout_fifo stderr_fifo stdout_pid stderr_pid rc capture_rc=0
  local -a command
  shift 2
  FM_CREDENTIAL_RC=70
  case "$operation" in
    whoami) command=(whoami "$@") ;;
    deploy) command=(deploy "$@") ;;
    deploy-dry-run) command=(deploy --dry-run "$@") ;;
    *) return 2 ;;
  esac
  FM_CREDENTIAL_STDOUT="$FM_CREDENTIAL_RUNTIME/wrangler.stdout"
  FM_CREDENTIAL_STDERR="$FM_CREDENTIAL_RUNTIME/wrangler.stderr"
  stdout_fifo="$FM_CREDENTIAL_RUNTIME/stdout.fifo"
  stderr_fifo="$FM_CREDENTIAL_RUNTIME/stderr.fifo"
  mkfifo "$stdout_fifo" "$stderr_fifo" || return 70
  capture_bounded "$stdout_fifo" "$FM_CREDENTIAL_STDOUT" &
  stdout_pid=$!
  capture_bounded "$stderr_fifo" "$FM_CREDENTIAL_STDERR" &
  stderr_pid=$!
  (
    mkdir -p "$FM_CREDENTIAL_RUNTIME/wrangler-home" "$FM_CREDENTIAL_RUNTIME/xdg" || exit 70
    cd "$worktree" || exit 70
    exec /usr/bin/env -i PATH="${PATH:-/usr/bin:/bin}" \
      HOME="$FM_CREDENTIAL_RUNTIME/wrangler-home" \
      XDG_CONFIG_HOME="$FM_CREDENTIAL_RUNTIME/xdg" \
      CI=1 CLOUDFLARE_ENV="$ALIAS_ENVIRONMENT" \
      CLOUDFLARE_AUTH_USE_KEYRING=false WRANGLER_SEND_METRICS=false \
      /bin/bash -c '
        IFS= read -r CLOUDFLARE_API_TOKEN <&3 || exit 70
        exec 3<&-
        export CLOUDFLARE_API_TOKEN
        exec "$@"
      ' _ "$FM_CREDENTIAL_WRANGLER" "${command[@]}" 3<<< "$FM_CREDENTIAL_SECRET"
  ) > "$stdout_fifo" 2> "$stderr_fifo"
  rc=$?
  wait "$stdout_pid" || capture_rc=1
  wait "$stderr_pid" || capture_rc=1
  rm -f -- "$stdout_fifo" "$stderr_fifo"
  if [ "$capture_rc" -ne 0 ] && [ "$rc" -eq 0 ]; then
    rc=70
  fi
  FM_CREDENTIAL_RC=$rc
}

provider_failure_class() {
  local files=("$FM_CREDENTIAL_STDOUT" "$FM_CREDENTIAL_STDERR")
  if grep -Eiq 'insufficient[[:space:]-]+(scope|permission)|permission denied|forbidden|(^|[^0-9])403([^0-9]|$)' "${files[@]}"; then
    printf '%s\n' insufficient-scope
  elif grep -Eiq 'revoked|expired' "${files[@]}"; then
    printf '%s\n' credential-revoked-or-expired
  elif grep -Eiq 'invalid[[:space:]-]+(api[[:space:]-]+)?token|unauthorized|authentication error|(^|[^0-9])401([^0-9]|$)' "${files[@]}"; then
    printf '%s\n' credential-invalid
  elif grep -Eiq 'network|timed out|timeout|connection (refused|reset)|could not resolve|dns|enotfound|econn' "${files[@]}"; then
    printf '%s\n' network-failure
  else
    printf '%s\n' provider-failure
  fi
}

redact_file() { # <path>
  local path=$1 line prefix suffix raw_size redacted_size
  local redacted="$FM_CREDENTIAL_RUNTIME/redacted-output"
  raw_size=$(wc -c < "$path" | tr -d '[:space:]') || raw_size=0
  : > "$redacted" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    while [[ "$line" == *"$FM_CREDENTIAL_SECRET"* ]]; do
      prefix=${line%%"$FM_CREDENTIAL_SECRET"*}
      suffix=${line#*"$FM_CREDENTIAL_SECRET"}
      line="${prefix}[REDACTED]${suffix}"
    done
    printf '%s\n' "$line" >> "$redacted"
  done < "$path"
  redacted_size=$(wc -c < "$redacted" | tr -d '[:space:]') || redacted_size=0
  if [ "$redacted_size" -gt "$OUTPUT_LIMIT" ]; then
    head -c "$OUTPUT_LIMIT" "$redacted"
  else
    cat "$redacted"
  fi
  if [ "$raw_size" -gt "$OUTPUT_LIMIT" ]; then
    printf '[output truncated at %s bytes]\n' "$OUTPUT_LIMIT"
  fi
  rm -f -- "$redacted"
}

audit_prepare() {
  local audit="$FM_CREDENTIAL_HOME/state/credential-audit.log" old_umask
  if [ ! -e "$audit" ] && [ ! -L "$audit" ]; then
    old_umask=$(umask)
    umask 077
    ( set -C; : > "$audit" ) 2>/dev/null || true
    umask "$old_umask"
  fi
  regular_file_safe "$audit" policy || {
    fail "credential audit log is missing or unsafe"
    return 1
  }
}

audit_append() { # <task> <alias> <adapter> <operation> <started> <class> <code>
  local task=$1 alias=$2 adapter=$3 operation=$4 started=$5 class=$6 code=$7
  local audit="$FM_CREDENTIAL_HOME/state/credential-audit.log" ended
  ended=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  regular_file_safe "$audit" policy || return 1
  printf 'task=%s\talias=%s\tadapter=%s\toperation=%s\tstart=%s\tend=%s\texit_class=%s\texit_code=%s\n' \
    "$task" "$alias" "$adapter" "$operation" "$started" "$ended" "$class" "$code" >> "$audit"
}

alias_project_resolve() {
  local project project_real
  project="$FM_CREDENTIAL_HOME/projects/$ALIAS_PROJECT"
  [ -d "$project" ] && [ ! -L "$project" ] || return 1
  project_real=$(CDPATH='' cd -- "$project" 2>/dev/null && pwd -P) || return 1
  case "$project_real" in
    "$FM_CREDENTIAL_HOME/projects/"*) : ;;
    *) return 1 ;;
  esac
  ALIAS_PROJECT_PATH=$project_real
}

task_metadata_load() { # <task-id>
  local task=$1 meta key count value meta_project_real worktree_real
  case "$task" in ''|*[!A-Za-z0-9._-]*) fail "invalid task id"; return 1 ;; esac
  meta="$FM_CREDENTIAL_HOME/state/$task.meta"
  regular_file_safe "$meta" record || {
    fail "task metadata is missing or unsafe"
    return 1
  }
  for key in project kind worktree; do
    count=$(grep -c "^$key=" "$meta" 2>/dev/null || true)
    [ "$count" -eq 1 ] || {
      fail "task metadata has a missing or ambiguous $key"
      return 1
    }
    value=$(grep "^$key=" "$meta" | cut -d= -f2-)
    [ -n "$value" ] || return 1
    case "$key" in
      project) TASK_PROJECT=$value ;;
      kind) TASK_KIND=$value ;;
      worktree) TASK_WORKTREE=$value ;;
    esac
  done
  [ "$TASK_KIND" = ship ] || {
    fail "credential operations require a ship task"
    return 1
  }
  alias_project_resolve || {
    fail "alias project is not registered in the effective FM_HOME"
    return 1
  }
  [ -d "$TASK_PROJECT" ] && [ ! -L "$TASK_PROJECT" ] || {
    fail "task project path is unavailable or unsafe"
    return 1
  }
  meta_project_real=$(CDPATH='' cd -- "$TASK_PROJECT" 2>/dev/null && pwd -P) || return 1
  [ "$meta_project_real" = "$ALIAS_PROJECT_PATH" ] || {
    fail "task project does not match the credential alias"
    return 1
  }
  [ -d "$TASK_WORKTREE" ] && [ ! -L "$TASK_WORKTREE" ] || {
    fail "task worktree is unavailable or unsafe"
    return 1
  }
  worktree_real=$(CDPATH='' cd -- "$TASK_WORKTREE" 2>/dev/null && pwd -P) || return 1
  TASK_WORKTREE=$worktree_real
}

adapter_args_valid() { # <operation> [args...]
  local operation=$1
  shift
  case "$operation" in
    deploy)
      [ "$#" -eq 0 ] || { fail "deploy does not allow caller arguments"; return 1; }
      ;;
    deploy-dry-run)
      [ "$#" -eq 0 ] || { fail "deploy-dry-run does not allow caller arguments"; return 1; }
      ;;
    whoami)
      [ "$#" -eq 0 ] || { fail "whoami does not allow caller arguments"; return 1; }
      ;;
    *)
      fail "unrecognized adapter operation"
      return 1
      ;;
  esac
}

status_alias() { # <alias> <print-prefix>
  local alias=$1 prefix=$2 class rc
  alias_load "$alias" || return 2
  alias_project_resolve || {
    printf '%s%s: missing-project\n' "$prefix" "$alias"
    return 5
  }
  if alias_expired; then
    printf '%s%s: expired\n' "$prefix" "$alias"
    return 4
  fi
  command -v op >/dev/null 2>&1 || {
    printf '%s%s: missing-backend\n' "$prefix" "$alias"
    return 5
  }
  [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || {
    printf '%s%s: missing-backend\n' "$prefix" "$alias"
    return 5
  }
  resolve_wrangler "$ALIAS_PROJECT_PATH" || {
    printf '%s%s: missing-provider\n' "$prefix" "$alias"
    return 5
  }
  prepare_runtime || return 1
  if resolve_secret; then
    rc=0
  else
    rc=$?
    printf '%s%s: missing\n' "$prefix" "$alias"
    credential_cleanup
    return "$rc"
  fi
  run_wrangler_capture "$ALIAS_PROJECT_PATH" whoami
  rc=$FM_CREDENTIAL_RC
  if [ "$rc" -eq 0 ]; then
    if alias_expiring_soon; then
      printf '%s%s: available-expiring expires_at=%s\n' "$prefix" "$alias" "$ALIAS_EXPIRES_AT"
    else
      printf '%s%s: available\n' "$prefix" "$alias"
    fi
  else
    class=$(provider_failure_class)
    printf '%s%s: %s\n' "$prefix" "$alias" "$class"
  fi
  credential_cleanup
  return "$rc"
}

command_doctor() {
  local aliases ready=0 alias rc
  validate_policy || return 1
  aliases=$(jq '.aliases | length' "$FM_CREDENTIAL_POLICY") || return 1
  printf 'policy: valid aliases=%s\n' "$aliases"
  for alias in $(jq -r '.aliases | keys[]' "$FM_CREDENTIAL_POLICY"); do
    status_alias "$alias" "credential " || rc=$?
    rc=${rc:-0}
    [ "$rc" -eq 0 ] || ready=1
    rc=0
  done
  [ "$ready" -eq 0 ] || return 1
  printf 'doctor: ready\n'
}

command_status() {
  [ "$#" -eq 1 ] || {
    usage
    return 2
  }
  validate_policy || return 1
  status_alias "$1" "credential "
}

command_exec() {
  local task alias operation started class rc audit_rc=0
  [ "$#" -ge 4 ] && [ "$3" = -- ] || {
    usage
    return 2
  }
  task=$1
  alias=$2
  operation=$4
  shift 4
  validate_policy || return 1
  alias_load "$alias" || return 2
  task_metadata_load "$task" || return 2
  prepare_runtime || return 1
  audit_prepare || {
    credential_cleanup
    return 1
  }
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  case "$operation" in deploy|deploy-dry-run|whoami) : ;; *)
    audit_append "$task" "$alias" "$ALIAS_ADAPTER" invalid "$started" policy-denied 2 || true
    credential_cleanup
    fail "unrecognized adapter operation"
    return 2
    ;;
  esac
  if ! alias_operation_allowed "$alias" "$operation"; then
    audit_append "$task" "$alias" "$ALIAS_ADAPTER" "$operation" "$started" policy-denied 2 || true
    credential_cleanup
    fail "credential alias does not grant this operation"
    return 2
  fi
  if ! adapter_args_valid "$operation" "$@"; then
    audit_append "$task" "$alias" "$ALIAS_ADAPTER" "$operation" "$started" policy-denied 2 || true
    credential_cleanup
    return 2
  fi
  if alias_expired; then
    audit_append "$task" "$alias" "$ALIAS_ADAPTER" "$operation" "$started" credential-expired 4 || true
    credential_cleanup
    fail "credential is expired"
    return 4
  fi
  if ! command -v op >/dev/null 2>&1 || [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    audit_append "$task" "$alias" "$ALIAS_ADAPTER" "$operation" "$started" missing-backend 127 || true
    credential_cleanup
    fail "1Password backend is unavailable"
    return 127
  fi
  if ! resolve_wrangler "$TASK_WORKTREE"; then
    audit_append "$task" "$alias" "$ALIAS_ADAPTER" "$operation" "$started" missing-provider 127 || true
    credential_cleanup
    fail "Wrangler is unavailable"
    return 127
  fi
  if resolve_secret; then
    rc=0
  else
    rc=$?
    audit_append "$task" "$alias" "$ALIAS_ADAPTER" "$operation" "$started" credential-missing "$rc" || true
    credential_cleanup
    fail "credential is missing from 1Password"
    return "$rc"
  fi
  if [ "$operation" != whoami ]; then
    run_wrangler_capture "$TASK_WORKTREE" whoami
    rc=$FM_CREDENTIAL_RC
    if [ "$rc" -ne 0 ]; then
      class=$(provider_failure_class)
      audit_append "$task" "$alias" "$ALIAS_ADAPTER" "$operation" "$started" "$class" "$rc" || audit_rc=1
      credential_cleanup
      [ "$audit_rc" -eq 0 ] || fail "credential audit append failed"
      printf 'fm-credential: provider preflight failed: %s\n' "$class" >&2
      return "$rc"
    fi
  fi
  run_wrangler_capture "$TASK_WORKTREE" "$operation"
  rc=$FM_CREDENTIAL_RC
  redact_file "$FM_CREDENTIAL_STDOUT"
  redact_file "$FM_CREDENTIAL_STDERR" >&2
  if [ "$rc" -eq 0 ]; then
    class=success
  else
    class=$(provider_failure_class)
  fi
  audit_append "$task" "$alias" "$ALIAS_ADAPTER" "$operation" "$started" "$class" "$rc" || audit_rc=1
  credential_cleanup
  [ "$audit_rc" -eq 0 ] || fail "credential audit append failed"
  return "$rc"
}

trap credential_cleanup EXIT
trap 'exit 1' HUP INT TERM

case "${1:-}" in
  doctor)
    shift
    [ "$#" -eq 0 ] || { usage; exit 2; }
    command_doctor
    exit $?
    ;;
  status)
    shift
    command_status "$@"
    exit $?
    ;;
  exec)
    shift
    command_exec "$@"
    exit $?
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac
