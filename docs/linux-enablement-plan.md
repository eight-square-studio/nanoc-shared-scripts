# Linux compatibility for nanoc-shared-scripts

Status: implementation complete, live Linux verification pending (no Linux host available in this environment — see Verification)

## Context

All local setup logic in this repo currently assumes macOS + Homebrew:
`lib/_shared.sh`'s `check_os_type`/`check_for_rbenv` only know how to install
things via `brew`, and several scripts hardcode macOS-only paths/commands
(`/Applications/Google Chrome.app`, the `open` command). CI already bypasses
all of this (`initiate()` returns early when `$CI` is set, and the GitHub
Actions runner is `ubuntu-latest` with its own setup steps in
`templates/deploy.yml`) — so this plan is about making `run.sh`,
`deploy.sh`, `check-layouts.sh`, `generate-transcripts.sh`, and
`code-server.sh` work when a developer runs them directly on a Linux
workstation, with package-manager detection done dynamically (apt, dnf,
pacman, zypper) rather than hardcoding one distro.

## Issues found (by file)

- **`lib/_shared.sh`**: `check_os_type()` only installs Homebrew and exits
  the "happy path" only for `darwin*`; Linux just gets a warning and the
  rest of the setup chain (`check_for_rbenv`, `validate_and_install_ruby`)
  has no working non-mac install path beyond a manual-install message.
  `rbenv install` needs Ruby's native build dependencies, which `brew`
  pulls in transitively on macOS but Linux package managers do not.
- **`deploy.sh`** (`check_for_awscli`): non-darwin branch just prints a link
  and exits — no actual install path.
- **`check-layouts.sh`**: ImageMagick install is `brew install imagemagick`
  only; Chrome detection is hardcoded to `/Applications/Google Chrome.app`,
  which doesn't exist on Linux even when Chromium/Chrome is installed.
- **`generate-transcripts.sh`**: `ffmpeg` and `whisper-cpp` installs are
  `brew install` only. `whisper-cpp` isn't in default apt/dnf/pacman repos,
  so it needs a source-build fallback on Linux.
- **`run.sh`** / **`code-server.sh`**: both poll for port availability with
  `lsof -i :PORT -sTCP:LISTEN`. `lsof` isn't always present on minimal Linux
  installs (it's a manual apt-get away) — needs a fallback.
- **`tools/screenshot-compare.rb`**: opens the HTML report with the bare
  `open` command (macOS-only) in two places. Needs an `xdg-open` path for
  Linux.
- Things checked and found **already fine**, no change needed: `sha256_file()`
  (already branches on `sha256sum`/`shasum`), `date +%Y-%m-%d`/`date +%s`
  usage in `deploy.sh` (same on GNU/BSD date), no `sed -i`/BSD-only flags
  anywhere, `tailscale` handling in `run.sh` already no-ops gracefully if
  the binary is absent, `code-server` install script is already
  cross-platform.

## Branching

All work for this plan happens on `platform/linux-enablement`, created off
`main`. PR/merge decision is left to the user once the branch is ready for
review.

## Tracking

As each numbered section under Approach is completed, check it off below.
Once every section is done and verified, rename this file to
`docs/linux-enablement-plan-complete.md` and update the Status line.

## Approach

- [x] 1. `lib/_shared.sh` — package-manager detection + Linux install paths
  - Added `detect_pkg_manager()`, `pkg_install(...)`, `port_in_use(...)`,
    `check_for_build_deps()`.
  - Rewrote `check_os_type()`, `check_for_rbenv()`, and
    `validate_and_install_ruby()` to use them on Linux.
- [x] 2. `deploy.sh` — `check_for_awscli` installs AWS CLI v2 on Linux via
  the official zip installer instead of printing a manual-install message.
- [x] 3. `check-layouts.sh` — ImageMagick via `pkg_install`; cross-platform
  browser detection (`find_browser()`), auto-install Chromium on Linux,
  export `CHROME_PATH` for Ferrum.
- [x] 4. `generate-transcripts.sh` — ffmpeg via `pkg_install`; whisper-cli
  via `pkg_install` with a source-build fallback for Linux.
- [x] 5. `run.sh` / `code-server.sh` — replaced direct `lsof` calls with a
  `port_in_use` helper that falls back to `ss` / `/dev/tcp`.
- [x] 6. `tools/screenshot-compare.rb` — `open_report()` helper using
  `xdg-open` on Linux, `open` on macOS; also accepts `CHROME_PATH` env var
  for `Ferrum::Browser.new` (via a `new_browser` helper).
- [x] 7. Docs — updated `CLAUDE.md`, `README.md`, `CHANGELOG.md`.

## Verification

1. [x] `bash -n` every changed shell script + `ruby -c` on
   `tools/screenshot-compare.rb` — all pass.
2. [ ] Exercise the install paths on a Linux container/VM (apt- and
   dnf-based) — `validate.sh` and `run.sh --no-watch` against a minimal
   nanoc project fixture. **Not run** — this development environment is
   macOS-only with no Docker/Linux VM access. Needs to be done by whoever
   picks this branch up on (or with access to) a Linux host before merging.
3. [ ] Manually trigger `check-layouts.sh` on a Linux host to confirm
   Chromium auto-installs and Ferrum launches with `CHROME_PATH` set. **Not
   run**, same reason as above.
4. [ ] Run `generate-transcripts.sh` for real on a Linux host against one
   short test clip to exercise the whisper.cpp source-build fallback. **Not
   run**, same reason as above.
5. [x] Re-ran the existing macOS flows' syntax checks on this machine — the
   darwin branches in every changed file are untouched logic-wise (only
   the non-darwin branches changed), confirmed by diff review.

This file stays as `linux-enablement-plan.md` (not renamed to
`-complete.md`) until items 2-4 above are actually exercised on a Linux
host.
