#!/bin/bash
# Tests for lib/claude_templates.sh (what validate.sh uses to install templates/claude/ into a
# project's .claude/) and tools/check-agent-config.rb. Run from anywhere:
#   bash test/claude_templates/run.sh
# Needs: bash, ruby. No network, no Claude, no project checkout: each scenario gets a throwaway dir.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSES=0
FAILS=0
OUT=""

pass() { PASSES=$((PASSES + 1)); echo "  ok   - $1"; }
fail() {
    FAILS=$((FAILS + 1)); echo "  FAIL - $1"
    echo "         output (tail):"; printf '%s\n' "$OUT" | tail -12 | sed 's/^/         | /'
}
assert_eq()       { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 (missing '$3')"; fi; }
assert_missing()  { if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1 (unexpected '$3')"; fi; }
assert_same()     { if cmp -s "$2" "$3"; then pass "$1"; else fail "$1 (files differ)"; fi; }
# The interactive diff header (read -p only prints its prompt on a terminal, so we assert on the header).
assert_asked()    { if printf '%s\n' "$2" | grep -q "^\.claude/$3 differs from template (project:"; then pass "$1"; else fail "$1 (not asked for $3)"; fi; }
assert_not_asked(){ if ! printf '%s\n' "$2" | grep -q "^\.claude/.* differs from template (project:"; then pass "$1"; else fail "$1 (was asked)"; fi; }
assert_differ()   { if ! cmp -s "$2" "$3"; then pass "$1"; else fail "$1 (files identical)"; fi; }

# Fresh project dir with a minimal nanoc.yaml; prints its path.
new_project() {
    local d; d="$(mktemp -d "$WORK/proj.XXXXXX")"
    printf 'base_url: https://example.com\n' > "$d/nanoc.yaml"
    echo "$d"
}

# run_lib <project> <function...> — runs lib functions with the stubs validate.sh normally provides.
# Extra env (CI=..., CLAUDE_TEMPLATES_ASSUME_TTY=...) is inherited; stdin is passed through.
run_lib() {
    local proj="$1"; shift
    SCRIPT_DIR="$REPO" current_dir="$proj" bash -c '
        PASS="[PASS]"; WARN="[WARN]"; YELLOW=""; NC=""
        check_pass() { echo "[PASS] $1"; }
        source "$SCRIPT_DIR/lib/claude_templates.sh"
        "$@"
        rc=$?
        echo "CHANGED=$CLAUDE_TEMPLATES_CHANGED"
        printf "ACCEPTED<%s>\n" "$CLAUDE_DIFF_ACCEPTED"
        exit $rc
    ' _ "$@" 2>&1
}

T="$REPO/templates/claude"
FILES="agents/copy-reviewer.md agents/page-dates.md skills/promote/SKILL.md"

echo "== templates are well formed"
for f in $FILES; do
    first="$(head -1 "$T/$f")"
    assert_eq "$f starts with frontmatter" "---" "$first"
    ver="$(sed -n 's/^<!-- template: \(.*\) -->$/\1/p' "$T/$f" | head -1)"
    case "$ver" in *@[0-9]*) pass "$f has a version comment ($ver)";; *) fail "$f has no version comment";; esac
done

echo "== missing: copied from template, new-session note"
P="$(new_project)"
OUT="$(run_lib "$P" install_claude_templates </dev/null)"
for f in $FILES; do assert_same "$f copied" "$T/$f" "$P/.claude/$f"; done
assert_contains "reports copy" "$OUT" ".claude/agents/page-dates.md copied from template (page-dates@1)"
assert_contains "new-session note" "$OUT" "NEW Claude Code session"
assert_contains "marks changed" "$OUT" "CHANGED=true"

echo "== identical: up to date, no note"
OUT="$(run_lib "$P" install_claude_templates </dev/null)"
assert_contains "up to date" "$OUT" ".claude/agents/copy-reviewer.md is up to date"
assert_contains "up to date (skill)" "$OUT" ".claude/skills/promote/SKILL.md is up to date"
assert_missing "no new-session note" "$OUT" "NEW Claude Code session"
assert_contains "not changed" "$OUT" "CHANGED=false"

echo "== differs, non-interactive (CI=1): warning, no prompt, file untouched, nothing recorded"
echo "local edit" >> "$P/.claude/agents/page-dates.md"
cp "$P/.claude/agents/page-dates.md" "$WORK/edited.md"
OUT="$(echo y | CI=1 run_lib "$P" install_claude_templates)"
assert_contains "warns" "$OUT" "[WARN] .claude/agents/page-dates.md differs from template"
assert_contains "points to interactive run" "$OUT" "run validate.sh interactively"
assert_not_asked "no prompt" "$OUT"
assert_missing "a piped yes was not consumed" "$OUT" "updated from template"
assert_same "file untouched" "$WORK/edited.md" "$P/.claude/agents/page-dates.md"
assert_contains "nothing accepted" "$OUT" "ACCEPTED<>"
OUT="$(echo y | CI=1 CLAUDE_TEMPLATES_ASSUME_TTY=1 run_lib "$P" install_claude_templates)"
assert_not_asked "CI wins over a TTY: no prompt" "$OUT"
assert_same "CI wins: file untouched" "$WORK/edited.md" "$P/.claude/agents/page-dates.md"

echo "== differs, no TTY on stdin (CI unset): also non-interactive"
OUT="$(unset CI; echo y | run_lib "$P" install_claude_templates)"
assert_contains "warns without CI" "$OUT" "[WARN] .claude/agents/page-dates.md differs from template"
assert_not_asked "no prompt without a TTY" "$OUT"
assert_same "no TTY: file untouched" "$WORK/edited.md" "$P/.claude/agents/page-dates.md"

echo "== differs, interactive: answer no is recorded per file"
echo "other local edit" >> "$P/.claude/skills/promote/SKILL.md"
OUT="$(unset CI; echo n | CLAUDE_TEMPLATES_ASSUME_TTY=1 run_lib "$P" install_claude_templates; true)"
assert_asked "prompts for page-dates" "$OUT" "agents/page-dates.md"
assert_asked "prompts for promote" "$OUT" "skills/promote/SKILL.md"
# The one piped "n" answers the first prompt; the second prompt reads EOF = no. Both are recorded.
assert_contains "records page-dates key" "$OUT" "agent-page-dates-diff-ok: "
assert_contains "records promote key" "$OUT" "skill-promote-diff-ok: "
assert_missing "copy-reviewer untouched, no key" "$OUT" "agent-copy-reviewer-diff-ok"
assert_same "answer no leaves file" "$WORK/edited.md" "$P/.claude/agents/page-dates.md"

echo "== previously accepted: not asked again (until the diff changes)"
ACC="$(printf '%s\n' "$OUT" | sed -n '/^ACCEPTED</,/^>$/p' | sed -e 's/^ACCEPTED<//' -e '/^>$/d')"
printf '%s\n' "$ACC" > "$P/.validated"
OUT="$(unset CI; echo y | CLAUDE_TEMPLATES_ASSUME_TTY=1 run_lib "$P" install_claude_templates)"
assert_contains "page-dates accepted" "$OUT" ".claude/agents/page-dates.md differs from template (previously accepted)"
assert_contains "promote accepted" "$OUT" ".claude/skills/promote/SKILL.md differs from template (previously accepted)"
assert_not_asked "no prompt when accepted" "$OUT"
assert_contains "accepted lines carried forward" "$OUT" "agent-page-dates-diff-ok: "
assert_missing "a piped yes was not consumed" "$OUT" "updated from template"
echo "more edits" >> "$P/.claude/agents/page-dates.md"
OUT="$(unset CI; CLAUDE_TEMPLATES_ASSUME_TTY=1 run_lib "$P" install_claude_templates </dev/null)"
assert_asked "changed diff is asked again" "$OUT" "agents/page-dates.md"
assert_contains "other file still accepted" "$OUT" ".claude/skills/promote/SKILL.md differs from template (previously accepted)"

echo "== differs, interactive: answer yes overwrites"
OUT="$(unset CI; echo y | CLAUDE_TEMPLATES_ASSUME_TTY=1 run_lib "$P" install_claude_template agents/page-dates.md agent-page-dates-diff-ok)"
assert_same "page-dates restored" "$T/agents/page-dates.md" "$P/.claude/agents/page-dates.md"
assert_contains "reports update" "$OUT" "updated from template (page-dates@1)"
assert_contains "new-session note" "$OUT" "CHANGED=true"

echo "== promote: false skips the skill"
P2="$(new_project)"; printf 'promote: false\n' >> "$P2/nanoc.yaml"
OUT="$(run_lib "$P2" install_claude_templates </dev/null)"
assert_contains "skips skill" "$OUT" "promote: false"
[[ ! -e "$P2/.claude/skills/promote/SKILL.md" ]] && pass "skill not installed" || fail "skill installed despite promote: false"
[[ -f "$P2/.claude/agents/copy-reviewer.md" ]] && pass "agents still installed" || fail "agents missing"

echo "== config examples appended when keys are absent"
P3="$(new_project)"
OUT="$(run_lib "$P3" add_claude_config_examples </dev/null)"
assert_contains "adds agents example" "$OUT" "added commented-out agents example"
assert_contains "adds promote example" "$OUT" "added commented-out promote example"
assert_eq "yaml has no active agents key" "false" "$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).key?("agents")' "$P3/nanoc.yaml")"
assert_eq "yaml has no active promote key" "false" "$(ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).key?("promote")' "$P3/nanoc.yaml")"
OUT="$(run_lib "$P3" add_claude_config_examples </dev/null)"
assert_contains "second run finds agents" "$OUT" "agents config found"
assert_eq "no duplicate agents block" "1" "$(grep -c '^# agents:' "$P3/nanoc.yaml")"
assert_eq "no duplicate promote block" "1" "$(grep -c '^# promote:' "$P3/nanoc.yaml")"
P4="$(new_project)"; printf 'agents:\n  copy_review: {}\npromote:\n  branches: {}\n' >> "$P4/nanoc.yaml"
cp "$P4/nanoc.yaml" "$WORK/before.yaml"
OUT="$(run_lib "$P4" add_claude_config_examples </dev/null)"
assert_same "active keys: nanoc.yaml untouched" "$WORK/before.yaml" "$P4/nanoc.yaml"
P5="$(new_project)"; printf '# promote:\n#   branches: {}\n' >> "$P5/nanoc.yaml"
OUT="$(run_lib "$P5" add_claude_config_examples </dev/null)"
assert_eq "commented promote counts as present" "0" "$(grep -c 'Settings for the /promote skill' "$P5/nanoc.yaml")"
assert_contains "still adds missing agents" "$OUT" "added commented-out agents example"

echo "== path warnings"
P6="$(new_project)"
mkdir -p "$P6/content/pages" "$P6/content/data"
touch "$P6/content/pages/help.haml" "$P6/content/data/faqs.yaml"
cat >> "$P6/nanoc.yaml" <<'YAML'
agents:
  copy_review:
    sources: [content/pages/*.haml, "content/missing/*.md", layouts/nope.haml]
  dated_pages:
    - page: /help/
      date_in: content/data/faqs.yaml
      content: [content/data/faqs.yaml, content/pages/help.haml]
    - page: /gone/
      date_in: content/data/gone.yaml
      content: [content/pages/gone.haml]
    - page: /bad/
      content: [content/pages/help.haml]
  never_touch_dates: [content/data/releases.yaml]
YAML
OUT="$(run_lib "$P6" check_claude_config_paths </dev/null)"
assert_contains "missing sources glob" "$OUT" "agents.copy_review.sources: content/missing/*.md matches nothing"
assert_contains "missing sources file" "$OUT" "agents.copy_review.sources: layouts/nope.haml matches nothing"
assert_contains "missing date_in" "$OUT" "(/gone/): date_in content/data/gone.yaml does not exist"
assert_contains "missing content" "$OUT" "(/gone/): content content/pages/gone.haml does not exist"
assert_contains "needs a date source" "$OUT" "(/bad/): needs exactly one of"
assert_contains "missing never_touch" "$OUT" "never_touch_dates: content/data/releases.yaml does not exist"
assert_missing "existing paths are quiet" "$OUT" "(/help/)"
assert_missing "existing glob is quiet" "$OUT" "content/pages/*.haml matches nothing"
assert_missing "warnings never fail" "$OUT" "[FAIL]"
P7="$(new_project)"
OUT="$(run_lib "$P7" check_claude_config_paths </dev/null)"
assert_contains "no config: passes quietly" "$OUT" "agents config paths exist (or not configured)"
P8="$(new_project)"; printf 'agents: [1, 2\n' >> "$P8/nanoc.yaml"
OUT="$(run_lib "$P8" check_claude_config_paths </dev/null)"
assert_contains "broken yaml does not crash" "$OUT" "agents config paths exist (or not configured)"

echo
echo "$PASSES passed, $FAILS failed"
[[ $FAILS -eq 0 ]]
