#!/bin/bash
set -euo pipefail
# Setup environment, compile, and deploy to S3 + CloudFront
# Locally: checks/installs awscli, prompts for AWS auth if needed
# CI ($CI is set): skips local setup, uses environment credentials

# Resolve symlinks to find the real script directory
_s="${BASH_SOURCE[0]}"
while [[ -L "$_s" ]]; do _d="$(cd "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; [[ "$_s" != /* ]] && _s="$_d/$_s"; done
source "$(cd "$(dirname "$_s")" && pwd)/lib/_shared.sh"
source "$(cd "$(dirname "$_s")" && pwd)/lib/deploy_helpers.sh"
BATCH_TOOL="$(cd "$(dirname "$_s")" && pwd)/tools/deploy-batches.rb"
DEPLOY_TMP=""
trap cleanup_deploy_tmp EXIT

if [[ ! -f "nanoc.yaml" ]]; then
    echo "Error: must be run from the project root (nanoc.yaml not found)"
    exit 1
fi

function check_for_awscli(){
    if ! command -v aws &> /dev/null; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            brew install awscli
            echo -e "${PASS} awscli installed"
        else
            command -v unzip &> /dev/null || pkg_install unzip unzip unzip unzip unzip
            local arch
            arch="$(uname -m)"
            local tmp_zip
            tmp_zip="$(mktemp -d)/awscliv2.zip"
            echo -e "${WARN} awscli not found, installing AWS CLI v2 for Linux (${arch})..."
            curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "$tmp_zip"
            unzip -q "$tmp_zip" -d "$(dirname "$tmp_zip")"
            sudo_cmd
            ${SUDO} "$(dirname "$tmp_zip")/aws/install"
            if command -v aws &> /dev/null; then
                echo -e "${PASS} awscli installed"
            else
                echo -e "${FAIL} awscli install failed — install manually: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
                exit 4
            fi
        fi
    else
        echo -e "${PASS} awscli has been found"
    fi
}

function apply_staging_nanoc_config() {
    local config_file="$current_dir/nanoc.yaml"
    local staging_block
    staging_block=$(awk '/^staging:/{found=1; next} found && /^[^ ]/{exit} found' "$config_file")
    [[ -z "$staging_block" ]] && return 0

    local nanoc_overrides
    nanoc_overrides=$(echo "$staging_block" | grep -vE '^\s*(s3_bucket|cloudfront_distribution_id|aws_region|#):' | grep -v '^\s*$')
    [[ -z "$nanoc_overrides" ]] && return 0

    cp "$config_file" "${config_file}.pre-staging"
    while IFS= read -r line; do
        local key trimmed
        key=$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')
        trimmed=$(echo "$line" | sed 's/^  //')
        if grep -qE "^${key}:" "$config_file"; then
            sed -i.bak "s|^${key}:.*|${trimmed}|" "$config_file" && rm -f "${config_file}.bak"
            echo -e "${PASS} Staging override: ${trimmed}"
        else
            echo "" >> "$config_file"
            echo "$trimmed" >> "$config_file"
            echo -e "${PASS} Staging override (added): ${trimmed}"
        fi
    done <<< "$nanoc_overrides"
}

function restore_nanoc_config() {
    local config_file="$current_dir/nanoc.yaml"
    if [[ -f "${config_file}.pre-staging" ]]; then
        mv "${config_file}.pre-staging" "$config_file"
        echo -e "${PASS} Restored nanoc.yaml"
    fi
}

function check_aws_auth() {
    if [[ -n "${CI:-}" ]]; then
        # In CI, credentials are injected via environment — just validate they work
        if aws sts get-caller-identity &>/dev/null; then
            echo -e "${PASS} AWS authenticated"
            return
        else
            echo -e "${FAIL} AWS authentication failed. Check that AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_REGION secrets are set."
            exit 6
        fi
    fi
    # Local: check env vars, then fall back to interactive login
    # (use :- defaults — these are commonly unset entirely for devs who
    # authenticate via ~/.aws/credentials or SSO instead of env vars)
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        echo -e "${PASS} AWS credentials found in environment"
    fi
    if aws sts get-caller-identity &>/dev/null; then
        echo -e "${PASS} AWS authenticated"
        return
    fi
    echo -e "${WARN} Not authenticated — running aws login..."
    aws login --region $AWS_REGION
    if aws sts get-caller-identity &>/dev/null; then
        echo -e "${PASS} AWS authenticated"
    else
        echo -e "${FAIL} AWS authentication failed."
        echo -e "  Check your credentials or set ${WHITE}AWS_ACCESS_KEY_ID${NC} / ${WHITE}AWS_SECRET_ACCESS_KEY${NC} in your environment."
        exit 6
    fi
}

function cleanup_deploy_tmp() {
    [[ -n "${DEPLOY_TMP:-}" && -d "$DEPLOY_TMP" ]] && rm -rf "$DEPLOY_TMP"
    return 0
}

function check_for_batch_tool() {
    if ! command -v ruby &> /dev/null; then
        echo -e "${FAIL} ruby not found — required by tools/deploy-batches.rb (hashing, batching)"
        exit 4
    fi
}

# Hash output/ once. Lines are "sha256  relative/path", LC_ALL=C sorted — the
# same format as .deployed, so manifests can be diffed with comm.
function build_manifest() {
    ruby "$BATCH_TOOL" manifest --dir "${current_dir}/output" > "$1"
}

# "sha256  path" lines on stdin -> bare paths on stdout
function strip_hashes() {
    sed 's/^[0-9a-f]\{64\}  //'
}

# Upload the keys listed in $2 under one `aws s3 cp --recursive` (parallel
# transfers). Successful keys are appended to $DEPLOY_TMP/uploaded.txt.
# Returns non-zero if anything failed.
function upload_batch() {
    local s3_bucket="$1" list="$2" label="$3"
    [[ -s "$list" ]] || return 0
    local stage="${DEPLOY_TMP}/stage-${label}"
    local out="${DEPLOY_TMP}/upload-${label}.out" err="${DEPLOY_TMP}/upload-${label}.err"
    local rc=0
    mkdir -p "$stage"
    ruby "$BATCH_TOOL" stage --src "${current_dir}/output" --dest "$stage" < "$list"
    aws s3 cp "${stage}/" "s3://${s3_bucket}/" --recursive --no-progress > "$out" 2> "$err" < /dev/null || rc=$?
    sed -n "s|^upload: .* to s3://${s3_bucket}/||p" "$out" >> "${DEPLOY_TMP}/uploaded.txt"
    if [[ $rc -ne 0 ]]; then
        sed 's/^/    /' "$err" >&2
    fi
    return $rc
}

# Delete the keys in $1 from S3 in batches of up to 1000.
# Keys S3 confirms are appended to $DEPLOY_TMP/deleted_ok.txt.
function delete_batch() {
    local s3_bucket="$1" list="$2"
    local rc=0 line response
    ruby "$BATCH_TOOL" delete < "$list" > "${DEPLOY_TMP}/delete-batches.jsonl"
    while IFS= read -r line; do
        response=$(aws s3api delete-objects --bucket "$s3_bucket" --delete "$line" --output json < /dev/null) || rc=1
        printf '%s' "$response" | ruby "$BATCH_TOOL" delete-result >> "${DEPLOY_TMP}/deleted_ok.txt" || rc=1
    done < "${DEPLOY_TMP}/delete-batches.jsonl"
    return $rc
}

function plan_invalidation_paths() {
    ruby "$BATCH_TOOL" invalidate --group-threshold "$CF_GROUP_THRESHOLD" \
        --all-threshold "$CF_INVALIDATE_ALL_THRESHOLD" --list < "$1"
}

function invalidate_cloudfront() {
    local affected="$1"
    local batches="${DEPLOY_TMP}/invalidations.jsonl"
    local path_count request_count line
    path_count=$(plan_invalidation_paths "$affected" | wc -l | tr -d ' ')
    ruby "$BATCH_TOOL" invalidate --group-threshold "$CF_GROUP_THRESHOLD" \
        --all-threshold "$CF_INVALIDATE_ALL_THRESHOLD" --ref "$(date +%s)-$$" < "$affected" > "$batches"
    request_count=$(wc -l < "$batches" | tr -d ' ')
    echo -e "${PASS} Invalidating ${path_count} CloudFront path(s) in ${request_count} request(s) on ${CF_DIST_ID}..."
    while IFS= read -r line; do
        aws cloudfront create-invalidation \
            --distribution-id "$CF_DIST_ID" \
            --invalidation-batch "$line" \
            --query 'Invalidation.Id' --output text --no-cli-pager < /dev/null \
            | sed "s/^/    invalidation /"
    done < "$batches"
}

# Rewrite .deployed from the manifest we just hashed. Files whose upload (or
# delete) failed keep their PREVIOUS entry (or none, if new) so the next run
# retries them instead of treating them as deployed.
function write_deployed_file() {
    local keep="${DEPLOY_TMP}/keep-previous.txt"
    local deployed_file="${current_dir}/.deployed"
    {
        awk -v keep="$keep" 'BEGIN{while ((getline l < keep) > 0) bad[l]=1} {if (!(substr($0,67) in bad)) print}' "${DEPLOY_TMP}/current.manifest"
        awk -v keep="$keep" 'BEGIN{while ((getline l < keep) > 0) bad[l]=1} {if (substr($0,67) in bad) print}' "${DEPLOY_TMP}/previous.manifest"
    } | LC_ALL=C sort > "$deployed_file"
}

function commit_deployed_file() {
    local today
    today=$(date +%Y-%m-%d)
    git -C "$current_dir" add "${current_dir}/.deployed"
    git -C "$current_dir" commit -m "*** Release ${today} ***"
    echo -e "${PASS} Committed .deployed for release ${today}" >&2
}

function get_latest_release_tag() {
    local today
    today=$(date +%Y-%m-%d)
    git -C "$current_dir" tag -l "${today}-*" | sort -t'-' -k4 -n | tail -1
}

function create_release_tag() {
    local today
    today=$(date +%Y-%m-%d)
    local latest_tag
    latest_tag=$(get_latest_release_tag)
    local next_num
    if [[ -z "$latest_tag" ]]; then
        next_num="01"
    else
        local current_num="${latest_tag##*-}"
        next_num=$(printf "%02d" $((10#$current_num + 1)))
    fi
    local new_tag="${today}-${next_num}"
    git -C "$current_dir" tag "$new_tag"
    echo -e "${PASS} Tagged release: ${new_tag}" >&2
    git push
    git push --tags
    echo "$new_tag"
}

function print_help() {
    echo -e "Usage: ./deploy.sh [--deploy-only] [--staging] [--dry-run] [-h|--help]

Wipes output/, compiles the site, and deploys to S3 + CloudFront.
Only uploads new/changed files (hash-based), in parallel batches. Deletes removed
files from S3 in batches and invalidates the affected CloudFront paths in grouped
requests. Commits .deployed and creates a release tag only if everything succeeded.

Local:  checks/installs awscli, prompts for AWS auth if needed
CI:     skips local setup, uses AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars

Options:
  --deploy-only  Skip Ruby setup and nanoc compile — deploy output/ as-is
  --staging      Deploy to staging environment (reads staging config from nanoc.yaml,
                 uses s3 sync, skips hash tracking / .deployed commit / release tag)
  --dry-run      Production only: show what would be uploaded, deleted and invalidated,
                 then exit without touching S3, CloudFront, .deployed or git
  -h, --help     Show this help message"
}

# --- Main ---

DEPLOY_ONLY=false
STAGING=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --deploy-only)
            DEPLOY_ONLY=true
            shift
            ;;
        --staging)
            STAGING=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_help
            exit 1
            ;;
    esac
done

if [[ "$DRY_RUN" == true && "$STAGING" == true ]]; then
    echo -e "${FAIL} --dry-run is only supported for production deploys"
    exit 1
fi

if [[ "$DEPLOY_ONLY" == false ]]; then
    rm -rf output/
    [[ "$STAGING" == true ]] && apply_staging_nanoc_config
    initiate
    bundle exec nanoc compile || { [[ "$STAGING" == true ]] && restore_nanoc_config; exit 1; }
    [[ "$STAGING" == true ]] && restore_nanoc_config
else
    if [[ ! -d "output" ]]; then
        echo -e "${FAIL} --deploy-only requires output/ to exist"
        exit 1
    fi
    echo -e "${PASS} --deploy-only: skipping compile, deploying output/ as-is"
fi

if [[ "$DRY_RUN" == false ]]; then
    check_for_awscli
fi
read_deploy_config
if [[ "$DRY_RUN" == false ]]; then
    check_aws_auth
fi

if [[ "$STAGING" == true ]]; then
    echo -e "${PASS} Deploying to s3://${S3_BUCKET}/ (staging — full sync)..."
    exclude_args=""
    if [[ -n "${S3_SYNC_EXCLUDES:-}" ]]; then
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] && exclude_args+=" --exclude ${pattern}"
        done <<< "$S3_SYNC_EXCLUDES"
    fi
    aws s3 sync "${current_dir}/output/" "s3://${S3_BUCKET}/" --delete $exclude_args
    echo -e "${PASS} Invalidating all paths on CloudFront distribution ${CF_DIST_ID}..."
    aws cloudfront create-invalidation \
        --distribution-id "$CF_DIST_ID" \
        --invalidation-batch "{\"Paths\":{\"Quantity\":1,\"Items\":[\"/*\"]},\"CallerReference\":\"$(date +%s)\"}" \
        --no-cli-pager
    echo -e "${PASS} Staging deploy complete"
    exit 0
fi

# --- Production: hash-based batched deploy ---
check_for_batch_tool
DEPLOY_TMP=$(mktemp -d "${current_dir}/.deploy-tmp.XXXXXX")
deployed_file="${current_dir}/.deployed"
export LC_ALL=C   # comm/sort/awk must agree on bytewise ordering

echo -e "${PASS} Deploying to s3://${S3_BUCKET}/ (hash-based, batched)..."
phase_start=$SECONDS
build_manifest "${DEPLOY_TMP}/current.manifest"
if [[ -f "$deployed_file" ]]; then
    sort "$deployed_file" > "${DEPLOY_TMP}/previous.manifest"
else
    echo -e "${WARN} No previous deployment found. All files will be uploaded."
    : > "${DEPLOY_TMP}/previous.manifest"
fi

# changed = new or different hash; deleted = path in the previous manifest only
comm -23 "${DEPLOY_TMP}/current.manifest" "${DEPLOY_TMP}/previous.manifest" | strip_hashes | sort > "${DEPLOY_TMP}/changed.txt"
strip_hashes < "${DEPLOY_TMP}/current.manifest" | sort > "${DEPLOY_TMP}/current.paths"
strip_hashes < "${DEPLOY_TMP}/previous.manifest" | sort > "${DEPLOY_TMP}/previous.paths"
comm -13 "${DEPLOY_TMP}/current.paths" "${DEPLOY_TMP}/previous.paths" > "${DEPLOY_TMP}/deleted.txt"

changed_count=$(wc -l < "${DEPLOY_TMP}/changed.txt" | tr -d ' ')
deleted_count=$(wc -l < "${DEPLOY_TMP}/deleted.txt" | tr -d ' ')
echo -e "${PASS} Hashed output/ in $((SECONDS - phase_start))s: ${changed_count} changed, ${deleted_count} removed"

if [[ "$DRY_RUN" == true ]]; then
    cat "${DEPLOY_TMP}/changed.txt" "${DEPLOY_TMP}/deleted.txt" | sort -u > "${DEPLOY_TMP}/affected.txt"
    if [[ -s "${DEPLOY_TMP}/affected.txt" ]]; then
        echo -e "${PASS} --dry-run: would upload ${changed_count}, delete ${deleted_count}, and invalidate:"
        plan_invalidation_paths "${DEPLOY_TMP}/affected.txt" | sed 's/^/    /'
    else
        echo -e "${PASS} --dry-run: nothing to deploy"
    fi
    exit 0
fi

: > "${DEPLOY_TMP}/uploaded.txt"
: > "${DEPLOY_TMP}/deleted_ok.txt"
upload_failed=false
delete_failed=false

if [[ "$changed_count" -gt 0 ]]; then
    # Assets first, HTML last — a page never goes live ahead of what it references
    grep -v '\.html$' "${DEPLOY_TMP}/changed.txt" > "${DEPLOY_TMP}/changed-assets.txt" || true
    grep '\.html$' "${DEPLOY_TMP}/changed.txt" > "${DEPLOY_TMP}/changed-pages.txt" || true
    phase_start=$SECONDS
    echo -e "${PASS} Uploading ${changed_count} file(s)..."
    upload_batch "$S3_BUCKET" "${DEPLOY_TMP}/changed-assets.txt" assets || upload_failed=true
    if [[ "$upload_failed" == true ]]; then
        echo -e "${FAIL} Asset upload failed — skipping HTML so pages don't go live ahead of their assets"
    else
        upload_batch "$S3_BUCKET" "${DEPLOY_TMP}/changed-pages.txt" pages || upload_failed=true
    fi
    sort -u -o "${DEPLOY_TMP}/uploaded.txt" "${DEPLOY_TMP}/uploaded.txt"
    echo -e "${PASS} Uploaded $(wc -l < "${DEPLOY_TMP}/uploaded.txt" | tr -d ' ')/${changed_count} in $((SECONDS - phase_start))s"
fi

if [[ "$deleted_count" -gt 0 ]]; then
    echo -e "${WARN} Found ${deleted_count} file(s) removed from output — deleting from S3..."
    delete_batch "$S3_BUCKET" "${DEPLOY_TMP}/deleted.txt" || delete_failed=true
    sort -u -o "${DEPLOY_TMP}/deleted_ok.txt" "${DEPLOY_TMP}/deleted_ok.txt"
    echo -e "${PASS} Deleted $(wc -l < "${DEPLOY_TMP}/deleted_ok.txt" | tr -d ' ')/${deleted_count} from S3"
fi

# Anything not confirmed uploaded/deleted keeps its previous .deployed entry
{ comm -23 "${DEPLOY_TMP}/changed.txt" "${DEPLOY_TMP}/uploaded.txt"
  comm -23 "${DEPLOY_TMP}/deleted.txt" "${DEPLOY_TMP}/deleted_ok.txt"; } | sort -u > "${DEPLOY_TMP}/keep-previous.txt"

cat "${DEPLOY_TMP}/uploaded.txt" "${DEPLOY_TMP}/deleted_ok.txt" | sort -u > "${DEPLOY_TMP}/affected.txt"
if [[ -s "${DEPLOY_TMP}/affected.txt" ]]; then
    invalidate_cloudfront "${DEPLOY_TMP}/affected.txt"
else
    echo -e "${PASS} No files changed — nothing to deploy"
fi

echo -e "${PASS} Saving file hashes to .deployed..."
write_deployed_file

if [[ -s "${DEPLOY_TMP}/keep-previous.txt" ]]; then
    echo -e "${FAIL} $(wc -l < "${DEPLOY_TMP}/keep-previous.txt" | tr -d ' ') file(s) failed — .deployed not committed and no release tagged; re-run to retry them"
    exit 1
fi
if [[ -s "${DEPLOY_TMP}/affected.txt" ]]; then
    commit_deployed_file
    create_release_tag
fi
