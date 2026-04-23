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
2. Run `bash ./nanoc-shared-scripts/validate.sh` (copies `deploy.yml` into `.github/workflows/`, adds `.validated` to `.gitignore`, and creates symlinks automatically — re-run after any submodule update to keep the workflow in sync)
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
./nanoc-shared-scripts/run.sh                        # watch mode + local server (default)
./nanoc-shared-scripts/run.sh --no-watch             # one-off compile, then exit
./nanoc-shared-scripts/run.sh --clean                # wipe output/ before running
./nanoc-shared-scripts/run.sh --host 0.0.0.0         # listen on all interfaces (LAN/VPN)
./nanoc-shared-scripts/run.sh --port 3003            # use a custom port (default 3000)
./nanoc-shared-scripts/run.sh -o 0.0.0.0 -p 3003     # combine host + port
./nanoc-shared-scripts/run.sh --vscode               # restart Tailscale + launch VS Code web server (no nanoc)
./nanoc-shared-scripts/run.sh --restart-tailscale    # restart Tailscale and exit
```

| Flag | Short | Effect |
|------|-------|--------|
| `--clean` | `-c` | Remove `output/` before running |
| `--no-watch` | `-n` | Compile once only, no file watching, no server |
| `--host HOST` | `-o` | Bind the server to HOST (default: `127.0.0.1`). Use `0.0.0.0` to listen on all interfaces (useful for accessing the site from other devices on your network or over a Tailscale VPN) |
| `--port PORT` | `-p` | Listen on PORT (default: `3000`) |
| `--vscode` | | Restart Tailscale, then run `code serve-web` on `VSCODE_PORT` (default `8000`) in the foreground — blocks until VS Code exits. No nanoc. Exits with an error if port `8000` is already in use. Skips Tailscale/VS Code gracefully if not installed |
| `--restart-tailscale` | | Restart Tailscale (`tailscale down` → `tailscale up`) and exit — no nanoc, no VS Code |
| `--help` | `-h` | Show usage |

If the chosen nanoc port is already in use, the script automatically increments until
it finds a free one.

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

### check-layouts.sh — visual regression comparison

Compares full-page screenshots of every published page between your current branch
and `release`. Highlights pixel-level differences and flags pages where >1% of pixels changed.

```bash
./check-layouts.sh
```

**Prerequisites:**
- Google Chrome must be installed at `/Applications/Google Chrome.app`
- ImageMagick is auto-installed via Homebrew if missing
- `ferrum` gem is auto-added to your `Gemfile` and installed if missing

Pages are discovered automatically from `content/pages/**/*.haml` — no hardcoded list.
Output (screenshots + HTML report) goes to `tmp/screenshots/` in your project root.
Report opens automatically in your browser on completion. Exits with code 1 if any pages are flagged.

### validate.sh — setup check

One-time verification after adding the submodule or updating it significantly.

```bash
bash ./nanoc-shared-scripts/validate.sh
```

Copies `templates/Gemfile` into the project root if no `Gemfile` exists (existing
Gemfiles are left untouched). Writes `.validated` to the project root on success.
Creates `run.sh`, `deploy.sh`, and `check-layouts.sh` symlinks and adds all four
(plus `.validated`) to `.gitignore` — local machine state only, not committed.

---

## GitHub Actions

`validate.sh` copies `templates/deploy.yml` from this repo into your project at
`.github/workflows/deploy.yml`. This is a self-contained workflow — it runs all
steps directly and does not call back into this repo.

**Triggers:**
- `push` to the `release` branch — primary trigger for production deploys
- `workflow_call` — can be invoked from another workflow in your project if needed

**What it does:** checkout (full history + recursive submodules, authenticated via `GH_PAT`) → Ruby setup →
`bundle install` → nanoc version check → git identity → AWS credentials → `bash ./nanoc-shared-scripts/deploy.sh` (with `CI=true`) →
merge `release` back into `main`

### Secrets required

Set these in GitHub repo Settings → Secrets and variables → Actions:

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | IAM access key with S3 + CloudFront permissions |
| `AWS_SECRET_ACCESS_KEY` | Corresponding secret key |
| `AWS_REGION` | e.g. `eu-west-1` |
| `GH_PAT` | Personal access token (see instructions below) |

### GH_PAT setup

`GH_PAT` is required — the workflow uses it to authenticate the submodule checkout.
Without it the action will fail with "repository not found".

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
