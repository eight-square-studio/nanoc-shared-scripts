#!/bin/bash
set -uo pipefail
# One-time setup verification for a nanoc project using nanoc-shared-scripts as a submodule.
# Run from the project root after adding the submodule, or after a significant update.
# On success: writes .validated to the project root and creates run.sh / deploy.sh symlinks.
source "$(dirname "${BASH_SOURCE[0]}")/lib/_shared.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

function check_pass() {
    echo -e "${PASS} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

function check_fail() {
    echo -e "${FAIL} $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo ""
echo "=== nanoc-shared-scripts validate ==="
echo "Project root: $current_dir"
echo ""

# --- Bootstrap: use nanoc create-site if core project files are missing ---
nanoc_needs_bootstrap=false
for f in nanoc.yaml Rules; do
    [[ ! -f "$current_dir/$f" ]] && nanoc_needs_bootstrap=true
done

if [[ "$nanoc_needs_bootstrap" == true ]]; then
    echo -e "${BLUE}Nanoc project not configured — bootstrapping with nanoc create-site...${NC}"
    nanoc_tmp="$(mktemp -d)"
    trap 'rm -rf "$nanoc_tmp"' RETURN
    if RBENV_VERSION="$default_ruby_version" rbenv exec nanoc create-site "$nanoc_tmp/site" &>/dev/null 2>&1; then
        check_pass "nanoc create-site succeeded"
        # nanoc create-site gives us content/ and layouts/ scaffolding;
        # overlay our templates for nanoc.yaml and Rules (richer defaults
        # with deployment keys, haml/scss rules, pages routing)
        if [[ ! -f "$current_dir/nanoc.yaml" ]]; then
            if [[ -f "$SCRIPT_DIR/templates/nanoc.yaml" ]]; then
                cp "$SCRIPT_DIR/templates/nanoc.yaml" "$current_dir/nanoc.yaml"
                check_pass "nanoc.yaml created from project template (with deployment keys)"
            else
                cp "$nanoc_tmp/site/nanoc.yaml" "$current_dir/nanoc.yaml"
                check_pass "nanoc.yaml created via nanoc create-site"
            fi
        fi
        if [[ ! -f "$current_dir/Rules" ]]; then
            if [[ -f "$SCRIPT_DIR/templates/Rules" ]]; then
                cp "$SCRIPT_DIR/templates/Rules" "$current_dir/Rules"
                check_pass "Rules created from project template (haml/scss/pages routing)"
            else
                cp "$nanoc_tmp/site/Rules" "$current_dir/Rules"
                check_pass "Rules created via nanoc create-site"
            fi
        fi
        if [[ ! -d "$current_dir/content" && -d "$nanoc_tmp/site/content" ]]; then
            cp -r "$nanoc_tmp/site/content" "$current_dir/content"
            check_pass "content/ created via nanoc create-site"
        fi
        if [[ ! -d "$current_dir/layouts" && -d "$nanoc_tmp/site/layouts" ]]; then
            cp -r "$nanoc_tmp/site/layouts" "$current_dir/layouts"
            check_pass "layouts/ created via nanoc create-site"
        fi
    else
        echo -e "${WARN} nanoc create-site failed — falling back to templates"
        for f in nanoc.yaml Rules; do
            if [[ ! -f "$current_dir/$f" && -f "$SCRIPT_DIR/templates/$f" ]]; then
                cp "$SCRIPT_DIR/templates/$f" "$current_dir/$f"
                check_pass "$f created from template (nanoc create-site unavailable)"
            fi
        done
        if [[ ! -d "$current_dir/layouts" ]]; then
            mkdir -p "$current_dir/layouts"
            [[ -f "$SCRIPT_DIR/templates/default.haml" ]] && cp "$SCRIPT_DIR/templates/default.haml" "$current_dir/layouts/default.haml"
            check_pass "layouts/ created from template"
        fi
        if [[ ! -d "$current_dir/content" ]]; then
            mkdir -p "$current_dir/content/pages"
            [[ -f "$SCRIPT_DIR/templates/index.haml" ]] && cp "$SCRIPT_DIR/templates/index.haml" "$current_dir/content/pages/index.haml"
            check_pass "content/ created from template"
        fi
    fi
    rm -rf "$nanoc_tmp"
    echo ""
fi

# --- Augment nanoc.yaml with deployment keys if missing ---
if [[ -f "$current_dir/nanoc.yaml" ]]; then
    check_pass "nanoc.yaml found"
    for key in s3_bucket cloudfront_distribution_id aws_region; do
        if ! grep -qE "^${key}:" "$current_dir/nanoc.yaml" 2>/dev/null; then
            case "$key" in
                s3_bucket)              echo -e "\n${key}: <S3_BUCKET>" >> "$current_dir/nanoc.yaml" ;;
                cloudfront_distribution_id) echo -e "\n${key}: <DISTRIBUTION_ID>" >> "$current_dir/nanoc.yaml" ;;
                aws_region)             echo -e "\n${key}: eu-west-2" >> "$current_dir/nanoc.yaml" ;;
            esac
            check_pass "nanoc.yaml: added missing key $key (placeholder)"
        fi
    done
else
    check_fail "nanoc.yaml not found and could not be created"
fi

# --- Check: nanoc.yaml deployment keys have real values ---
for key in s3_bucket cloudfront_distribution_id aws_region; do
    value=$(grep -E "^${key}:" "$current_dir/nanoc.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"')
    if [[ -n "$value" && "$value" != "<DISTRIBUTION_ID>" && "$value" != "<S3_BUCKET>" ]]; then
        check_pass "nanoc.yaml: $key = $value"
    else
        check_fail "nanoc.yaml: $key is missing or placeholder — edit nanoc.yaml to set it"
    fi
done

# --- Check: .ruby-version exists; create with default if missing ---
if [[ -f "$current_dir/.ruby-version" ]]; then
    rv=$(<"$current_dir/.ruby-version")
    check_pass ".ruby-version found ($rv)"
else
    echo "$default_ruby_version" > "$current_dir/.ruby-version"
    check_pass ".ruby-version created (${default_ruby_version})"
fi

# --- Check: Gemfile exists; copy from template if missing ---
if [[ -f "$current_dir/Gemfile" ]]; then
    check_pass "Gemfile found"
else
    cp "$SCRIPT_DIR/templates/Gemfile" "$current_dir/Gemfile"
    check_pass "Gemfile copied from template"
fi

# --- Check: Rules exists ---
if [[ -f "$current_dir/Rules" ]]; then
    check_pass "Rules found"
else
    check_fail "Rules not found and could not be created"
fi

# --- Check: layouts/ exists ---
if [[ -d "$current_dir/layouts" ]] && ls "$current_dir/layouts"/* &>/dev/null 2>&1; then
    check_pass "layouts/ has files"
else
    check_fail "layouts/ is missing or empty"
fi

# --- Check: content/ exists ---
if [[ -d "$current_dir/content" ]] && ls "$current_dir/content"/* &>/dev/null 2>&1; then
    check_pass "content/ has files"
else
    check_fail "content/ is missing or empty"
fi

# --- Check: lib/helpers.rb requires the shared Ruby helpers ---
helpers_file="$current_dir/lib/helpers.rb"
shared_helpers_require="require_relative '../nanoc-shared-scripts/lib/shared_helpers'"
if [[ -f "$helpers_file" ]]; then
    if grep -q "nanoc-shared-scripts/lib/shared_helpers" "$helpers_file"; then
        check_pass "lib/helpers.rb requires nanoc-shared-scripts/lib/shared_helpers"
    else
        check_fail "lib/helpers.rb does not require shared_helpers.rb — add this line near the top of lib/helpers.rb: ${shared_helpers_require}"
    fi
else
    mkdir -p "$current_dir/lib"
    echo "$shared_helpers_require" > "$helpers_file"
    check_pass "lib/helpers.rb created with shared_helpers require"
fi

# --- Check: screenshot-overrides.js exists; copy from template if missing ---
if [[ -f "$current_dir/screenshot-overrides.js" ]]; then
    check_pass "screenshot-overrides.js found"
else
    cp "$SCRIPT_DIR/templates/screenshot-overrides.js" "$current_dir/screenshot-overrides.js"
    check_pass "screenshot-overrides.js copied from template"
fi

# --- Check: .github/workflows/deploy.yml exists; copy/update from template ---
workflow_file="$current_dir/.github/workflows/deploy.yml"
mkdir -p "$current_dir/.github/workflows"
if [[ -f "$workflow_file" ]] && diff -q "$workflow_file" "$SCRIPT_DIR/templates/deploy.yml" &>/dev/null; then
    check_pass ".github/workflows/deploy.yml is up to date"
else
    cp "$SCRIPT_DIR/templates/deploy.yml" "$workflow_file"
    check_pass ".github/workflows/deploy.yml updated from template"
fi

# --- Check: deploy.yml calls the shared reusable workflow ---
if grep -q "nanoc-shared-scripts" "$workflow_file"; then
    check_pass "deploy.yml calls the nanoc-shared-scripts reusable workflow"
else
    check_fail "deploy.yml does not reference nanoc-shared-scripts — update it to use the reusable workflow"
fi

# --- Check: shared scripts are executable ---
for script in deploy.sh run.sh setup.sh lib/_shared.sh validate.sh check-layouts.sh generate-transcripts.sh; do
    script_path="$SCRIPT_DIR/${script}"
    if [[ -x "$script_path" ]]; then
        check_pass "${script} is executable"
    else
        check_fail "${script} is not executable — run: chmod +x nanoc-shared-scripts/${script}"
    fi
done

# --- Check: AWS credentials reachable ---
if aws sts get-caller-identity &>/dev/null; then
    check_pass "AWS credentials valid"
else
    check_fail "AWS credentials not reachable — check AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY or run 'aws configure'"
fi

# --- Summary ---
echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
echo ""

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo -e "${FAIL} Validation failed. Fix the issues above and re-run."
    exit 1
fi

# --- Ensure local-only files are gitignored ---
gitignore_file="$current_dir/.gitignore"
for entry in .validated run.sh deploy.sh check-layouts.sh generate-transcripts.sh; do
    if grep -q "^${entry}$" "$gitignore_file" 2>/dev/null; then
        echo -e "${PASS} .gitignore already ignores ${entry}"
    else
        # printf ensures a newline before the entry even if the file lacks a trailing newline
        printf "\n%s\n" "$entry" >> "$gitignore_file"
        echo -e "${PASS} Added ${entry} to .gitignore"
    fi
done

# --- Write .validated ---
shared_sha=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
project_name=$(basename "$current_dir")
validated_file="$current_dir/.validated"
{
    echo "Validated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Shared scripts ref: $shared_sha"
    echo "Project: $project_name"
} > "$validated_file"
echo -e "${PASS} Written: .validated"

# --- Create symlinks at project root ---
for script in run.sh deploy.sh check-layouts.sh generate-transcripts.sh; do
    target="nanoc-shared-scripts/${script}"
    link="$current_dir/${script}"
    if [[ -L "$link" ]]; then
        existing_target=$(readlink "$link")
        if [[ "$existing_target" == "$target" ]]; then
            echo -e "${PASS} Symlink already correct: ${script} -> ${target}"
            continue
        else
            echo -e "${WARN} Symlink ${script} points to ${existing_target} — updating to ${target}"
            rm "$link"
        fi
    elif [[ -f "$link" ]]; then
        echo -e "${WARN} ${script} exists as a regular file — skipping symlink creation (remove it manually if you want the symlink)"
        continue
    fi
    ln -s "$target" "$link"
    echo -e "${PASS} Created symlink: ${script} -> ${target}"
done

echo ""
echo -e "${PASS} Validation complete. You can now run:"
echo -e "  ${WHITE}./run.sh${NC}                  — watch + serve at localhost:3000"
echo -e "  ${WHITE}./deploy.sh${NC}               — full production deploy"
echo -e "  ${WHITE}./check-layouts.sh${NC}        — visual regression screenshot comparison"
echo -e "  ${WHITE}./generate-transcripts.sh${NC} — batch-generate video caption transcripts"
echo ""
echo "If .gitignore was updated, commit it:"
echo "  git add .gitignore && git commit -m \"Gitignore local script symlinks and .validated\""
