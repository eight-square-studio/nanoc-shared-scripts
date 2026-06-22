# nanoc-shared-scripts — Claude Code Guide

Shell scripts and GitHub Actions reusable workflow for nanoc static sites.
Consumed by nanoc project repos via git submodule at `nanoc-shared-scripts/`.

> **Maintenance:** When scripts change behaviour, new flags are added, or the
> reusable workflow is modified, update **all three** docs:
> - `CLAUDE.md` — this file
> - `README.md` — user-facing usage examples and flag tables
> - `CHANGELOG.md` — add an entry under today's date (group with existing entries if the date already exists)

---

## Repo structure

```
shared.sh          # Sourced by other scripts — setup functions, colours, vars
deploy.sh          # S3 sync, CloudFront invalidation, release tagging
run.sh             # Watch + serve (default), one-off compile (--no-watch)
code-server.sh     # Standalone: run code-server with TLS certs (does not source shared.sh)
validate.sh        # One-time setup check; writes .validated and creates symlinks
check-layouts.sh   # Visual regression screenshot comparison (current branch vs release)
generate-transcripts.sh # Batch-generate WebVTT caption transcripts for a folder of videos (whisper.cpp)
lib/
  shared_helpers.rb          # Shared Ruby/nanoc helpers — required from a consumer's lib/helpers.rb
tools/
  screenshot-compare.rb      # Ruby script called by check-layouts.sh
templates/
  deploy.yml                 # Full workflow — copied into consumer projects by validate.sh
  Gemfile                    # Baseline Gemfile — copied into project root if missing
  screenshot-overrides.js    # JS injected before screenshots — copied into project root if missing
CLAUDE.md
README.md
```

---

## Scripts

### shared.sh
Not called directly — sourced by `deploy.sh`, `run.sh`, `check-layouts.sh`, and `validate.sh`.

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
Usage: ./run.sh [-c|--clean] [-n|--no-watch] [-o|--host HOST] [-i|--any-ip] [-p|--port PORT] [--restart-tailscale] [-h|--help]

  -c, --clean            Remove output/ before running
  -n, --no-watch         Compile once only (no watch, no serve)
  -o, --host HOST        Bind the server to HOST (default: 127.0.0.1)
  -i, --any-ip           Use 0.0.0.0 to listen on all interfaces
  -p, --port PORT        Listen on PORT (default: 3000)
  --restart-tailscale    Restart Tailscale and exit (no nanoc, no VS Code)
  -h, --help             Show this help message
```

Default (no flags): runs `nanoc compile -W` in the background and `nanoc view -L`
(watch mode + local server at http://localhost:3000).

With `--no-watch`: runs `nanoc compile` once and exits.

With `--restart-tailscale`: restarts Tailscale (`tailscale down` → `tailscale up`) and exits — no nanoc, no VS Code.

### code-server.sh
Standalone script to run `code-server` with TLS certs for remote browser access.
Does **not** source `shared.sh` — defines its own colour constants and exit trap.

Checks `~/.config/certs/` for a `.crt`/`.key` pair — exits with an error if missing.
Auto-installs `code-server` via the official install script (`curl -fsSL https://code-server.dev/install.sh | sh`)
if not found. Runs `code-server` on port `8080` from `~`, bound to `0.0.0.0`, with TLS certs
passed via `--cert`/`--cert-key`. Errors and exits if port `8080` is already in use. On exit,
traps and returns to the original working directory.

```bash
bash ./nanoc-shared-scripts/code-server.sh
```

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

### check-layouts.sh
Visual regression screenshot comparison between the current branch and `release`.
Screenshots every page, diffs them with ImageMagick, and generates an HTML report.
Flags pages where >1% of pixels changed. Opens report automatically on completion.

**Prerequisites (checked and auto-installed where possible):**
- ImageMagick (`compare`, `convert`) — auto-installed via `brew install imagemagick` if missing
- Google Chrome at `/Applications/Google Chrome.app` — must be installed manually (Ferrum uses Chrome via CDP)
- `ferrum` gem — auto-added to consumer `Gemfile` if missing, then installed via `bundle install`

**Path resolution:** Script uses `PROJECT_DIR` env var (set to `$current_dir` by the shell script) to locate `content/pages/`, `tmp/screenshots/`, and the git worktree. The Ruby script at `tools/screenshot-compare.rb` must always be invoked via `check-layouts.sh` — calling it directly without `PROJECT_DIR` set will abort with an error.

**Page discovery:** Globs `content/pages/**/*.haml` in the consumer project, reads frontmatter, skips `publish: false` pages, derives URLs using the same routing logic as nanoc `Rules`.

**Flags:**

| Flag | Short | Behaviour |
|------|-------|-----------|
| `--screenshot-only` | `-s` | Screenshot current branch only — skip release worktree, compile, ImageMagick prereq, and compare. Generates a simple HTML gallery and exits 0. |

**Screenshot pipeline (per page):**
1. Reset browser viewport to `1440×900`
2. Load page; wait for network idle
3. Execute `screenshot-overrides.js` (freeze script):
   - `window.scrollTo(0, 0)`
   - Pin all `100vh` selectors to `window.innerHeight` — prevents inflation when viewport resizes
   - Disable all animations, transitions, scroll behaviour
   - Add `is-visible` to all `[data-animate]`, `[data-animate-stagger]`, `[data-animate-chips]` parents
   - Force hero content visible (`opacity: 1 !important`)
   - Load named web fonts; decode all images; set `window.__renderReady` after `requestAnimationFrame`
4. Wait for network idle; poll for `window.__renderReady`
5. Measure `document.documentElement.scrollHeight`
6. Resize viewport to that height — forces Chrome to paint all below-fold content
7. Sleep 0.5s; take `full: false` screenshot (viewport now equals full page height)

**Why resize instead of `full: true`:** Chrome's `captureBeyondViewport` (used by `full: true`) inflates `100vh` to the document height, breaking min-height layouts. Resizing the viewport to the document height before a regular screenshot avoids this entirely.

**`screenshot-overrides.js`:** Injected before each screenshot. Consumer projects get their own copy (created by `validate.sh` from `templates/screenshot-overrides.js`) and can customise it. The default pins `.hero`, `.section`, `.error-page`, `.login-page` — add any other `100vh` selectors specific to the project.

**Output:** `{project}/tmp/screenshots/` — `release/`, `current/`, `diffs/` subdirs + `report.html`. Covered by `/tmp/` in `.gitignore`.

**Exit code:** 1 if any pages are flagged, 0 if all pass.

### generate-transcripts.sh
Batch-generates WebVTT (`.vtt`) caption transcripts for a folder of videos, using
`whisper.cpp`'s `whisper-cli`. Must be run from the project root (`nanoc.yaml`
presence check, like `deploy.sh`/`run.sh`).

```
Usage: ./generate-transcripts.sh <folder> [--force] [--model NAME] [--language LANG] [--dry-run] [-h|--help]

  --force             Regenerate even if a transcript already exists
  --model NAME        whisper.cpp model name, e.g. tiny.en/base.en/small.en/medium.en (default: base.en)
  --language LANG     Spoken language code passed to whisper (default: en)
  --dry-run           List videos that would be processed, without transcribing
  -h, --help          Show this help message
```

Searches `<folder>` **recursively** for `*.mp4 *.mov *.m4v *.webm` files. Output is
always flattened into `content/videos/transcripts/<video-basename>.vtt` regardless
of which subfolder the source video lives in — this matches consumer projects'
basename-only transcript lookup convention (e.g. `lib/helpers.rb`'s
`video_transcript_path` in `thom-portfolio`).

**Per-video pipeline:**
1. Skip if a transcript already exists for that basename (unless `--force`).
2. Extract mono 16kHz WAV via `ffmpeg` (whisper-cli only reads flac/mp3/ogg/wav, not mp4/mov directly).
3. Transcribe with `whisper-cli -sns -ovtt` (`-sns` suppresses non-speech hallucination tokens like `[Music]`).
4. Validate the output: strip any stray leading blank line before the `WEBVTT` signature (a malformed leading newline silently breaks every cue in spec-compliant parsers), and require at least one cue. If whisper detected no speech (music-only/visual-only clip), skip writing a file rather than producing an empty transcript — an empty transcript would incorrectly clear the "no audio" muted state consumer projects derive from transcript presence.
5. Move the validated `.vtt` into `content/videos/transcripts/`.

**Prerequisites (checked and auto-installed where possible):**
- `ffmpeg` — auto-installed via `brew install ffmpeg` if missing
- `whisper-cli` — auto-installed via `brew install whisper-cpp` if missing
- Model file (`ggml-<NAME>.bin`) — auto-downloaded from Hugging Face (`ggerganov/whisper.cpp`) into `~/.cache/whisper-models/` if not already cached

### lib/shared_helpers.rb
Generic nanoc helper methods (no dependency on any consumer project's content
model) shared across consumer projects via `require_relative`:

```ruby
require_relative '../nanoc-shared-scripts/lib/shared_helpers'
```

Self-contained — declares its own `require 'kramdown'` / `require 'haml'`
rather than relying on the consumer's `lib/helpers.rb` having required them
first. Path-resolving helpers (`image_dimensions`, `video_transcript_path`)
resolve against `Dir.pwd` (e.g. `File.join('content', path)`), not
`File.dirname(__FILE__)` — this only works because nanoc commands and
`run.sh`/`deploy.sh`/`validate.sh` are always run from the consumer project
root. Provides: `make_slug`, `image_dimensions`, `image_attrs`,
`video_transcript_path`, `make_haml`, `markdown_to_html`,
`excerpt_from_markdown`, `date_parse`, `svg_icon` (+ the `SVG_Icons` class).

**Visibility gotcha:** top-level `def`s become instance methods on `Object`,
and bare `private`/`public` calls toggle a process-global default that
persists across `require`d files in load order. `jpeg_dimensions` /
`webp_dimensions` are marked `private` then immediately followed by an
explicit `public` before the next method — this file must always end in the
`public` state, or every method defined in files loaded afterward (including
the consumer's own `lib/helpers.rb`) silently becomes private, breaking Haml
template calls with `NoMethodError: private method`.

### validate.sh
One-time setup verification. Run after adding the submodule to a new project,
or after a significant submodule update.

Checks:
- `nanoc.yaml` present and contains `s3_bucket`, `cloudfront_distribution_id`, `aws_region`
- `.ruby-version` present
- `Gemfile` present — copies from `templates/Gemfile` if missing (existing Gemfiles are left untouched)
- `screenshot-overrides.js` present — copies from `templates/screenshot-overrides.js` if missing (existing files left untouched); contains JS injected into each page before screenshotting to freeze animations/transitions; projects can customise their own copy
- `.github/workflows/deploy.yml` always synced from `templates/deploy.yml` (copied/updated on every run); checks it contains the string `nanoc-shared-scripts` (satisfied by the `bash ./nanoc-shared-scripts/deploy.sh` run step)
- `deploy.sh`, `run.sh`, `shared.sh`, `validate.sh`, `check-layouts.sh`, `generate-transcripts.sh` are executable
- AWS credentials reachable via `sts get-caller-identity`

On success writes `.validated` to the project root with a timestamp and the
shared scripts git SHA, creates symlinks `run.sh`, `deploy.sh`, `check-layouts.sh`,
and `generate-transcripts.sh` at the project root, and adds all five (plus
`.validated`) to `.gitignore`. All are local machine state only — recreated by
validate on each machine.

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
- `deploy.sh`, `run.sh`, `check-layouts.sh`, and `generate-transcripts.sh` resolve symlinks before sourcing `shared.sh` (they're accessed via symlinks from the project root); `validate.sh` uses the simpler `source "$(dirname "${BASH_SOURCE[0]}")/shared.sh"` since it's always run directly — `shared.sh` must always live in the same directory as the scripts that source it; `code-server.sh` is self-contained (does not source `shared.sh`)
- `check-layouts.sh` passes `PROJECT_DIR="$current_dir"` to `tools/screenshot-compare.rb` via env var — the Ruby script uses this to locate consumer project files rather than resolving paths relative to `__dir__`
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
