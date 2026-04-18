# Changelog

## 2026-04-18

- Merge `vs_code_server.sh` into `run.sh` — add `--vscode` flag (restart Tailscale + launch VS Code web server on `VSCODE_PORT=8000` in background) and `--restart-tailscale` flag (restart Tailscale and exit)
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
