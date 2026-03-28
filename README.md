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
2. Run `bash ./nanoc-shared-scripts/validate.sh` (copies `deploy.yml` into `.github/workflows/`, adds `.validated` to `.gitignore`, and creates symlinks automatically)
3. Commit: `git add .gitignore .github/workflows/deploy.yml nanoc-shared-scripts && git commit -m "Add shared scripts"`

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
2. Checks `awscli` is installed (installs via brew on macOS if missing)
3. Reads `s3_bucket`, `cloudfront_distribution_id`, `aws_region` from `nanoc.yaml`
4. Checks AWS credentials (locally falls back to `aws login`; in CI exits on failure)
5. Uploads only new/changed files to S3 (SHA256 hash comparison)
6. Deletes from S3 any files removed since the last deploy
7. Invalidates only the changed paths on CloudFront
8. Commits `.deployed` as `*** Release YYYY-MM-DD ***`
9. Creates and pushes a sequential release tag (`YYYY-MM-DD-NN`)

### validate.sh — setup check

One-time verification after adding the submodule or updating it significantly.

```bash
bash ./nanoc-shared-scripts/validate.sh
```

Writes `.validated` to the project root on success. Creates `run.sh` and `deploy.sh`
symlinks and adds all three to `.gitignore` — local machine state only, not committed.

---

## GitHub Actions

`validate.sh` copies `templates/deploy.yml` from this repo into your project at
`.github/workflows/deploy.yml`. This is a self-contained workflow — it runs all
steps directly and does not call back into this repo.

**Triggers:**
- `push` to the `release` branch — primary trigger for production deploys
- `workflow_call` — can be invoked from another workflow in your project if needed

**What it does:** checkout (full history + recursive submodules) → Ruby setup →
`bundle install` → AWS credentials → `bash ./nanoc-shared-scripts/deploy.sh` →
merge `release` back into `main`

### Secrets required

Set these in GitHub repo Settings → Secrets and variables → Actions:

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | IAM access key with S3 + CloudFront permissions |
| `AWS_SECRET_ACCESS_KEY` | Corresponding secret key |
| `AWS_REGION` | e.g. `eu-west-1` |
| `GH_PAT` | Personal access token (see instructions below) |

### Private submodule access (GH_PAT)

If `nanoc-shared-scripts` is a private repo, CI needs a `GH_PAT` secret to check
it out. Without it the action will fail with "repository not found".

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)** https://github.com/settings/tokens
2. Click **Generate new token (classic)**
3. Give it a descriptive name, e.g. `my-project CI`
4. Set an expiry (90 days recommended — rotate when it expires)
5. Tick **`repo`** scope (grants full repo access including private repos)
6. Click **Generate token** and copy it immediately

Then add it to your consumer repo:

1. Go to the repo on GitHub → **Settings → Secrets and variables → Actions**
2. Click **New repository secret**
3. Name: `GH_PAT`, Value: paste the token
4. Click **Add secret**

### Actions permissions

The repo also needs **read + write** permissions for Actions (Settings → Actions → General).
