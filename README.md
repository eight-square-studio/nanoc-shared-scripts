# nanoc-shared-scripts

Shell scripts, a reusable GitHub Actions workflow, and shared Ruby/nanoc helpers
for nanoc static sites. Consumed by nanoc project repos via git submodule at
`nanoc-shared-scripts/`.

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
`run.sh`, `deploy.sh`, `check-layouts.sh`, and `generate-transcripts.sh` symlinks
at the project root on success.

---

## Scripts

### run.sh — local development

Sets up the environment and compiles the site.

```bash
./nanoc-shared-scripts/run.sh                        # watch mode + local server (default)
./nanoc-shared-scripts/run.sh --no-watch             # one-off compile, then exit
./nanoc-shared-scripts/run.sh --clean                # wipe output/ before running
./nanoc-shared-scripts/run.sh --host 0.0.0.0         # listen on all interfaces (LAN/VPN)
./nanoc-shared-scripts/run.sh --any-ip               # shortcut for --host 0.0.0.0
./nanoc-shared-scripts/run.sh --port 3003            # use a custom port (default 3000)
./nanoc-shared-scripts/run.sh -o 0.0.0.0 -p 3003     # combine host + port
./nanoc-shared-scripts/run.sh --restart-tailscale    # restart Tailscale and exit
```

| Flag | Short | Effect |
|------|-------|--------|
| `--clean` | `-c` | Remove `output/` before running |
| `--no-watch` | `-n` | Compile once only, no file watching, no server |
| `--host HOST` | `-o` | Bind the server to HOST (default: `127.0.0.1`) |
| `--any-ip` | `-i` | Use `0.0.0.0` to listen on all interfaces (useful for accessing the site from other devices on your network or over a Tailscale VPN) |
| `--port PORT` | `-p` | Listen on PORT (default: `3000`) |
| `--restart-tailscale` | | Restart Tailscale (`tailscale down` → `tailscale up`) and exit — no nanoc, no VS Code |
| `--help` | `-h` | Show usage |

If the chosen nanoc port is already in use, the script automatically increments until
it finds a free one.

Default (no flags): starts `nanoc compile -W` in watch mode and serves at
`http://localhost:3000`.

### code-server.sh — remote VS Code

Standalone script to run `code-server` with TLS certs for remote browser access.

```bash
./nanoc-shared-scripts/code-server.sh                # run code-server on port 8080
```

Requires TLS certs at `~/.config/certs/` (a `.crt` and `.key` file). Auto-installs
`code-server` via the official install script if not found. Binds to `0.0.0.0:8080`.
Exits with an error if certs are missing or the port is already in use.

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
./check-layouts.sh                 # full compare: current vs release
./check-layouts.sh --screenshot-only   # screenshot current branch only, no compare
./check-layouts.sh -s              # same, short form
```

**Prerequisites:**
- Google Chrome must be installed at `/Applications/Google Chrome.app`
- ImageMagick is auto-installed via Homebrew if missing
- `ferrum` gem is auto-added to your `Gemfile` and installed if missing

Pages are discovered automatically from `content/pages/**/*.haml` — no hardcoded list.
Output (screenshots + HTML report) goes to `tmp/screenshots/` in your project root.
Report opens automatically in your browser on completion. Exits with code 1 if any pages are flagged.

**Customising the freeze script:**

Before each screenshot, the tool injects `screenshot-overrides.js` from your project root.
`validate.sh` creates this file from the template if it doesn't exist. You can edit it to:
- Add extra `100vh` selectors to the pin list (default covers `.hero`, `.section`, `.error-page`, `.login-page`)
- Load additional web font families by name for accurate font rendering
- Add any other page-specific freeze logic

The default freeze script handles animations, transitions, scroll-based fading, `is-visible` reveal classes, and web font + image loading.

### generate-transcripts.sh — video transcripts

Batch-generates WebVTT (`.vtt`) caption transcripts for a folder of videos, using
`whisper.cpp` (local, no API key, nothing leaves the machine).

```bash
./nanoc-shared-scripts/generate-transcripts.sh content/videos                # recursively transcribe everything missing a transcript
./nanoc-shared-scripts/generate-transcripts.sh content/videos/hsbc           # just one subfolder
./nanoc-shared-scripts/generate-transcripts.sh content/videos --force        # regenerate existing transcripts too
./nanoc-shared-scripts/generate-transcripts.sh content/videos --model small.en  # bigger/slower model for better accuracy
./nanoc-shared-scripts/generate-transcripts.sh content/videos --dry-run      # preview what would be processed
```

| Flag | Effect |
|------|--------|
| `--force` | Regenerate even if a transcript already exists |
| `--model NAME` | whisper.cpp model, e.g. `tiny.en`/`base.en`/`small.en`/`medium.en` (default: `base.en`) |
| `--language LANG` | Spoken language code passed to whisper (default: `en`) |
| `--dry-run` | List videos that would be processed, without transcribing |
| `--help` | Show usage |

Searches the given folder recursively for `.mp4`/`.mov`/`.m4v`/`.webm` files and
writes each transcript to `content/videos/transcripts/<video-basename>.vtt` —
flattened by basename regardless of which subfolder the video is in.

**Prerequisites (auto-installed if missing):** `ffmpeg`, `whisper-cli` (via
`brew install whisper-cpp`), and a `ggml-<model>.bin` file (auto-downloaded to
`~/.cache/whisper-models/` on first use).

Skips videos that already have a transcript (idempotent — safe to rerun after
adding new videos), and skips videos where no speech was detected rather than
writing an empty transcript.

### validate.sh — setup check

One-time verification after adding the submodule or updating it significantly.

```bash
bash ./nanoc-shared-scripts/validate.sh
```

Copies `templates/Gemfile` into the project root if no `Gemfile` exists (existing
Gemfiles are left untouched). Checks that `lib/helpers.rb` requires
`lib/shared_helpers.rb` — fails with the exact `require_relative` line to add
if it's missing or the file doesn't exist (see Ruby helpers above); this isn't
auto-fixed since it'd mean injecting a line into a file you own. Copies
`templates/screenshot-overrides.js` if missing — this JS is injected into
pages before screenshotting to freeze animations; customise per-project as
needed. Writes `.validated` to the project root on success. Creates `run.sh`,
`deploy.sh`, `check-layouts.sh`, and `generate-transcripts.sh` symlinks and
adds all five (plus `.validated`) to `.gitignore` — local machine state only,
not committed.

---

## Ruby helpers — `lib/shared_helpers.rb`

Generic nanoc helper methods shared across consumer projects, to avoid each
site re-implementing (and slowly diverging on) the same utility code.

**Using it in a project:** add this near the top of your `lib/helpers.rb`,
alongside your other `require`s:

```ruby
require_relative '../nanoc-shared-scripts/lib/shared_helpers'
```

The file is self-contained — it requires `kramdown` and `haml` itself, so it
doesn't depend on your project's `lib/helpers.rb` having required them first.
Both gems are already in `templates/Gemfile`. Path-resolving helpers
(`image_dimensions`, `video_transcript_path`) assume the process's working
directory is the project root, which holds for every nanoc command run via
`run.sh`/`deploy.sh`/`bundle exec nanoc ...`.

**What's in it:**

| Helper | Purpose |
|--------|---------|
| `make_slug(text)` | Lowercase + dashes |
| `image_dimensions(path)` | Reads pixel width/height from a PNG/JPEG/WebP file under `content/` (no gem — hand-rolled binary parsing); returns `{}` if missing/unreadable. Memoised per-process |
| `image_attrs(src, alt, eager: false, **extra)` | Builds the attribute hash for a content `%img` — merges `image_dimensions(src)`, sets `loading: 'lazy'` unless `eager: true`, always sets `decoding: 'async'` |
| `video_transcript_path(path)` | Returns `/videos/transcripts/{basename}.vtt` if that file exists under `content/`, else `nil` |
| `make_haml(haml_string, locals = {})` | Renders an inline Haml string to HTML |
| `markdown_to_html(blob)` | Converts a Kramdown Markdown string to HTML |
| `excerpt_from_markdown(markdown, max_length)` | Renders Markdown to plain text, truncates at the last word boundary within `max_length`, appends `…` only if it actually truncated |
| `date_parse(datetime)` | Parses a datetime string via `DateTime.parse` |
| `svg_icon(name)` | Inline SVG icon from the shared icon set — `linkedin`, `external_link`, `book`, `email`, `arrow_right`, `arrow_down`, `scroll_down`, `success_check` |

**If you extend this file:** top-level `def`s in Ruby land as instance methods
on `Object`, and `private`/`public` visibility toggles persist across
`require`d files in load order for the rest of the process. `jpeg_dimensions`
and `webp_dimensions` are deliberately marked `private` then immediately
followed by an explicit `public` before the next method def — keep that
bookending if you add more private helpers, or every method defined in files
loaded afterward (including the consumer's own `lib/helpers.rb`) will
silently become private too.

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
