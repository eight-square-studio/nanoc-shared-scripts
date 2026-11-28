#!/bin/bash
# Sourced by validate.sh (and test/claude_templates/run.sh): installs the Claude Code agent and
# skill templates from templates/claude/ into the project's .claude/ and checks the nanoc.yaml
# keys they read. Needs from the caller: SCRIPT_DIR, current_dir, check_pass(), and the
# PASS / WARN / YELLOW / NC colour constants from lib/_shared.sh.
#
# Install flow per file (same accepted-diff pattern as deploy.yml): missing -> copied; identical ->
# "up to date"; different -> show the diff and ask. Answering no records a hash of the diff in
# .validated under a per-file key so the question is not asked again until the diff changes.
# Non-interactive runs (CI set, or no TTY on stdin) warn about a difference and never prompt.

# "<path under templates/claude/ and .claude/>|<.validated key>"
CLAUDE_TEMPLATES=(
    "agents/copy-reviewer.md|agent-copy-reviewer-diff-ok"
    "agents/page-dates.md|agent-page-dates-diff-ok"
    "skills/promote/SKILL.md|skill-promote-diff-ok"
)
CLAUDE_TEMPLATES_CHANGED=false   # true once a file was newly copied or overwritten
CLAUDE_DIFF_ACCEPTED=""          # "key: hash" lines for validate.sh to write to .validated

# CLAUDE_TEMPLATES_ASSUME_TTY=1 is a test hook: treat stdin as interactive even when piped.
function claude_noninteractive() {
    [[ -n "${CI:-}" ]] && return 0
    [[ "${CLAUDE_TEMPLATES_ASSUME_TTY:-}" == "1" ]] && return 1
    [[ ! -t 0 ]]
}

function claude_template_version() {
    sed -n 's/^<!-- template: \(.*\) -->$/\1/p' "$1" 2>/dev/null | head -1
}

function claude_diff_hash() {
    diff -u "$1" "$2" | { if command -v sha256sum &>/dev/null; then sha256sum; else shasum -a 256; fi; } | awk '{print $1}'
}

# install_claude_template <rel path> <.validated key>
function install_claude_template() {
    local rel="$1" key="$2"
    local src="$SCRIPT_DIR/templates/claude/$rel" dest="$current_dir/.claude/$rel" label=".claude/$rel"
    local version hash saved answer have
    version=$(claude_template_version "$src")

    if [[ ! -f "$dest" ]]; then
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        CLAUDE_TEMPLATES_CHANGED=true
        check_pass "$label copied from template (${version:-unversioned})"
    elif diff -q "$dest" "$src" &>/dev/null; then
        check_pass "$label is up to date (${version:-unversioned})"
    else
        have=$(claude_template_version "$dest")
        hash=$(claude_diff_hash "$dest" "$src")
        saved=$(sed -n "s/^${key}: //p" "$current_dir/.validated" 2>/dev/null || true)
        if [[ "$saved" == "$hash" ]]; then
            CLAUDE_DIFF_ACCEPTED+="${key}: ${hash}"$'\n'
            check_pass "$label differs from template (previously accepted)"
        elif claude_noninteractive; then
            echo -e "${WARN} $label differs from template (project: ${have:-no version}, template: ${version:-unversioned}) — run validate.sh interactively to review the diff"
        else
            echo ""
            echo -e "${YELLOW}${label} differs from template (project: ${have:-no version}, template: ${version:-unversioned}):${NC}"
            echo ""
            diff --color=always -u "$dest" "$src" 2>/dev/null || diff -u "$dest" "$src"
            echo ""
            read -rp "Overwrite ${label} with template? [y/N] " answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                cp "$src" "$dest"
                CLAUDE_TEMPLATES_CHANGED=true
                check_pass "$label updated from template (${version:-unversioned})"
            else
                CLAUDE_DIFF_ACCEPTED+="${key}: ${hash}"$'\n'
                check_pass "$label differs from template (accepted)"
            fi
        fi
    fi
}

# True when promote is switched off in nanoc.yaml (`promote: false`).
function claude_promote_disabled() {
    grep -qE '^promote:[[:space:]]*(false|no|off)[[:space:]]*(#.*)?$' "$current_dir/nanoc.yaml" 2>/dev/null
}

function install_claude_templates() {
    local entry rel key
    for entry in "${CLAUDE_TEMPLATES[@]}"; do
        rel="${entry%%|*}"
        key="${entry##*|}"
        if [[ "$rel" == skills/promote/* ]] && claude_promote_disabled; then
            check_pass "nanoc.yaml: promote: false — skipping .claude/$rel"
            continue
        fi
        install_claude_template "$rel" "$key"
    done
    if [[ "$CLAUDE_TEMPLATES_CHANGED" == true ]]; then
        echo -e "${WARN} New or updated Claude agents/skills are only discovered by a NEW Claude Code session — start one (or restart) before using them"
    fi
}

# Commented-out example blocks, appended when the key is absent (active or commented out).
function claude_config_has_key() {
    grep -qE "^[[:space:]]*#?[[:space:]]*$1:" "$current_dir/nanoc.yaml"
}

function add_claude_config_examples() {
    if claude_config_has_key agents; then
        check_pass "nanoc.yaml: agents config found"
    else
        cat >> "$current_dir/nanoc.yaml" <<'YAML'

# Settings for the Claude agents installed into .claude/agents/ (copy-reviewer, page-dates).
# Uncomment and edit; the agents stop and name the key if a required one is missing.
# agents:
#   copy_review:
#     locale: en-GB                    # required: en-GB or en-US
#     product: My Product              # required
#     tagline: "My tagline"            # optional
#     terms: [Favourites, Premium]     # optional: canonical wording checked for consistency
#     sources: [content/pages/*.haml, content/pages/*.md, layouts/*.haml]   # required
#     notes: .claude/copy-review-notes.md   # optional free-text rules
#   dated_pages:                       # pages that show a "last updated" date
#     - page: /help/
#       date_in: content/data/faqs.yaml          # data file; key last_updated (or set date_key)
#       content: [content/data/faqs.yaml, content/pages/help.haml]
#     - page: /privacy-policy/
#       date_line: content/pages/privacy-policy.md   # inline "> **Last updated:** ..." line
#       content: [content/pages/privacy-policy.md]
#       changelog_table: true
#   never_touch_dates: [content/data/releases.yaml]   # dates the agent reports but never edits
#   date_format: "%-d %B %Y"           # optional strftime format for dates
YAML
        check_pass "nanoc.yaml: added commented-out agents example"
    fi

    if claude_config_has_key promote; then
        check_pass "nanoc.yaml: promote config found"
    else
        cat >> "$current_dir/nanoc.yaml" <<'YAML'

# Settings for the /promote skill installed into .claude/skills/promote/.
# Uncomment and edit, or set `promote: false` to skip installing the skill.
# promote:
#   branches: { source: main, staging: staging, release: release }   # required
#   review_agents: [copy-reviewer, page-dates]
#   checks:                            # run in an isolated copy; a non-zero exit blocks
#     - ruby scripts/my-build-check.rb
#   release_blockers: ["coming soon"]  # grep -rniE over content/ and layouts/ on a release
#   hidden_page_flag: publish          # flag any page whose `publish: false` changes in a release
#   notes: .claude/promote-notes.md    # optional free-text gates and reminders
YAML
        check_pass "nanoc.yaml: added commented-out promote example"
    fi
}

# Warn (never fail) about missing paths in agents.dated_pages / agents.copy_review.sources.
function check_claude_config_paths() {
    command -v ruby &>/dev/null || return 0
    local line found=false
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        found=true
        echo -e "${WARN} nanoc.yaml: $line"
    done < <(ruby "$SCRIPT_DIR/tools/check-agent-config.rb" "$current_dir" 2>&1)
    [[ "$found" == false ]] && check_pass "nanoc.yaml: agents config paths exist (or not configured)"
    return 0
}
