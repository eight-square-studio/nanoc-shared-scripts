# NSS: Add `--deploy-only` flag to deploy.sh

## Problem

`deploy.sh` hardcodes the full pipeline: wipe `output/` → Ruby setup via
`initiate` → `nanoc compile` → S3 upload → CloudFront invalidation → release
tag. External CI pipelines (e.g. card image generation) need only the deploy
half — they populate `output/` themselves and want S3 sync, change detection,
CloudFront invalidation, and `.deployed` tracking without Ruby/nanoc.

## Change

Add a `--deploy-only` flag to `deploy.sh` that skips the compile phase and
deploys `output/` as-is.

### What changes

**File:** `deploy.sh`

1. Add `DEPLOY_ONLY=false` variable
2. Add `--deploy-only` to the arg parser (`while [[ $# -gt 0 ]]`)
3. Wrap the compile block in a conditional:

```bash
if [[ "$DEPLOY_ONLY" == false ]]; then
    rm -rf output/
    initiate
    bundle exec nanoc compile
else
    if [[ ! -d "output" ]]; then
        echo -e "${FAIL} --deploy-only requires output/ to exist"
        exit 1
    fi
    echo -e "${PASS} --deploy-only: skipping compile, deploying output/ as-is"
fi
```

4. Update `print_help` to document the flag

### What doesn't change

Everything after the compile block stays identical:
- `check_for_awscli`
- `read_deploy_config`
- `check_aws_auth`
- `deploy_with_hash_check` (SHA256 change detection, selective S3 upload)
- `delete_removed_files` (S3 cleanup of removed files)
- CloudFront invalidation (only changed/deleted paths)
- `save_deployment_hashes` + `commit_deployed_file` + `create_release_tag`

No new functions. No changes to `_shared.sh`. No changes to any other script.

### Behaviour matrix

| Flag | `output/` exists | Result |
|------|------------------|--------|
| (none) | N/A | Wipes output/, runs initiate + compile, deploys (existing behaviour) |
| `--deploy-only` | Yes | Skips compile, deploys output/ as-is |
| `--deploy-only` | No | Exits with error |

### Docs updates

**CLAUDE.md** — add `--deploy-only` to the deploy.sh flags table.

**README.md** — add `--deploy-only` to the deploy.sh usage section.

**CHANGELOG.md** — entry under today's date.

## Use case

CI workflow generates card images into `output/cards/google/` via a Swift
CLI tool, then calls `deploy.sh --deploy-only` to upload only new/changed
images using the existing hash-based change detection pipeline. No Ruby, no
nanoc, no unnecessary setup.

```bash
# External CI populates output/
swift run CardGenerator --output output/cards/google/

# Deploy just those files
bash ./nanoc-shared-scripts/deploy.sh --deploy-only
```

## Testing

1. Run `deploy.sh --deploy-only` with no `output/` → should exit 1
2. Run `mkdir -p output && touch output/test.txt && deploy.sh --deploy-only` → should attempt S3 upload (will fail without AWS config, but proves the flag works)
3. Run `deploy.sh` without the flag → existing behaviour unchanged
4. Run `deploy.sh --help` → shows `--deploy-only` in usage
