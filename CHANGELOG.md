# Changelog

## 2026-07-25

- `deploy.sh` gains `--deploy-only` flag — skips Ruby setup and nanoc compile, deploys `output/` as-is. Enables CI pipelines that populate `output/` externally (e.g. image generation) to reuse the existing hash-based S3 sync, CloudFront invalidation, and `.deployed` tracking
- `validate.sh` now bootstraps nanoc projects from scratch — runs `nanoc create-site` for `content/` and `layouts/` scaffolding when core files are missing, overlays project templates for `nanoc.yaml` (deployment keys) and `Rules` (haml/scss/pages routing), creates `.ruby-version` and `lib/helpers.rb` if absent. Falls back to templates if nanoc gem unavailable. Never overwrites existing files
- Add `setup.sh` — standalone environment setup (rbenv, Ruby, bundler) without compile or deploy
- New templates: `nanoc.yaml`, `Rules`, `default.haml`, `index.haml`

## 2026-06-27

- `generate-transcripts.sh` no longer treats silent videos (no audio stream at all) as a failure — probes with `ffprobe` first and skips them the same way as a "no speech detected" clip, instead of letting `ffmpeg` error out trying to extract a non-existent audio stream
- Move `shared.sh` to `lib/_shared.sh` and update all `source` references in `deploy.sh`, `run.sh`, `check-layouts.sh`, `validate.sh`, and `generate-transcripts.sh`
- Add Linux support across all local setup paths: `lib/_shared.sh` gains `detect_pkg_manager()`/`pkg_install()` (apt/dnf/pacman/zypper, alongside brew), `port_in_use()`, and `check_for_build_deps()`; `check_os_type()`/`check_for_rbenv()`/`validate_and_install_ruby()` use them on Linux instead of erroring out
- `deploy.sh` installs AWS CLI v2 on Linux via the official zip installer instead of just printing a manual-install message
- `check-layouts.sh` installs ImageMagick via the detected package manager and auto-detects/installs a Chrome/Chromium binary on Linux (was hardcoded to `/Applications/Google Chrome.app`); the discovered binary path is passed to Ferrum via `CHROME_PATH`
- `generate-transcripts.sh` installs `ffmpeg`/`whisper-cli` via the detected package manager on Linux, falling back to building `whisper.cpp` from source when it isn't packaged
- `run.sh` and `code-server.sh` no longer hard-depend on `lsof` for port checks — fall back to `ss`, then a raw `/dev/tcp` probe
- `tools/screenshot-compare.rb` opens the HTML report with `xdg-open` on Linux (was `open`-only) and respects `CHROME_PATH` when launching Ferrum
- Fix bugs found by actually running the Linux setup paths end-to-end in Docker (Ubuntu 24.04 and Fedora): the official rbenv installer's `~/.rbenv/bin` wasn't being added to `PATH` for the current process; `ruby -v` crashed the whole script under `set -e` on a box with no system Ruby at all; `dnf groupinstall "Development Tools"` doesn't exist on dnf5 (replaced with explicit packages); `check_aws_auth` referenced `$AWS_ACCESS_KEY_ID`/`$AWS_SECRET_ACCESS_KEY` unguarded under `set -u`; headless Chrome needs `--no-sandbox`/`--disable-dev-shm-usage` when running as root (containers/CI); Debian/Ubuntu's `chromium`/`chromium-browser` apt packages are non-functional Snap stubs without a running snapd, so `find_browser()` now validates the binary actually runs and falls back to installing Google Chrome (or `snap install chromium`) when it doesn't

## 2026-06-23

- Add `validate.sh` check — flags (does not auto-fix) when a consumer project's `lib/helpers.rb` is missing the `require_relative '../nanoc-shared-scripts/lib/shared_helpers'` line, with the exact line to add

## 2026-06-22

- Add `lib/shared_helpers.rb` — generic Ruby/nanoc helpers (`make_slug`, `image_dimensions`, `image_attrs`, `video_transcript_path`, `make_haml`, `markdown_to_html`, `excerpt_from_markdown`, `date_parse`, `svg_icon`) shared across consumer projects via `require_relative`; consolidates code that had already drifted into duplicate copies in `eightsquarestudio.com` and `thom-portfolio`

## 2026-06-21

- Add `generate-transcripts.sh` — batch-generates WebVTT caption transcripts for a folder of videos via `whisper.cpp` (local, no API key); recursively finds videos, skips ones that already have a transcript, validates/sanitises the `WEBVTT` signature, and skips writing a transcript when no speech is detected
- Wire `generate-transcripts.sh` into `validate.sh` (executable check, `.gitignore` entry, symlink creation)

## 2026-06-20

- Extract VS Code / code-server functionality from `run.sh` into standalone `code-server.sh` — self-contained script (own colour constants, does not source `shared.sh`); removes `--vscode` and `--vport` flags from `run.sh`
- Add `-i` / `--any-ip` flag to `run.sh` — shortcut for `--host 0.0.0.0` to listen on all interfaces

## 2026-06-17

- Add `-h` / `--help` flag to `check-layouts.sh` and `deploy.sh`

## 2026-06-13

- Make `templates/screenshot-overrides.js` font loading agnostic — no longer hardcodes specific font family names

## 2026-05-18

- Switch VS Code integration in `run.sh` from `code serve-web` to `code-server`; default port changed from `8000` to `8080`; auto-installs `code-server` via official install script if not found

## 2026-05-11

- Add `--screenshot-only` / `-s` flag to `check-layouts.sh` — screenshots current branch only, skips release worktree setup, ImageMagick prereq, and comparison; generates a simple HTML gallery report and exits 0

## 2026-04-23

- Update `validate.sh` — copy `templates/Gemfile` into project root if no `Gemfile` exists (existing Gemfiles left untouched)
- Extract screenshot freeze/override JS from `screenshot-compare.rb` into `templates/screenshot-overrides.js`; `validate.sh` copies it to project root if missing; each project can customise their own; injection skipped if file absent
- Fix headless Chrome screenshot rendering in `tools/screenshot-compare.rb` and `templates/screenshot-overrides.js`:
  - Fix `100vh` inflation: `full: true` / `captureBeyondViewport` inflates all `100vh` elements to document height — replaced with reset viewport → freeze → measure `scrollHeight` → resize viewport to `scrollHeight` → `full: false` screenshot; forces Chrome to paint all content without viewport side-effects
  - Pin all `100vh` selectors (`.hero`, `.section`, `.error-page`, `.login-page`) to actual `window.innerHeight` before resize so they don't re-inflate
  - Fix below-fold content not painting — viewport resize to full document height causes Chrome to treat all content as in-viewport and paint it
  - Fix `[data-animate-stagger]` / `[data-animate-chips]` visibility — `is-visible` now added to parent containers (CSS selector is `[data-animate-stagger].is-visible > *`), not children
  - Fix hero content fading during screenshot — add `.hero__content { opacity: 1 !important }` to freeze CSS so JS scroll handler can't override it
  - Fix web font rendering — load actual font families by name in freeze script; wait for `requestAnimationFrame` after fonts and images are ready before flagging `__renderReady`
  - Add `img.decode()` for all images to ensure images are painted before screenshot
  - Reset browser viewport to `1440×900` at the start of each page to ensure consistent `window.innerHeight` across pages

## 2026-04-22

- Add `check-layouts.sh` — visual regression screenshot comparison between current branch and `release`; screenshots all published pages via Ferrum (Chrome CDP), diffs with ImageMagick, generates HTML report, exits 1 if any page >1% changed
- Add `tools/screenshot-compare.rb` — Ruby script called by `check-layouts.sh`; discovers pages from `content/pages/**/*.haml`, respects `publish: false`, derives URLs from nanoc routing rules; uses `PROJECT_DIR` env var for all consumer project paths
- Update `validate.sh` — add `check-layouts.sh` to executable check, gitignore entries, and symlink creation

## 2026-04-20

- Updated script to skip configuring nanoc + ruby context if it is restarting tailscale or running vscode in `run.sh` 

## 2026-04-19

- Skip `ruby-build` git pull when not installed as rbenv plugin — guard with directory check so Homebrew-installed ruby-build doesn't error
- Fix unbound variable error for `$CI` under `set -u` — use `${CI:-}` in `deploy.sh` and `shared.sh`
- Fix `templates/deploy.yml` merge step — explicitly checkout `.deployed` from release after merging into main so latest deploy hashes always win
- Add `set -euo pipefail` to `deploy.sh` and `run.sh`; `set -uo pipefail` to `validate.sh` (survey script intentionally continues past individual check failures)
- Fix `validate_and_install_ruby()` — run `cd ~/.rbenv/plugins/ruby-build && git pull` in subshell to prevent working directory corruption on failure
- Silence exit trap on successful exit — only print `exiting` message on non-zero exit status
- Extract `restart_tailscale()` function in `run.sh` — eliminates duplicated Tailscale restart block between `--restart-tailscale` and `--vscode` paths
- Remove `set -a` / `set +a` from `shared.sh` — variables need no export since `shared.sh` is sourced, not executed
- Fix temp file leak in `get_changed_files()` — use `trap ... RETURN` so files are cleaned up even if the function exits early due to an error

## 2026-04-18

- Fix `validate_and_install_ruby()` — use `rbenv install --skip-existing` to suppress reinstall prompt when Ruby version already installed
- Merge `vs_code_server.sh` into `run.sh` — add `--vscode` flag (restart Tailscale + run VS Code web server on `VSCODE_PORT=8000` in foreground, mutually exclusive with nanoc) and `--restart-tailscale` flag (restart Tailscale and exit)
- Delete `vs_code_server.sh`

## 2026-04-17

- Add `vs_code_server.sh` — restarts Tailscale and launches VS Code web server for remote browser access

## 2026-04-03

- Add `--host` and `--port` flags to `run.sh` for binding to custom addresses
- Auto-increment port when the chosen port is already in use

## 2026-03-30

- Fix validate script bug - github action deploy.yml is now updated if different in parent repo

## 2026-03-28

- Add update script
- Update README and documentation
- Update deploy.yml action versions
- Update template to be standalone
- Move permissions to workflow level in deploy.yml template
- Update org references to eight-square-studio
- Create LICENSE
- Fix stale docs — symlinks are gitignored, update submodule paths
- Fix `generate_file_hashes` — use while loop instead of `find -exec` for `sha256_file`
- Fix gitignore append — use `printf` to ensure newline before each entry
- Gitignore symlinks `run.sh` and `deploy.sh` automatically
- Create `.github/workflows/deploy.yml` if missing in `validate.sh`
- Flatten structure — move scripts to repo root, update all paths to `nanoc-shared-scripts/`
- Auto-add `.validated` to `.gitignore` in `validate.sh`
- Resolve symlinks when sourcing `shared.sh`
- Make scripts executable; add executable check to `validate.sh`
- Fix `validate.sh` workflow check — consumer uses `uses:` not `workflow_call`
- Initial commit — shared scripts and reusable workflow
