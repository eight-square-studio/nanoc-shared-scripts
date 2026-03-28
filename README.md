# nanoc-shared-scripts

Shell scripts and a reusable GitHub Actions workflow for nanoc static sites.
Consumed by nanoc project repos via git submodule at `nanoc-shared-scripts/`.

Note:
- macOS-primary, can be adapted to *nix environments.
- Setup currently checks require Homebrew and rbenv installed.
- All setup is skipped in CI environments (`$CI` env var).

---

## Adding this to a new project

1. `git submodule add https://github.com/eight-square-studio/nanoc-shared-scripts nanoc-shared-scripts`
2. Run `bash ./nanoc-shared-scripts/validate.sh` (creates `.github/workflows/deploy.yml`, adds `.validated` to `.gitignore`, and creates symlinks automatically)
3. Commit: `git add run.sh deploy.sh .gitignore .github/workflows/deploy.yml && git commit -m "Add shared scripts"`

## Updating to the latest scripts

```bash
git submodule update --remote nanoc-shared-scripts
git add nanoc-shared-scripts
git commit -m "Update shared scripts to latest"
```

Re-run `validate.sh` after a significant update.

---

## First-time setup

After adding this repo as a submodule, run the validation script from the
project root to confirm everything is wired up correctly:

```bash
bash ./nanoc-shared-scripts/validate.sh
```

This checks your `nanoc.yaml` config, `.ruby-version`, GitHub Actions workflow,
and AWS credentials, then writes a `.validated` timestamp file and creates
`run.sh` / `deploy.sh` symlinks at the project root on success.

---

## Scripts

### run.sh — local development

Sets up the environment and compiles the site.

```bash
./nanoc-shared-scripts/run.sh              # watch mode + local server (default)
./nanoc-shared-scripts/run.sh --no-watch   # one-off compile, then exit
./nanoc-shared-scripts/run.sh --clean      # wipe output/ before running
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
./nanoc-shared-scripts/deploy.sh
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
bash ./nanoc-shared-scripts/validate.sh
```

Writes `.validated` to the project root on success. Creates `run.sh` and `deploy.sh`
symlinks and adds all three to `.gitignore` — local machine state only, not committed.

---

## GitHub Actions

A reusable workflow is provided at `.github/workflows/deploy.yml`.

Call it from your project's workflow:

```yaml
name: Deploy
on:
  push:
    branches: [release]

permissions:
  contents: write

jobs:
  deploy:
    uses: eight-square-studio/nanoc-shared-scripts/.github/workflows/deploy.yml@main
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
