#!/usr/bin/env bash
# fm-skill-route.sh - suggest a short list of relevant installed skills for a
# written task brief, with typesafe.ai's System One model (Jev), opt-in.
#
# Usage:
#   fm-skill-route.sh <brief-file> [--project <name>] [--project-dir <path>]
#
# Opt-in gate: same as bin/fm-dispatch-resolve.sh. TYPESAFE_API_KEY non-empty
#   in this process environment, else a TYPESAFE_API_KEY= line in
#   $FM_HOME/.env read with fmx_env_get. The environment wins. Absent in both:
#   one "skill-route: off" line on stderr, nothing on stdout, exit 0, no
#   network call, so firstmate authors the brief's Firstmate spec exactly as
#   today.
#
# Catalog: every installed skill visible to the worker, one entry per
#   <root>/<name>/SKILL.md with a readable YAML frontmatter `name:` and
#   `description:` (only the description's first line is used, matching a
#   short catalog entry, not the full multi-line text some SKILL.md files
#   carry). These roots are read when present: <project-dir>/.agents/skills
#   and <project-dir>/.claude/skills (the project this task is briefed
#   against; --project-dir is optional because a scout or secondmate charter
#   may name none), the user-level skills directory (FM_USER_SKILLS_OVERRIDE,
#   default $HOME/.claude/skills), and <installPath>/skills of every Claude
#   Code plugin listed in $HOME/.claude/plugins/installed_plugins.json and
#   enabled in $HOME/.claude/settings.json, named <plugin>:<skill>.
#   Entries are de-duplicated by resolved directory, so a project whose
#   .agents/skills and .claude/skills are the same tree as the user directory
#   (as this repo's own .claude/skills symlink is) is counted once. A skill directory with no
#   readable name or description is skipped rather than guessed.
#
# What it does when on with a non-empty catalog: one POST to
#   https://api.typesafe.ai/v1/systemone with the project name and the
#   brief's task-specific text (the same `## Captain's intent` and
#   `## Firstmate spec` sections bin/fm-dispatch-resolve.sh sends, read by the
#   same parser) as state, and one Noul (yes/no probability) question per
#   catalog skill asking whether that skill would help a worker completing
#   this task. Noul, not Choice, because several skills may independently
#   apply; a Choice would force a single pick over an arbitrary-length
#   catalog. The model sees only names, one-line descriptions, and the task
#   text - never the wider catalog metadata, safety language, or brief
#   boilerplate.
#
# Output (stdout, TOON-style block):
#   skill-route:
#     status: clear | none | error
#     model/latency_ms/tokens
#     skill: <name> (<one-line description>) noul=<p> -> selected|not selected
#     reason: <why status is not clear>
#     line: Load these skills: <name1>, <name2>, ...     (status clear only)
#   clear -> firstmate may add, edit, or drop the `line:` text under the
#            brief's `## Firstmate spec`; nothing is auto-loaded and no brief
#            contract or safety section changes.
#   none  -> no installed skill, or no skill's probability cleared the floor;
#            decide as today (no line added).
#   error -> API, network, response, curl, or catalog failure; decide as today.
#   Every outcome exits 0 so brief authoring is never blocked by this tool.
#   Exit 2 only for a usage error (unreadable brief or missing jq), which is
#   actionable, never selected around.
#
# Environment:
#   TYPESAFE_API_KEY is the only resolver-specific environment setting.
#   FM_USER_SKILLS_OVERRIDE overrides the user-level skills directory (tests).
#
# Authority: this tool never replaces firstmate's judgment or auto-loads
#   anything; it publishes one inspectable suggestion plus every candidate
#   skill's evidence, in code. docs/configuration.md "Skill routing" owns the
#   operator contract.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"

CONFIDENCE_FLOOR=0.6
MAX_SKILLS=5
TS_MODEL=jev-latest
TS_BASE=https://api.typesafe.ai
TS_TIMEOUT=5
CLAUDE_DIR="$HOME/.claude"
USER_SKILLS_DIR="${FM_USER_SKILLS_OVERRIDE:-$CLAUDE_DIR/skills}"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

BRIEF='' PROJECT='' PROJECT_DIR=''
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || die "--project needs a value"; PROJECT=$2; shift 2 ;;
    --project-dir) [ $# -ge 2 ] || die "--project-dir needs a value"; PROJECT_DIR=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) [ -z "$BRIEF" ] || die "one brief file only"; BRIEF=$1; shift ;;
  esac
done

# ---- opt-in gate ---------------------------------------------------------------
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  echo "skill-route: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
  exit 0
fi

# ---- inputs --------------------------------------------------------------------
[ -n "$BRIEF" ] || die "brief file required (see --help)"
[ -r "$BRIEF" ] || die "brief file not readable: $BRIEF"
command -v jq >/dev/null 2>&1 || die "jq required"

emit_error() {
  local reason=$1
  echo "skill-route: error ($reason)" >&2
  printf 'skill-route:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}

no_catalog() {
  printf 'skill-route:\n  status: none\n  reason: no installed skills found\n'
  exit 0
}

# ---- catalog: name + one-line description per SKILL.md, de-duplicated ----------
# Only the description's first content line is read: the frontmatter's `name:`
# and `description:` keys, where `description:` may hold its value inline or,
# for a folded/literal block scalar (`>-`, `>`, `|`, `|-`), on the next
# non-blank indented line. A directory without a readable name or description
# is skipped rather than guessed.
fm_skill_frontmatter() {  # <SKILL.md path>
  awk '
    NR == 1 { if ($0 != "---") exit 1; infm = 1; next }
    infm && $0 == "---" { exit }
    infm && /^name:[[:space:]]*/ {
      val = $0
      sub(/^name:[[:space:]]*/, "", val)
      sub(/[[:space:]]+$/, "", val)
      name = val
      next
    }
    infm && /^description:[[:space:]]*/ {
      val = $0
      sub(/^description:[[:space:]]*/, "", val)
      sub(/[[:space:]]+$/, "", val)
      if (val == "" || val ~ /^[|>][-+]?$/) {
        desc_pending = 1
      } else {
        desc = val
        desc_pending = 0
      }
      next
    }
    infm && desc_pending == 1 && /^[[:space:]]+[^[:space:]]/ {
      val = $0
      sub(/^[[:space:]]+/, "", val)
      desc = val
      desc_pending = 0
      next
    }
    infm && desc_pending == 1 && /^[[:space:]]*$/ { next }
    infm && desc_pending == 1 { desc_pending = 0 }
    END { if (name != "" && desc != "") printf "%s\t%s\n", name, desc }
  ' "$1" 2>/dev/null
}

CATALOG_ENTRIES=$(mktemp) || die "mktemp failed"
SEEN_DIRS=$(mktemp) || { rm -f "$CATALOG_ENTRIES"; die "mktemp failed"; }
trap 'rm -f "$CATALOG_ENTRIES" "$SEEN_DIRS"' EXIT

collect_catalog_root() {  # <root dir holding one subdir per skill> [<name prefix>]
  local root=$1 prefix=${2:-} dir real name desc
  [ -n "$root" ] && [ -d "$root" ] || return 0
  for dir in "$root"/*/; do
    [ -d "$dir" ] || continue
    [ -r "${dir}SKILL.md" ] || continue
    real=$(cd "$dir" 2>/dev/null && pwd -P) || continue
    grep -qxF "$real" "$SEEN_DIRS" 2>/dev/null && continue
    printf '%s\n' "$real" >> "$SEEN_DIRS"
    IFS=$'\t' read -r name desc < <(fm_skill_frontmatter "${dir}SKILL.md")
    [ -n "$name" ] || name=$(basename "$dir")
    [ -n "$desc" ] || continue
    printf '%s%s\t%s\n' "$prefix" "$name" "$desc" >> "$CATALOG_ENTRIES"
  done
}
enabled_plugin_roots() {  # prints <plugin>\t<installPath> per enabled installed plugin
  local installed="$CLAUDE_DIR/plugins/installed_plugins.json" settings="$CLAUDE_DIR/settings.json"
  [ -r "$installed" ] && [ -r "$settings" ] || return 0
  jq -r --slurpfile s "$settings" '
    ($s[0].enabledPlugins // {}) as $on |
    (.plugins // {}) | to_entries[] | select($on[.key] == true) |
    (.key | split("@")[0]) as $plugin | .value[] | select(.installPath) |
    "\($plugin)\t\(.installPath)"
  ' "$installed" 2>/dev/null
}
if [ -n "$PROJECT_DIR" ]; then
  collect_catalog_root "$PROJECT_DIR/.agents/skills"
  collect_catalog_root "$PROJECT_DIR/.claude/skills"
fi
collect_catalog_root "$USER_SKILLS_DIR"
while IFS=$'\t' read -r plugin install_path; do
  collect_catalog_root "$install_path/skills" "$plugin:"
done < <(enabled_plugin_roots)

[ -s "$CATALOG_ENTRIES" ] || no_catalog

CATALOG_JSON=$(jq -Rn '
  [inputs | select(length > 0) | split("\t") | {name: .[0], description: .[1]}]
' "$CATALOG_ENTRIES") || die "could not read catalog"
CATALOG_COUNT=$(jq -r 'length' <<<"$CATALOG_JSON")
[ "$CATALOG_COUNT" -gt 0 ] || no_catalog

RESP_FILE=$(mktemp) || die "mktemp failed"
TASK_TEXT=$(mktemp) || { rm -f "$RESP_FILE"; die "mktemp failed"; }
trap 'rm -f "$CATALOG_ENTRIES" "$SEEN_DIRS" "$RESP_FILE" "$TASK_TEXT"' EXIT

# Send Jev only the task-specific sections bin/fm-brief.sh scaffolds, the same
# text bin/fm-dispatch-resolve.sh sends, so the model reads the same task
# description both tools reason about. A brief with neither section goes whole.
brief_kind() {
  if grep -qxF 'This is a SCOUT task: the deliverable is a written report, not a PR.' "$BRIEF"; then
    printf 'Brief kind: scout (report only)\n\n'
  fi
}
task_sections() {
  local heading
  for heading in "## Captain's intent" "## Firstmate spec"; do
    fm_brief_task_heading_present "$BRIEF" "$heading" || continue
    printf '%s\n%s\n\n' "$heading" "$(fm_brief_task_heading_body "$BRIEF" "$heading")"
  done
}
SECTIONS=$(task_sections)
if [ -n "$SECTIONS" ]; then
  { brief_kind; printf '%s\n' "$SECTIONS"; } > "$TASK_TEXT" || die "could not read brief: $BRIEF"
else
  cp "$BRIEF" "$TASK_TEXT" || die "could not read brief: $BRIEF"
fi

command -v curl >/dev/null 2>&1 || emit_error "curl not installed"
REQUEST=$(jq -n --rawfile brief "$TASK_TEXT" --arg project "$PROJECT" --arg model "$TS_MODEL" --argjson catalog "$CATALOG_JSON" '
  ($catalog | to_entries | map({
    key: ("skill_" + ((.key + 1) | tostring)),
    value: {
      type: "noul",
      instructions: ("Would the installed skill \"" + .value.name + "\" (" + .value.description + ") help a worker completing `task`? Read `task.brief` and `task.project`."),
      criteria: {"true": "The skill applies to this task.", "false": "The skill does not apply to this task."}
    }
  }) | from_entries) as $questions |
  {model: $model, state: {task: {project: $project, brief: $brief}}, questions: $questions}
') || die "could not build request"
T0=$(fm_timing_now_ms)
HTTP=$(printf '%s' "$REQUEST" | curl -sS --max-time "$TS_TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
  -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
  -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
  --data-binary @- 2>/dev/null) || HTTP=000
T1=$(fm_timing_now_ms)
LAT_MS=$(( T1 - T0 ))
[ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms: $(head -c 200 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')"

jq -e --argjson n "$CATALOG_COUNT" '
  . as $top |
  ($top.answers | type) == "object" and
  ([range(1; $n + 1) | "skill_" + tostring] | all(. as $k |
    ($top.answers[$k].type == "noul") and
    (($top.answers[$k].noul) | type) == "number" and
    ($top.answers[$k].noul) >= 0 and ($top.answers[$k].noul) <= 1)) and
  (($top | has("usage") | not) or
    (($top.usage | type) == "object" and
     ($top.usage.input_tokens | type) == "number" and
     ($top.usage.output_tokens | type) == "number"))
' "$RESP_FILE" >/dev/null 2>&1 || emit_error "response is not a set of Noul answers"

RESULT=$(jq -n --arg floor "$CONFIDENCE_FLOOR" --argjson max "$MAX_SKILLS" --argjson lat "$LAT_MS" --argjson catalog "$CATALOG_JSON" --slurpfile resp "$RESP_FILE" '
  ($resp[0]) as $r |
  ($catalog | to_entries | map({
    name: .value.name, description: .value.description,
    noul: $r.answers[("skill_" + ((.key + 1) | tostring))].noul
  })) as $scored |
  ([$scored[] | select(.noul >= ($floor | tonumber))] | sort_by(-.noul) | .[0:$max] | map(.name)) as $names |
  {
    model: ($r.model // null), latency_ms: $lat, tokens: ($r.usage // null),
    floor: ($floor | tonumber),
    scored: ($scored | sort_by(-.noul)),
    selected: $names
  }
') || emit_error "resolution failed"

TEXT=$(jq -r '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($v): ($v // "-") | flat;
  . as $top | ($top.selected) as $names | ($top.scored) as $scored | ($names | length) as $n |
  "skill-route:",
  "  status: \(if $n > 0 then "clear" else "none" end)",
  "  model: \(show($top.model))   latency_ms: \(show($top.latency_ms))   tokens: \(show($top.tokens.input_tokens))/\(show($top.tokens.output_tokens))",
  ($scored[] | . as $item | "  skill: \($item.name | flat) (\($item.description | flat)) noul=\($item.noul | flat) -> " + (if ($names | index($item.name)) != null then "selected" else "not selected" end)),
  (if $n == 0 then "  reason: no skill cleared confidence floor \($top.floor)" else empty end),
  (if $n > 0 then "  line: Load these skills: \($names | join(", "))" else empty end)
' <<<"$RESULT") || emit_error "output rendering failed"
printf '%s\n' "$TEXT"
exit 0
