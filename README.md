# nanoc-shared-scripts

Shell scripts, a reusable GitHub Actions workflow, and shared Ruby/nanoc helpers
for nanoc static sites. Consumed by nanoc project repos via git submodule at
`nanoc-shared-scripts/`.

Note:
- Supports macOS (via Homebrew) and Linux (apt/dnf/pacman/zypper, auto-detected) for local setup.
- rbenv is installed automatically if missing (via Homebrew on macOS, the official installer on Linux).
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
and AWS credentials. Symlinks (`run.sh`, `deploy.sh`, `check-layouts.sh`,
`generate-transcripts.sh`) and `.gitignore` entries are always created regardless
of validation outcome, so the scripts are usable locally even before all checks
pass. Also ensures nanoc build artifacts (`output/*`, `*.log`) are gitignored.
The `.validated` timestamp file is only written when all checks pass.

---

## Scripts

### run.sh — local development

Sets up the environment and compiles the site.

```bash
./run.sh                        # watch mode + local server (default)
./run.sh --no-watch             # one-off compile, then exit
./run.sh --clean                # wipe output/ before running
./run.sh --host 0.0.0.0         # listen on all interfaces (LAN/VPN)
./run.sh --any-ip               # shortcut for --host 0.0.0.0
./run.sh --kill                 # kill existing process on port 3000
./run.sh --port 3003            # use a custom port (default 3000)
./run.sh -k -p 3003             # kill existing process on port 3003
./run.sh -o 0.0.0.0 -p 3003     # combine host + port
./run.sh --restart-tailscale    # restart Tailscale and exit
```

| Flag | Short | Effect |
|------|-------|--------|
| `--clean` | `-c` | Remove `output/` before running |
| `--no-watch` | `-n` | Compile once only, no file watching, no server |
| `--kill` | `-k` | Kill any existing process on the specified port (default: `3000`) before starting |
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

### coder.sh — remote Coder server

Standalone alternative to `code-server.sh` that runs a [Coder](https://coder.com) server
over TLS instead of `code-server`.

```bash
./nanoc-shared-scripts/coder.sh                      # run coder server on port 8080
```

Same prerequisites as `code-server.sh`: TLS certs in `~/.config/certs/` (a `.crt` and
`.key` file; exits `9` if missing), and exits `1` if port 8080 is in use. Auto-installs
`coder` via `https://coder.com/install.sh` if not found. Starts `coder server` from
`~/Development`, listening on `0.0.0.0:8080` with `CODER_REDIRECT_TO_ACCESS_URL=true`.
Not symlinked by `validate.sh` — run it by path.

### setup.sh — environment setup only

Installs/validates rbenv, the project's Ruby version and bundler dependencies, and checks
nanoc — without compiling or deploying. Run from the project root (`nanoc.yaml` must exist).
Not symlinked by `validate.sh`.

```bash
bash ./nanoc-shared-scripts/setup.sh
```

### fix-content-type.sh — fix S3 Content-Type

Rewrites the `Content-Type` of already-deployed S3 objects (e.g. extensionless files like
`.well-known/apple-app-site-association` that `aws s3 sync` guessed wrong) without
redeploying. Run from the project root; requires the `aws` CLI and credentials.
Not symlinked by `validate.sh` — run it by path.

```bash
./nanoc-shared-scripts/fix-content-type.sh --key '.well-known/apple-app-site-association' --content-type 'application/json'
./nanoc-shared-scripts/fix-content-type.sh --csv fixes.csv           # many files at once
./nanoc-shared-scripts/fix-content-type.sh --staging --key foo --content-type text/plain
```

| Flag | Purpose |
|------|---------|
| `--key KEY` | S3 object key to fix |
| `--content-type TYPE` | Content-Type to set |
| `--csv FILE` | Batch mode: lines of `key,content-type`. Header row optional; blank lines and `#` comments ignored |
| `--bucket BUCKET` | Override the bucket (default: `s3_bucket` from `nanoc.yaml`) |
| `--region REGION` | Override the region (default: `$AWS_REGION`, then `aws_region` from `nanoc.yaml`) |
| `--staging` | Read bucket/region from the `staging:` block in `nanoc.yaml` |

It copies each object onto itself with `--metadata-directive REPLACE`. CloudFront is **not**
invalidated — invalidate the path afterwards if the old type is cached.

### deploy.sh — production deploy

Full deploy pipeline. Must be run from the project root (the directory
containing `nanoc.yaml`).

```bash
./deploy.sh                     # full pipeline: compile + deploy
./deploy.sh --deploy-only       # skip compile, deploy output/ as-is
./deploy.sh --staging           # deploy to staging environment
./deploy.sh --staging --deploy-only  # staging deploy, skip compile
./deploy.sh --deploy-only --dry-run  # show what would upload/delete/invalidate, change nothing
```

| Flag | Effect |
|------|--------|
| `--deploy-only` | Skip Ruby setup and nanoc compile — deploy whatever is in `output/`. Useful for CI pipelines that populate `output/` externally (e.g. image generation). Exits with error if `output/` doesn't exist. |
| `--staging` | Deploy to staging environment. Reads `s3_bucket`, `cloudfront_distribution_id`, `aws_region` from the `staging:` block in `nanoc.yaml`. Uses `aws s3 sync --delete` (full sync) instead of hash-based uploads. Invalidates all CloudFront paths (`/*`). Skips `.deployed` hash tracking, commit, and release tagging. |
| `--dry-run` | Production only. Hashes `output/`, then prints how many files would be uploaded and deleted and the exact CloudFront paths that would be invalidated. Does not touch S3, CloudFront, `.deployed` or git. |
| `--help` | Show usage |

**Production pipeline (`./deploy.sh`):**
1. Wipes `output/` and recompiles from scratch (skipped with `--deploy-only`)
2. Checks `awscli` is installed (installs via brew on macOS, or the AWS CLI v2 installer on Linux, if missing)
3. Reads `s3_bucket`, `cloudfront_distribution_id`, `aws_region` from `nanoc.yaml`
4. Checks AWS credentials (locally falls back to `aws login`; in CI exits on failure)
5. Hashes `output/` once and diffs it against `.deployed` to find new/changed and removed files
6. Uploads the changed files in one parallel batch (`aws s3 cp --recursive`) — assets first, HTML last, so a page never goes live ahead of what it references. If the asset upload fails, HTML is skipped
7. Deletes removed files from S3 in batches of up to 1000 (`aws s3api delete-objects`)
8. Invalidates the affected paths on CloudFront in grouped requests (see below)
9. Writes `.deployed`. Files that failed to upload or delete keep their previous entry, so the next run retries them
10. If everything succeeded: commits `.deployed` as `*** Release YYYY-MM-DD ***` and creates and pushes a sequential release tag (`YYYY-MM-DD-NN`). If anything failed, nothing is committed or tagged and the script exits `1`

Requires `ruby` on the `PATH` (hashing and batching use `tools/deploy-batches.rb`, stdlib only). CI already has it; locally it's installed by the setup step.

**CloudFront invalidation grouping:** instead of one path per file, the changed/deleted keys are turned into the smallest sensible set of paths:

| Change | Invalidated |
|--------|-------------|
| `foo/index.html` | `/foo/*` and `/foo` (the page, both URL forms and everything under it) |
| `index.html` (site root) | `/` and `/index.html` |
| Any other file | its exact path, e.g. `/img/a.png` (percent-encoded) |
| `cloudfront_group_threshold` or more changed files in one directory | `/dir/*` |
| More than `cloudfront_invalidate_all_threshold` paths in total | a single `/*` |

Paths already covered by a wildcard are dropped, and requests are split at CloudFront's 3000-paths-per-request limit. A wildcard counts as one path for CloudFront billing.

**Staging pipeline (`./deploy.sh --staging`):**
1. Overlays non-deploy keys from `staging:` block (e.g. `base_url`, `indexable`) onto `nanoc.yaml` for compile
2. Wipes `output/` and recompiles from scratch (skipped with `--deploy-only`)
3. Restores `nanoc.yaml` to original
4. Checks `awscli` is installed
5. Reads deploy config from the `staging:` block in `nanoc.yaml`
6. Checks AWS credentials
7. Full sync to S3 (`aws s3 sync --delete`)
8. Invalidates all CloudFront paths (`/*`)

**nanoc.yaml deploy config:**

Two formats are supported. Top-level keys (original format) continue to work:

```yaml
# Production keys at top level (backward-compatible)
s3_bucket: "my-prod-bucket"
cloudfront_distribution_id: "EXXXPROD"
aws_region: "eu-west-2"

staging:
  s3_bucket: "my-staging-bucket"
  cloudfront_distribution_id: "EXXXSTAGING"
  aws_region: "eu-west-2"
```

Optional invalidation tuning (production, either format; whole numbers):

```yaml
cloudfront_group_threshold: 10             # changed files in one directory before it collapses to /dir/*
cloudfront_invalidate_all_threshold: 1000  # total paths before falling back to /*  (1000 = CloudFront's free monthly paths)
```

Or nest both under named blocks:

```yaml
production:
  s3_bucket: "my-prod-bucket"
  cloudfront_distribution_id: "EXXXPROD"
  aws_region: "eu-west-2"

staging:
  s3_bucket: "my-staging-bucket"
  cloudfront_distribution_id: "EXXXSTAGING"
  aws_region: "eu-west-2"
```

Production reads from `production:` block if present, falls back to top-level keys. Staging always requires a `staging:` block.

### check-layouts.sh — visual regression comparison

Compares full-page screenshots of every published page between your current branch
and the live `origin/release` (the baseline). Highlights pixel-level differences and labels each page with a status.

```bash
./check-layouts.sh                 # full compare: current vs release
./check-layouts.sh --screenshot-only   # screenshot current branch only, no compare
./check-layouts.sh -s              # same, short form
./check-layouts.sh --strict         # also exit 2 if pages changed beyond the threshold (or LAYOUT_STRICT=1)
```

**Prerequisites:**
- A Chrome/Chromium browser — on macOS must be installed at `/Applications/Google Chrome.app`; on Linux, auto-installs Chromium if no `google-chrome`/`chromium` binary is found
- ImageMagick is auto-installed (Homebrew on macOS, your distro's package manager on Linux) if missing
- `ferrum` gem is auto-added to your `Gemfile` and installed if missing

Pages are discovered automatically from `content/pages/**/*.haml` — no hardcoded list.
Output (screenshots + HTML report) goes to `tmp/screenshots/` in your project root.
Report opens automatically in your browser on completion.

**Page statuses** (console summary and `report.html`):

| Status | Meaning |
|--------|---------|
| `failed` | Could not be captured (timeout, browser error, HTTP 4xx/5xx) |
| `new` | In current but not in the baseline — nothing to compare, shown as "new, no baseline" |
| `removed` | In the baseline but not in current |
| `changed` | More than the threshold (default 1.0%) of pixels differ |
| `unchanged` | At or below the threshold |

The last line reads e.g. `Done — 0 failed, 36 new, 10 changed, 0 unchanged of 46 pages`.

**Exit codes:**

| Code | When |
|------|------|
| `0` | Run completed. `new`, `changed` and `removed` pages are informational |
| `1` | Any `failed` page, or a setup/compile/worktree error |
| `2` | Only with `--strict` (or `LAYOUT_STRICT=1`): one or more `changed`/`removed` pages not listed as expected. `new` pages never fail |

**Baseline:** the script runs `git fetch origin release` and checks `origin/release` out into a
detached worktree, so it compares against what is actually deployed — never against a local
`release` branch that may be stale. The baseline commit (short hash + subject) is logged at the
start (`Baseline: origin/release @ abc1234 …`) and shown in `report.html`. If the fetch fails
(offline, no `origin`) it falls back to the local branch of the same name and logs a warning
that the baseline may be stale (also in the report). Override the ref with `screenshot_baseline`
in `nanoc.yaml` or the `SCREENSHOT_BASELINE` env var (env wins), e.g. `origin/main`; a ref
without a remote prefix (a local branch, tag or SHA) is used as-is with no fetch.

**Config (optional, in `nanoc.yaml`):**

```yaml
screenshot_baseline: origin/release             # default
screenshot_threshold: 1.0                       # % of pixels changed before a page counts as `changed`
screenshot_expected_changes: [/, /privacy/]     # shown as `changed (expected)`; never trip --strict
```

**Very tall pages:** Chrome can't paint a viewport taller than 16384px, so pages taller than
`SCREENSHOT_MAX_HEIGHT` (default `16000` px) are captured at that height — on both the release
and current sides, so the comparison stays valid — and noted as `capped` in the log and report
(only the top part of the page is compared). If a page can't be captured at all (e.g. a
timeout), it is logged, shown as `COULD NOT CAPTURE` in the report, the remaining pages still
run, and the script exits 1 at the end.

| Env var | Default | Purpose |
|---------|---------|---------|
| `SCREENSHOT_MAX_HEIGHT` | `16000` | Max captured page height in px (keep ≤ 16384) |
| `SCREENSHOT_TIMEOUT` | `30` | Per-command browser timeout in seconds |

**Sampling generated pages:** pages written into `output/` after compile (e.g. by a
post-compile script generating `output/<source>/<slug>/index.html`) aren't nanoc items, so
they aren't discovered automatically. Opt in with a `screenshot_samples` list in `nanoc.yaml`:

```yaml
screenshot_samples:
  - path: some-dir     # directory under output/ holding <slug>/index.html pages
    count: 10          # how many to screenshot
```

For each entry, slugs present in **both** the release and current builds are sorted and `count`
evenly spaced ones are chosen (deterministic — no randomness), so both sides capture identical
pages. Slugs that exist in only one build are skipped and the number is logged. Without the key,
behaviour is unchanged.

**No baseline for a sample directory:** if the two builds share no slugs under a `path` (e.g.
`release` has no generated pages yet), nothing is dropped — each build's own evenly spaced picks
are screenshotted and reported as `new` (current only) or `removed` (release only). The log says
how many were sampled and why.

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
./generate-transcripts.sh content/videos                # recursively transcribe everything missing a transcript
./generate-transcripts.sh content/videos/hsbc           # just one subfolder
./generate-transcripts.sh content/videos --force        # regenerate existing transcripts too
./generate-transcripts.sh content/videos --model small.en  # bigger/slower model for better accuracy
./generate-transcripts.sh content/videos --dry-run      # preview what would be processed
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
`brew install whisper-cpp` on macOS; on Linux, tries your package manager
first and falls back to building from source if not packaged), and a
`ggml-<model>.bin` file (auto-downloaded to
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
needed.

When `.github/workflows/deploy.yml` differs from the template, `validate.sh`
shows a unified diff and asks before overwriting. Declining records the diff
hash in `.validated` — subsequent runs with the same diff pass silently. The
record is cleared automatically when you accept an update or the files come
back into sync.

Writes `.validated` to the project root on success. Creates `run.sh`,
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
- `push` to the `release` branch — production deploy
- `push` to the `staging` branch — staging deploy (passes `--staging` to `deploy.sh`)
- `workflow_call` — can be invoked from another workflow in your project if needed

**What it does:** checkout (full history + recursive submodules) → Ruby setup →
`bundle install` → nanoc version check → git identity → AWS credentials → `bash ./nanoc-shared-scripts/deploy.sh` (with `CI=true`; `--staging` flag added automatically on the `staging` branch) →
merge `release` back into `main` (production only — skipped for staging)

### Secrets required

Set these in GitHub repo Settings → Secrets and variables → Actions:

| Secret | Value |
|--------|-------|
| `AWS_ACCESS_KEY_ID` | IAM access key with S3 + CloudFront permissions |
| `AWS_SECRET_ACCESS_KEY` | Corresponding secret key |
| `AWS_REGION` | e.g. `eu-west-1` |

### Actions permissions

The repo also needs **read + write** permissions for Actions (Settings → Actions → General).
