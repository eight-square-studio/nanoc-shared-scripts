# nanoc-shared-scripts — Claude Code Guide

Shell scripts and GitHub Actions reusable workflow for nanoc static sites.
Consumed by nanoc project repos via git submodule at `nanoc-shared-scripts/`.

> **Maintenance:** When scripts change behaviour, new flags are added, or the
> reusable workflow is modified, update the relevant docs:
> - `README.md` — user-facing usage examples, flag tables, pipeline steps, config formats
> - `CHANGELOG.md` — add an entry under today's date (group with existing entries if the date already exists)
> - `CLAUDE.md` — only if implementation internals, gotchas, or conventions change (not for user-facing behaviour already covered by README)

**Development environment:** local work is done on macOS; CI deploys run on
Linux (`ubuntu-latest`). All scripts must work on both — macOS uses Homebrew,
Linux uses the distro package manager (apt/dnf/pacman/zypper) via `pkg_install()`.
CI skips all local setup (`$CI` short-circuits `initiate()`).

See `README.md` for usage examples, flag tables, pipeline steps, nanoc.yaml
config formats, GitHub Actions setup, secrets, and consumer project setup/update
instructions. This file covers implementation details and gotchas relevant when
editing the scripts.

---

## Repo structure

```
deploy.sh          # S3 sync, CloudFront invalidation, release tagging
run.sh             # Watch + serve (default), one-off compile (--no-watch)
code-server.sh     # Standalone: run code-server with TLS certs (does not source lib/_shared.sh)
validate.sh        # One-time setup check; writes .validated and creates symlinks
check-layouts.sh   # Visual regression screenshot comparison (current branch vs release)
generate-transcripts.sh # Batch-generate WebVTT caption transcripts for a folder of videos (whisper.cpp)
lib/
  _shared.sh                 # Sourced by other scripts — setup functions, colours, vars
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

## Implementation details

### lib/_shared.sh
Not called directly — sourced by `deploy.sh`, `run.sh`, `check-layouts.sh`, and `validate.sh`.

Sets `current_dir` to `$PWD` (the calling script's working directory — i.e. the project root).
All scripts must be run from the project root; `deploy.sh` and `run.sh` enforce this with a
`nanoc.yaml` presence check.

| Function | Purpose |
|----------|---------|
| `sha256_file()` | Cross-platform SHA256: `sha256sum` (Linux) or `shasum -a 256` (macOS) |
| `get_ruby_version()` | Reads `.ruby-version` from CWD or defaults to `3.4.7` |
| `sudo_cmd()` | Sets `SUDO` to `sudo` if needed and available, or `""` when already root (containers) or `sudo` isn't installed |
| `detect_pkg_manager()` | Sets `PKG_MANAGER` to `brew` (macOS), `apt`, `dnf`, `pacman`, `zypper`, or `unknown` |
| `pkg_install(...)` | Cross-distro install dispatcher — takes one package name per manager (apt/dnf/pacman/zypper/brew) and runs the right install command |
| `port_in_use()` | Checks if a TCP port is listening — `lsof`, falling back to `ss`, falling back to a raw `/dev/tcp` probe |
| `check_for_build_deps()` | Linux-only; installs native libs `ruby-build` needs to compile Ruby from source (no-op on macOS) |
| `check_os_type()` | macOS: validates Homebrew, prompts to install if missing. Linux: detects the package manager via `detect_pkg_manager()` |
| `check_for_rbenv()` | Validates rbenv; offers to install via brew (macOS) or the official installer script (Linux) |
| `validate_and_install_ruby()` | Ensures correct Ruby version via rbenv, installing build deps first on Linux |
| `set_up_bundler()` | Runs `bundle install` |
| `check_for_nanoc()` | Validates nanoc is available |
| `initiate()` | Runs all of the above in sequence; skipped entirely if `$CI` is set |

### deploy.sh internals

**Config parsing:** `read_deploy_config()` uses `awk` to extract indented lines
under `production:` or `staging:` blocks. For production, tries the `production:`
block first, falls back to top-level keys. For staging, requires a `staging:` block.

**Staging nanoc config overlay:** `apply_staging_nanoc_config()` extracts
non-deploy keys (anything except `s3_bucket`, `cloudfront_distribution_id`,
`aws_region`) from the `staging:` block and temporarily overwrites them at the
top level of `nanoc.yaml` before `nanoc compile`. A `.pre-staging` backup is
taken; `restore_nanoc_config()` restores it after compile (also on compile failure).

### check-layouts.sh internals

**Path resolution:** Script uses `PROJECT_DIR` and `CHROME_PATH` env vars (set by the shell script) to locate `content/pages/`, `tmp/screenshots/`, the git worktree, and the browser binary. The Ruby script at `tools/screenshot-compare.rb` must always be invoked via `check-layouts.sh` — calling it directly without `PROJECT_DIR` set will abort with an error.

**Page discovery:** Globs `content/pages/**/*.haml` in the consumer project, reads frontmatter, skips `publish: false` pages, derives URLs using the same routing logic as nanoc `Rules`.

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

**Linux Chrome detection:** `find_browser()` checks `google-chrome`, `google-chrome-stable`, `chromium-browser`, `chromium` in turn, validating each candidate actually runs (`--version`) rather than trusting `command -v` alone — on Debian/Ubuntu, `chromium`/`chromium-browser` from apt are Snap-transitional stub scripts that exist on `PATH` but don't work without a running snapd. Falls back to installing Chromium via `pkg_install`, then Google Chrome from its official apt repo, then `snap install chromium`. Adds `--no-sandbox`/`--disable-dev-shm-usage` automatically when running as root (containers/CI).

### generate-transcripts.sh internals

**Per-video pipeline:**
1. Skip if a transcript already exists for that basename (unless `--force`).
2. Probe for an audio stream with `ffprobe`. Silent screen recordings with no audio track are skipped immediately — without this check, `ffmpeg` errors trying to extract a non-existent audio stream.
3. Extract mono 16kHz WAV via `ffmpeg` (whisper-cli only reads flac/mp3/ogg/wav, not mp4/mov directly).
4. Transcribe with `whisper-cli -sns -ovtt` (`-sns` suppresses non-speech hallucination tokens like `[Music]`).
5. Validate output: strip any stray leading blank line before `WEBVTT` signature (breaks spec-compliant parsers), and require at least one cue. No-speech clips skip writing a file rather than producing an empty transcript.
6. Move the validated `.vtt` into `content/videos/transcripts/`.

**Linux whisper-cli:** Not in default repos for most distros. Tries `pkg_install whisper-cpp` first, falls back to shallow-cloning `ggerganov/whisper.cpp` and building from source.

### lib/shared_helpers.rb internals

Self-contained — declares its own `require 'kramdown'` / `require 'haml'`.
Path-resolving helpers (`image_dimensions`, `video_transcript_path`) resolve
against `Dir.pwd`, not `File.dirname(__FILE__)` — only works because scripts
are always run from the consumer project root.

**Visibility gotcha:** top-level `def`s become instance methods on `Object`,
and bare `private`/`public` calls toggle a process-global default that
persists across `require`d files in load order. `jpeg_dimensions` /
`webp_dimensions` are marked `private` then immediately followed by an
explicit `public` before the next method — this file must always end in the
`public` state, or every method defined in files loaded afterward (including
the consumer's own `lib/helpers.rb`) silently becomes private, breaking Haml
template calls with `NoMethodError: private method`.

---

## Conventions

- All scripts use `#!/bin/bash` and support both macOS (via `brew`) and Linux (via `pkg_install`'s apt/dnf/pacman/zypper dispatch) for local setup checks; CI always skips local setup (`$CI` short-circuits `initiate()`)
- `current_dir` is set to `$PWD` in `lib/_shared.sh` — scripts must always be run from the project root
- Hash commands handle both platforms via `sha256_file()`: `sha256sum` (Linux) and `shasum -a 256` (macOS)
- `deploy.sh`, `run.sh`, `check-layouts.sh`, and `generate-transcripts.sh` resolve symlinks before sourcing `lib/_shared.sh` (they're accessed via symlinks from the project root); `validate.sh` uses the simpler `source "$(dirname "${BASH_SOURCE[0]}")/lib/_shared.sh"` since it's always run directly; `code-server.sh` is self-contained (does not source `lib/_shared.sh`)
- `check-layouts.sh` passes `PROJECT_DIR="$current_dir"` to `tools/screenshot-compare.rb` via env var
- Colour/formatting constants (`PASS`, `FAIL`, etc.) are defined in `lib/_shared.sh`
