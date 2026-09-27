#!/usr/bin/env bash
# Behavior tests for bin/fm-skill-route.sh.
#
# Drives the public argv and environment interface with a fake curl on PATH
# that records argv and the request body, then answers with a canned
# typesafe.ai Noul response. No case touches the network, and the absent-key
# case proves the tool makes no call at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-skill-route.sh"
TMP_ROOT=$(fm_test_tmproot fm-skill-route)
HOME_DIR="$TMP_ROOT/home"
USER_SKILLS="$TMP_ROOT/user-skills"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
BRIEF="$TMP_ROOT/brief.md"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR" "$USER_SKILLS" "$LOG"

write_skill() {  # <dir> <name> <description...>
  local dir=$1 name=$2
  shift 2
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'name: %s\n' "$name"
    printf 'description: %s\n' "$*"
    printf -- '---\n'
    printf 'body\n'
  } > "$dir/SKILL.md"
}

write_folded_skill() {  # <dir> <name> <first description line> <more lines...>
  local dir=$1 name=$2 first=$3
  shift 3
  mkdir -p "$dir"
  {
    printf -- '---\n'
    printf 'name: %s\n' "$name"
    printf 'description: >-\n'
    printf '  %s\n' "$first"
    for extra in "$@"; do
      printf '  %s\n' "$extra"
    done
    printf -- '---\n'
    printf 'body\n'
  } > "$dir/SKILL.md"
}

write_skill "$USER_SKILLS/alpha" alpha "Fix login and authentication bugs."
write_skill "$USER_SKILLS/beta" beta "Handle unrelated release-notes formatting."

cat > "$BRIEF" <<'MD'
# Task
Fix the login bug: sessions expire one second early because of an off-by-one.
MD

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: records argv (minus the -o target), the stdin body, and the header
# read from fd 3, then answers with FAKE_CURL_RESPONSE and FAKE_CURL_HTTP.
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

RESPONSE="$TMP_ROOT/response.json"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

write_response() {  # <path> <skill_1 noul> [<skill_2 noul> ...]
  local path=$1
  shift
  local answers='' i=1
  for p in "$@"; do
    answers="${answers}${answers:+,}\"skill_$i\":{\"type\":\"noul\",\"noul\":$p}"
    i=$((i + 1))
  done
  printf '{ "model": "jev-1.13.0", "answers": { %s }, "usage": { "input_tokens": 300, "output_tokens": 40 } }' "$answers" > "$path"
}

# run <exit-var> <out-var> <err-var> [args...]: the tool with fakebin first on
# PATH, an isolated FM_HOME, and the user-skills override; TYPESAFE_API_KEY
# comes from the caller's env.
run() {
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_USER_SKILLS_OVERRIDE="$USER_SKILLS" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

KEY='test-key-9f1c2d3e-never-on-argv'
code='' out='' err=''

# --- absent key: off, silent on stdout, no network call ----------------------
reset_log
write_response "$RESPONSE" 0.9 0.1
run code out err "$BRIEF" --project pager
expect_code 0 "$code" "absent key exits 0"
assert_equals '' "$out" "absent key prints nothing on stdout"
assert_contains "$err" 'skill-route: off (TYPESAFE_API_KEY absent from the environment and' "absent key explains itself on stderr"
assert_absent "$LOG/argv" "absent key never calls curl"
pass "absent key is off: one stderr line, exit 0, no network call"

# --- .env key, and the environment wins over it ------------------------------
printf '%s\n' '# local secrets' "export TYPESAFE_API_KEY=\"$KEY\"" > "$HOME_DIR/.env"
reset_log
run code out err "$BRIEF" --project pager
expect_code 0 "$code" ".env key resolves"
assert_contains "$out" '  status: clear' ".env key produces a clear result"
assert_contains "$(cat "$LOG/header")" "Authorization: Bearer $KEY" ".env key reaches curl on the fd header"
reset_log
TYPESAFE_API_KEY=env-wins run code out err "$BRIEF" --project pager
assert_equals 'Authorization: Bearer env-wins' "$(cat "$LOG/header")" "environment key wins over .env"
rm -f "$HOME_DIR/.env"
pass "TYPESAFE_API_KEY= in .env activates the tool; the environment wins over it"

# --- clear: request shape, secret handling, selection ------------------------
reset_log
write_response "$RESPONSE" 0.92 0.1
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project pager
expect_code 0 "$code" "clear exits 0"
assert_contains "$out" 'skill-route:' "TOON block header"
assert_contains "$out" '  status: clear' "clear status"
assert_contains "$out" 'skill: alpha (Fix login and authentication bugs.) noul=0.92 -> selected' "the matching skill is selected"
assert_contains "$out" 'skill: beta (Handle unrelated release-notes formatting.) noul=0.1 -> not selected' "the unrelated skill is listed but not selected"
assert_contains "$out" '  line: Load these skills: alpha' "the suggested line names only the selected skill"
argv=$(cat "$LOG/argv")
assert_not_contains "$argv" "$KEY" "the key never appears on curl argv"
assert_contains "$argv" 'https://api.typesafe.ai/v1/systemone' "the request uses the fixed typesafe.ai endpoint"
assert_contains "$argv" $'--max-time\n5' "the request uses the fixed five-second timeout"
assert_contains "$argv" '@/dev/fd/3' "the header is read from a file descriptor"
assert_equals "Authorization: Bearer $KEY" "$(cat "$LOG/header")" "curl receives the bearer header on fd 3"
body=$(cat "$LOG/body")
assert_equals 'jev-latest' "$(jq -r .model <<<"$body")" "default model is jev-latest"
assert_equals 'pager' "$(jq -r .state.task.project <<<"$body")" "project rides in the state"
assert_contains "$(jq -r .state.task.brief <<<"$body")" 'off-by-one' "a brief without task headings rides whole in the state"
assert_equals '["skill_1","skill_2"]' "$(jq -c '.questions | keys' <<<"$body")" "one Noul question per catalog skill"
assert_equals 'noul' "$(jq -r '.questions.skill_1.type' <<<"$body")" "each question is a Noul"
assert_contains "$(jq -r '.questions.skill_1.instructions' <<<"$body")" 'alpha' "the instructions name the skill"
pass "clear: one Noul question per catalog skill, key on the fd header only, floor-based selection"

# --- none: no skill clears the floor -----------------------------------------
reset_log
write_response "$RESPONSE" 0.4 0.1
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "none exits 0"
assert_contains "$out" '  status: none' "no skill clearing the floor is none"
assert_contains "$out" '  reason: no skill cleared confidence floor 0.6' "none names the floor"
assert_not_contains "$out" '  line:' "none emits no suggested line"
pass "none: nothing clears the floor, decide as today"

# --- no catalog: no model or network call ------------------------------------
reset_log
EMPTY_USER_SKILLS="$TMP_ROOT/empty-user-skills"
mkdir -p "$EMPTY_USER_SKILLS"
_out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_USER_SKILLS_OVERRIDE="$EMPTY_USER_SKILLS" TYPESAFE_API_KEY=$KEY "$TOOL" "$BRIEF" 2> "$TMP_ROOT/stderr")
_code=$?
expect_code 0 "$_code" "empty catalog exits 0"
assert_contains "$_out" '  status: none' "empty catalog is none"
assert_contains "$_out" '  reason: no installed skills found' "empty catalog names the reason"
assert_absent "$LOG/argv" "empty catalog never calls curl"
pass "no installed skills: no model or network call"

# --- project-dir catalog, and de-duplication across roots --------------------
reset_log
PROJ="$TMP_ROOT/proj"
EMPTY_USER_FOR_PROJ="$TMP_ROOT/empty-user-for-proj"
mkdir -p "$EMPTY_USER_FOR_PROJ"
write_skill "$PROJ/.agents/skills/gamma" gamma "Review pull requests for style."
write_response "$RESPONSE" 0.7
_out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_USER_SKILLS_OVERRIDE="$EMPTY_USER_FOR_PROJ" TYPESAFE_API_KEY=$KEY "$TOOL" "$BRIEF" --project-dir "$PROJ" 2> "$TMP_ROOT/stderr")
assert_equals '["skill_1"]' "$(jq -c '.questions | keys' "$LOG/body")" "project-dir catalog is read when the user directory has no skills"
assert_contains "$_out" 'skill: gamma' "the project skill appears in the catalog"

reset_log
rm -rf "$PROJ"
mkdir -p "$PROJ/.agents"
ln -s "$USER_SKILLS" "$PROJ/.agents/skills"
write_response "$RESPONSE" 0.92 0.1
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF" --project-dir "$PROJ"
assert_equals '["skill_1","skill_2"]' "$(jq -c '.questions | keys' "$LOG/body")" "a project catalog identical to the user catalog is counted once"
pass "project-dir catalog is read, and a shared tree with the user catalog de-duplicates"

# --- a skill without a readable description is skipped -----------------------
reset_log
NO_DESC_SKILLS="$TMP_ROOT/no-desc-skills"
mkdir -p "$NO_DESC_SKILLS/undocumented"
printf -- '---\nname: undocumented\n---\nbody\n' > "$NO_DESC_SKILLS/undocumented/SKILL.md"
_out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_USER_SKILLS_OVERRIDE="$NO_DESC_SKILLS" TYPESAFE_API_KEY=$KEY "$TOOL" "$BRIEF" 2> "$TMP_ROOT/stderr")
_code=$?
expect_code 0 "$_code" "an undescribed skill leaves an effectively empty catalog"
assert_contains "$_out" '  reason: no installed skills found' "a skill with no readable description is skipped rather than guessed"
pass "a skill directory with no readable name or description is skipped"

# --- a folded (>-) description reads only its first line ---------------------
reset_log
FOLDED_SKILLS="$TMP_ROOT/folded-skills"
write_folded_skill "$FOLDED_SKILLS/delta" delta "Generate a fleet digest." "A second line that must not appear."
write_response "$RESPONSE" 0.8
_out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_USER_SKILLS_OVERRIDE="$FOLDED_SKILLS" TYPESAFE_API_KEY=$KEY "$TOOL" "$BRIEF" 2> "$TMP_ROOT/stderr")
assert_contains "$_out" 'skill: delta (Generate a fleet digest.) noul=0.8' "only the folded description's first line is used"
assert_not_contains "$_out" 'A second line' "later folded lines are not read as the description"
pass "a folded description scalar reads only its first content line"

# --- selection caps at 5 skills -----------------------------------------------
reset_log
MANY_SKILLS="$TMP_ROOT/many-skills"
for n in 1 2 3 4 5 6; do
  write_skill "$MANY_SKILLS/skill$n" "skill$n" "Candidate number $n."
done
printf '{ "model": "jev-1.13.0", "answers": { "skill_1":{"type":"noul","noul":0.61},"skill_2":{"type":"noul","noul":0.62},"skill_3":{"type":"noul","noul":0.63},"skill_4":{"type":"noul","noul":0.64},"skill_5":{"type":"noul","noul":0.65},"skill_6":{"type":"noul","noul":0.99} }, "usage": { "input_tokens": 300, "output_tokens": 40 } }' > "$RESPONSE"
_out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_USER_SKILLS_OVERRIDE="$MANY_SKILLS" TYPESAFE_API_KEY=$KEY "$TOOL" "$BRIEF" 2> "$TMP_ROOT/stderr")
line=$(grep '^  line:' <<<"$_out")
assert_equals '  line: Load these skills: skill6, skill5, skill4, skill3, skill2' "$line" "the suggested line caps at the 5 highest-probability skills"
pass "selection caps at 5 skills, ranked by probability"

# --- error: HTTP failure and malformed response -------------------------------
reset_log
cat > "$RESPONSE" <<'JSON'
not json
JSON
FAKE_CURL_HTTP=500 TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "HTTP failure exits 0"
assert_contains "$out" '  status: error' "HTTP failure is a structured error"
assert_contains "$err" 'skill-route: error (http 500' "HTTP failure names the status on stderr"
assert_not_contains "$out" '  line:' "HTTP failure emits no suggested line"

reset_log
printf '{ "model": "jev-1.13.0", "answers": { "skill_1": {"type":"choice","choice":"x"} } }' > "$RESPONSE"
TYPESAFE_API_KEY=$KEY run code out err "$BRIEF"
expect_code 0 "$code" "malformed response exits 0"
assert_contains "$out" '  status: error' "a non-Noul answer is a structured error"
assert_contains "$err" 'response is not a set of Noul answers' "the malformed-response reason is named"
pass "error: HTTP failure and a malformed response return structured errors, never a blocked exit"

# --- usage errors: exit 2, actionable, never selected around ------------------
reset_log
_err=$(TYPESAFE_API_KEY=$KEY FM_HOME="$HOME_DIR" FM_USER_SKILLS_OVERRIDE="$USER_SKILLS" "$TOOL" 2>&1)
_code=$?
expect_code 2 "$_code" "a missing brief argument is a usage error"
assert_contains "$_err" 'brief file required' "the usage error names the missing brief"

_err=$(TYPESAFE_API_KEY=$KEY FM_HOME="$HOME_DIR" FM_USER_SKILLS_OVERRIDE="$USER_SKILLS" "$TOOL" "$TMP_ROOT/nonexistent-brief.md" 2>&1)
_code=$?
expect_code 2 "$_code" "an unreadable brief is a usage error"
assert_contains "$_err" 'brief file not readable' "the usage error names the unreadable brief"
pass "usage errors exit 2 and are never selected around"
