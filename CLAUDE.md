# nanoc-shared-scripts — Claude Code Guide

Shell scripts and GitHub Actions reusable workflow for nanoc static sites.
Consumed by nanoc project repos via git submodule at `nanoc-shared-scripts/`.

> **Maintenance:** Keep this file up to date when scripts change behaviour,
> new flags are added, or the reusable workflow is modified.

---

## Repo structure

```
shared.sh     # Sourced by all other scripts — setup functions, colours, vars
deploy.sh     # S3 sync, CloudFront invalidation, release tagging
run.sh        # Watch + serve (default) or one-off compile (--no-watch)
validate.sh   # One-time setup check; writes .validated and creates symlinks
templates/
  deploy.yml  # Full workflow — copied into consumer projects by validate.sh
CLAUDE.md
README.md
```

---

## Scripts

### shared.sh
Not called directly — sourced by `deploy.sh`, `run.sh`, and `validate.sh`.

Sets `current_dir` to `$PWD` (the calling script's working directory — i.e. the project root).
All scripts must be run from the project root; `deploy.sh` and `run.sh` enforce this with a
`nanoc.yaml` presence check.

| Function | Purpose |
|----------|---------|
| `sha256_file()` | Cross-platform SHA256: `sha256sum` (Linux) or `shasum -a 256` (macOS) |
| `get_ruby_version()` | Reads `.ruby-version` from CWD or defaults to `3.4.7` |
| `check_os_type()` | Validates macOS; prompts Homebrew install if missing |
| `check_for_rbenv()` | Validates rbenv; offers brew install |
| `validate_and_install_ruby()` | Ensures correct Ruby version via rbenv |
| `set_up_bundler()` | Runs `bundle install` |
| `check_for_nanoc()` | Validates nanoc is available |
| `initiate()` | Runs all of the above in sequence; skipped entirely if `$CI` is set |

### run.sh
Sets up the environment then compiles the site.

```
Usage: ./run.sh [-c|--clean] [-n|--no-watch] [-o|--host HOST] [-p|--port PORT] [-h|--help]

  -c, --clean      Remove output/ before running
  -n, --no-watch   Compile once only (no watch, no serve)
  -o, --host HOST  Bind the server to HOST (default: 127.0.0.1; use 0.0.0.0 for all interfaces)
  -p, --port PORT  Listen on PORT (default: 3000)
  -h, --help       Show this help message
```

Default (no flags): runs `nanoc compile -W` in the background and `nanoc view -L`
(watch mode + local server at http://localhost:3000).

With `--no-watch`: runs `nanoc compile` once and exits.

### deploy.sh
Full production deploy pipeline. Must be run from the project root
(directory containing `nanoc.yaml`) — exits with an error if not.

**Pipeline:**
1. Wipes `output/` and recompiles from scratch (`nanoc compile`)
2. Checks `awscli` is installed (installs via brew on macOS if missing)
3. Reads `s3_bucket`, `cloudfront_distribution_id`, `aws_region` from `nanoc.yaml`
4. Checks AWS credentials (`sts get-caller-identity`; locally falls back to `aws login --region`; in CI exits on failure)
5. Generates SHA256 hashes of all files in `output/`
6. Compares against `.deployed` (previous deploy hashes) — uploads only changed/new files
7. Deletes from S3 any files present in `.deployed` but absent from `output/`
8. Invalidates only the changed/deleted paths on CloudFront (not `/*`)
9. Saves updated hashes to `.deployed` and commits it as `*** Release YYYY-MM-DD ***`
10. Creates a sequential release tag (`YYYY-MM-DD-NN`) and pushes

**Dependencies on the consumer project (must exist in CWD):**
- `nanoc.yaml` — deploy config (`s3_bucket`, `cloudfront_distribution_id`, `aws_region`)
- `.ruby-version` — Ruby version for rbenv
- `output/` — built by nanoc compile step
- `.deployed` — created on first deploy, committed thereafter

### validate.sh
One-time setup verification. Run after adding the submodule to a new project,
or after a significant submodule update.

Checks:
- `nanoc.yaml` present and contains `s3_bucket`, `cloudfront_distribution_id`, `aws_region`
- `.ruby-version` present
- `.github/workflows/deploy.yml` always synced from `templates/deploy.yml` (copied/updated on every run); checks it contains the string `nanoc-shared-scripts` (satisfied by the `bash ./nanoc-shared-scripts/deploy.sh` run step)
- `deploy.sh`, `run.sh`, `shared.sh`, `validate.sh` are executable
- AWS credentials reachable via `sts get-caller-identity`

On success writes `.validated` to the project root with a timestamp and the
shared scripts git SHA, creates symlinks `run.sh` and `deploy.sh` at the project
root, and adds `.validated`, `run.sh`, and `deploy.sh` to `.gitignore`. All three
are local machine state only — recreated by validate on each machine.

```bash
bash ./nanoc-shared-scripts/validate.sh
```

---

## Consumer workflow (templates/deploy.yml)

Copied into consumer projects at `.github/workflows/deploy.yml` by `validate.sh`.

**Triggers:**
- `push` to `release` branch — primary trigger for production deploys
- `workflow_call` — can also be called as a reusable workflow from another workflow

**Secrets required:**
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`
- `GH_PAT` — personal access token with `repo` scope, used by `actions/checkout` to pull the private submodule

**What it does:** checkout (full history + recursive submodules, authenticated via `GH_PAT`) → Ruby setup → `bundle install`
→ nanoc version check → git identity → AWS credentials → `bash ./nanoc-shared-scripts/deploy.sh` (with `CI=true`)
→ merge `release` → `main`

**Permissions:** `contents: write` at workflow level (to push `.deployed` commit, release tags, and the merge back to `main`).

**Note:** The workflow runs all steps directly on `ubuntu-latest` — there is no separate reusable workflow in this repo. `submodules: recursive` ensures the nanoc-shared-scripts submodule is checked out in the consumer project. The `workflow_call` trigger allows the workflow to be called from another workflow in the consumer repo if needed (secrets must be passed by the caller).

---

## Conventions

- All scripts use `#!/bin/bash` and are macOS-primary (setup checks use `brew`/`rbenv`)
- CI skips all setup checks when `$CI` env var is set
- `current_dir` is set to `$PWD` in `shared.sh` — scripts must always be run from the project root
- Hash commands handle both platforms via `sha256_file()`: `sha256sum` (Linux) and `shasum -a 256` (macOS)
- `deploy.sh` and `run.sh` resolve symlinks before sourcing `shared.sh` (they're accessed via symlinks from the project root); `validate.sh` uses the simpler `source "$(dirname "${BASH_SOURCE[0]}")/shared.sh"` since it's always run directly
  — `shared.sh` must always live in the same directory as the scripts that source it
- Colour/formatting constants (`PASS`, `FAIL`, etc.) are defined in `shared.sh`

---

## Adding a new consumer project

1. Add submodule: `git submodule add https://github.com/eight-square-studio/nanoc-shared-scripts nanoc-shared-scripts`
2. Run `bash ./nanoc-shared-scripts/validate.sh` (creates workflow, gitignores local files, creates symlinks)
3. Commit: `git add .gitignore .github/workflows/deploy.yml nanoc-shared-scripts && git commit -m "Add shared scripts"`
4. Update the project's `CLAUDE.md` to note that scripts live in `nanoc-shared-scripts/`

## Updating scripts in a consumer project

```bash
git submodule update --remote nanoc-shared-scripts
git add nanoc-shared-scripts
git commit -m "Update shared scripts to latest"
```

Re-run `validate.sh` after a significant update.
