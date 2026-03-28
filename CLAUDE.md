# nanoc-shared-scripts — Claude Code Guide

Shell scripts and GitHub Actions reusable workflow for nanoc static sites.
Consumed by nanoc project repos via git submodule at `scripts/shared/`.

> **Maintenance:** Keep this file up to date when scripts change behaviour,
> new flags are added, or the reusable workflow is modified.

---

## Repo structure

```
scripts/
  shared.sh     # Sourced by all other scripts — setup functions, colours, vars
  deploy.sh     # S3 sync, CloudFront invalidation, release tagging
  run.sh        # Watch + serve (default) or one-off compile (--no-watch)
  validate.sh   # One-time setup check; writes .validated and creates symlinks
.github/
  workflows/
    deploy.yml  # Reusable workflow — called by consumer repos
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
Usage: ./run.sh [-c|--clean] [-n|--no-watch] [-h|--help]

  -c, --clean     Remove output/ before running
  -n, --no-watch  Compile once only (no watch, no serve)
  -h, --help      Show this help message
```

Default (no flags): runs `nanoc compile -W` in the background and `nanoc view -L`
(watch mode + local server at http://localhost:3000).

With `--no-watch`: runs `nanoc compile` once and exits.

### deploy.sh
Full production deploy pipeline. Must be run from the project root
(directory containing `nanoc.yaml`) — exits with an error if not.

**Pipeline:**
1. Wipes `output/` and recompiles from scratch (`nanoc compile`)
2. Checks AWS credentials (`sts get-caller-identity`; falls back to `aws login`)
3. Reads `s3_bucket`, `cloudfront_distribution_id`, `aws_region` from `nanoc.yaml`
4. Generates SHA256 hashes of all files in `output/`
5. Compares against `.deployed` (previous deploy hashes) — uploads only changed/new files
6. Deletes from S3 any files present in `.deployed` but absent from `output/`
7. Invalidates only the changed/deleted paths on CloudFront (not `/*`)
8. Saves updated hashes to `.deployed` and commits it as `*** Release YYYY-MM-DD ***`
9. Creates a sequential release tag (`YYYY-MM-DD-NN`) and pushes

**Dependencies on the consumer project (must exist in CWD):**
- `nanoc.yaml` — deploy config (`s3_bucket`, `cloudfront_distribution_id`, `aws_region`)
- `.ruby-version` — Ruby version for rbenv
- `output/` — built by nanoc compile step
- `.deployed` — created on first deploy, committed thereafter

### validate.sh
One-time setup verification. Run after adding the submodule to a new project,
or after a significant submodule update.

Checks: `nanoc.yaml` present + keys set, `.ruby-version` present,
`.github/workflows/deploy.yml` present and references `nanoc-shared-scripts`, AWS credentials reachable.

On success writes `.validated` to the project root with a timestamp and the
shared scripts git SHA, and creates symlinks `run.sh` and `deploy.sh` at the
project root pointing to the submodule scripts. Symlinks are committed to the
project repo. `.validated` is gitignored — local machine state only.

```bash
bash ./scripts/shared/scripts/validate.sh
```

---

## Reusable workflow (.github/workflows/deploy.yml)

Called by consumer repos via:
```yaml
uses: thomcowell/nanoc-shared-scripts/.github/workflows/deploy.yml@main
```

**Trigger:** `workflow_call` only — not triggered directly.

**Secrets required (passed by caller):**
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`

**What it does:** checkout (full history + submodules) → Ruby setup → `bundle install`
→ git identity → AWS credentials → `bash ./scripts/shared/scripts/deploy.sh`
→ merge `release` → `main`

**Permissions needed in caller:** `contents: write` (to push `.deployed` commit,
release tags, and the merge back to `main`).

---

## Conventions

- All scripts use `#!/bin/bash` and are macOS-primary (setup checks use `brew`/`rbenv`)
- CI skips all setup checks when `$CI` env var is set
- `current_dir` is set to `$PWD` in `shared.sh` — scripts must always be run from the project root
- Hash commands handle both platforms via `sha256_file()`: `sha256sum` (Linux) and `shasum -a 256` (macOS)
- Scripts source `shared.sh` using `source "$(dirname "${BASH_SOURCE[0]}")/shared.sh"`
  — `shared.sh` must always live in the same directory as the scripts that source it
- Colour/formatting constants (`PASS`, `FAIL`, etc.) are defined in `shared.sh`

---

## Adding a new consumer project

1. Add submodule: `git submodule add https://github.com/thomcowell/nanoc-shared-scripts scripts/shared`
2. Replace `.github/workflows/deploy.yml` with the caller pattern (see README.md)
3. Run `bash ./scripts/shared/scripts/validate.sh` (adds `.validated` to `.gitignore` automatically)
4. Commit the symlinks: `git add run.sh deploy.sh .gitignore && git commit -m "Add symlinks to shared scripts"`
5. Update the project's `CLAUDE.md` to note that scripts live in `scripts/shared/scripts/`

## Updating scripts in a consumer project

```bash
git submodule update --remote scripts/shared
git add scripts/shared
git commit -m "Update shared scripts to latest"
```

Re-run `validate.sh` after a significant update.
