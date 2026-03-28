#!/bin/bash
# One-time setup verification for a nanoc project using nanoc-shared-scripts as a submodule.
# Run from the project root after adding the submodule, or after a significant update.
# On success: writes .validated to the project root and creates run.sh / deploy.sh symlinks.
source "$(dirname "${BASH_SOURCE[0]}")/shared.sh"

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

# --- Check: nanoc.yaml exists ---
if [[ -f "$current_dir/nanoc.yaml" ]]; then
    check_pass "nanoc.yaml found"
else
    check_fail "nanoc.yaml not found — run this script from the project root"
fi

# --- Check: nanoc.yaml contains required keys ---
for key in s3_bucket cloudfront_distribution_id aws_region; do
    value=$(grep -E "^${key}:" "$current_dir/nanoc.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"')
    if [[ -n "$value" && "$value" != "<DISTRIBUTION_ID>" ]]; then
        check_pass "nanoc.yaml: $key = $value"
    else
        check_fail "nanoc.yaml: $key is missing or unset"
    fi
done

# --- Check: .ruby-version exists ---
if [[ -f "$current_dir/.ruby-version" ]]; then
    rv=$(<"$current_dir/.ruby-version")
    check_pass ".ruby-version found ($rv)"
else
    check_fail ".ruby-version not found"
fi

# --- Check: .github/workflows/deploy.yml exists; create if missing ---
workflow_file="$current_dir/.github/workflows/deploy.yml"
if [[ -f "$workflow_file" ]]; then
    check_pass ".github/workflows/deploy.yml found"
else
    mkdir -p "$current_dir/.github/workflows"
    cp "$SCRIPT_DIR/templates/deploy.yml" "$workflow_file"
    check_pass ".github/workflows/deploy.yml created"
fi

# --- Check: deploy.yml calls the shared reusable workflow ---
if grep -q "nanoc-shared-scripts" "$workflow_file"; then
    check_pass "deploy.yml calls the nanoc-shared-scripts reusable workflow"
else
    check_fail "deploy.yml does not reference nanoc-shared-scripts — update it to use the reusable workflow"
fi

# --- Check: shared scripts are executable ---
for script in deploy.sh run.sh shared.sh validate.sh; do
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
for entry in .validated run.sh deploy.sh; do
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
for script in run.sh deploy.sh; do
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
echo -e "  ${WHITE}./run.sh${NC}     — watch + serve at localhost:3000"
echo -e "  ${WHITE}./deploy.sh${NC}  — full production deploy"
echo ""
echo "If .gitignore was updated, commit it:"
echo "  git add .gitignore && git commit -m \"Gitignore local script symlinks and .validated\""
