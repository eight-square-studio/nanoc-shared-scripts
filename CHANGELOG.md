# Changelog

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
