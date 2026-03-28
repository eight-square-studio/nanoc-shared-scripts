# nanoc-shared-scripts

Shell scripts and a reusable GitHub Actions workflow for nanoc static sites.
Consumed by nanoc project repos via git submodule at `scripts/shared/`.

> macOS-primary. Setup checks require Homebrew and rbenv. All setup is skipped
> in CI environments (`$CI` env var).

---

## First-time setup

After adding this repo as a submodule, run the validation script from the
project root to confirm everything is wired up correctly:

```bash
bash ./scripts/shared/scripts/validate.sh
```

This checks your `nanoc.yaml` config, `.ruby-version`, GitHub Actions workflow,
and AWS credentials, then writes a `.validated` timestamp file and creates
`run.sh` / `deploy.sh` symlinks at the project root on success.

---

## Scripts

### run.sh — local development

Sets up the environment and compiles the site.

```bash
./scripts/shared/scripts/run.sh              # watch mode + local server (default)
./scripts/shared/scripts/run.sh --no-watch   # one-off compile, then exit
./scripts/shared/scripts/run.sh --clean      # wipe output/ before running
```

| Flag | Short | Effect |
|------|-------|--------|
| `--no-watch` | `-n` | Compile once only, no file watching, no server |
| `--clean` | `-c` | Remove `output/` before running |
| `--help` | `-h` | Show usage |

Default (no flags): starts `nanoc compile -W` in watch mode and serves at
`http://localhost:3000`.

### deploy.sh — production deploy

Full deploy pipeline. Must be run from the project root (the directory
containing `nanoc.yaml`).

```bash
./scripts/shared/scripts/deploy.sh
```

**What it does:**
1. Wipes `output/` and recompiles from scratch
2. Checks AWS credentials
3. Reads `s3_bucket`, `cloudfront_distribution_id`, `aws_region` from `nanoc.yaml`
4. Uploads only new/changed files to S3 (SHA256 hash comparison)
5. Deletes from S3 any files removed since the last deploy
6. Invalidates only the changed paths on CloudFront
7. Commits `.deployed` as `*** Release YYYY-MM-DD ***`
8. Creates and pushes a sequential release tag (`YYYY-MM-DD-NN`)

### validate.sh — setup check

One-time verification after adding the submodule or updating it significantly.

```bash
bash ./scripts/shared/scripts/validate.sh
```

Writes `.validated` to the project root on success (gitignored — local state only).
Creates `run.sh` and `deploy.sh` symlinks at the project root — commit these.

---

## GitHub Actions

A reusable workflow is provided at `.github/workflows/deploy.yml`.

Call it from your project's workflow:

```yaml
name: Deploy
on:
  push:
    branches: [release]

jobs:
  deploy:
    uses: thomcowell/nanoc-shared-scripts/.github/workflows/deploy.yml@main
    permissions:
      contents: write
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_REGION: ${{ secrets.AWS_REGION }}
```

Triggers on push to the `release` branch. After deploying, merges `release`
back into `main` so the `.deployed` commit and release tag are on both branches.

**Secrets required** (set in GitHub repo Settings → Secrets):
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`

The repo also needs **read + write** permissions for Actions (Settings → Actions → General).

---

## Adding this to a new project

1. `git submodule add https://github.com/thomcowell/nanoc-shared-scripts scripts/shared`
2. Add `.validated` to `.gitignore`
3. Replace `.github/workflows/deploy.yml` with the caller pattern above
4. Run `bash ./scripts/shared/scripts/validate.sh`
5. Commit the symlinks: `git add run.sh deploy.sh && git commit -m "Add symlinks to shared scripts"`

## Updating to the latest scripts

```bash
git submodule update --remote scripts/shared
git add scripts/shared
git commit -m "Update shared scripts to latest"
```

Re-run `validate.sh` after a significant update.
