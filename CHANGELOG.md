# Changelog

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
