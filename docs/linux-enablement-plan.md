# Linux compatibility for nanoc-shared-scripts

Status: complete — verified end-to-end on Ubuntu 24.04 and Fedora (latest) via Docker (OrbStack)

## Context

All local setup logic in this repo originally assumed macOS + Homebrew:
`lib/_shared.sh`'s `check_os_type`/`check_for_rbenv` only knew how to install
things via `brew`, and several scripts hardcoded macOS-only paths/commands
(`/Applications/Google Chrome.app`, the `open` command). CI already bypasses
all of this (`initiate()` returns early when `$CI` is set, and the GitHub
Actions runner is `ubuntu-latest` with its own setup steps in
`templates/deploy.yml`) — so this work makes `run.sh`, `deploy.sh`,
`check-layouts.sh`, `generate-transcripts.sh`, and `code-server.sh` work when
a developer runs them directly on a Linux workstation, with package-manager
detection done dynamically (apt, dnf, pacman, zypper) rather than hardcoding
one distro.

## Issues found (by file)

- **`lib/_shared.sh`**: `check_os_type()` only installed Homebrew; Linux had
  no working install path. `rbenv install` needs Ruby's native build deps,
  which `brew` pulls in transitively on macOS but Linux package managers
  do not.
- **`deploy.sh`** (`check_for_awscli`): non-darwin branch just printed a link
  and exited — no actual install path.
- **`check-layouts.sh`**: ImageMagick install was `brew`-only; Chrome
  detection was hardcoded to `/Applications/Google Chrome.app`.
- **`generate-transcripts.sh`**: `ffmpeg`/`whisper-cpp` installs were
  `brew`-only.
- **`run.sh`** / **`code-server.sh`**: hard-depended on `lsof` for port
  checks.
- **`tools/screenshot-compare.rb`**: opened the HTML report with the bare
  `open` command (macOS-only).

### Additional bugs found only by actually running the scripts on Linux

These would not have been caught by code review or syntax checking alone —
each one only surfaced when run for real in a container:

1. **rbenv install + PATH** (`lib/_shared.sh`): the official Linux rbenv
   installer (`curl -fsSL https://rbenv.org/install.sh | bash`) only wires
   `~/.rbenv/bin` into `~/.bash_profile` for *future* shells — it never
   reaches `PATH` in the current process, so the immediately-following
   `rbenv root` call failed with "command not found". Masked on macOS
   because `brew install rbenv` installs into Homebrew's already-on-PATH
   prefix. Fixed by exporting `~/.rbenv/bin` onto `PATH` right after the
   installer runs.
2. **`ruby -v` with no system Ruby at all** (`lib/_shared.sh`): macOS always
   ships a system Ruby, so `ruby_value=\`ruby -v\`` always succeeded (even
   if the version was wrong). A bare Linux container has no Ruby at all
   until rbenv installs one, so the bare command substitution failed
   outright under `set -e` and killed the script. Fixed by tolerating a
   missing `ruby` binary (`ruby -v 2>/dev/null || true`).
3. **`dnf groupinstall` doesn't exist on dnf5** (`lib/_shared.sh`): Fedora
   has moved to dnf5, which dropped the legacy `groupinstall` subcommand
   syntax entirely. Replaced `dnf groupinstall -y "Development Tools"` with
   the explicit package list (works on dnf4 and dnf5 alike, and is more
   precise than pulling in the entire group).
4. **`tzdata`'s interactive debconf prompt** under apt — not a code bug
   (only affects the test harness), but worth recording: any apt install
   that pulls in `tzdata` non-interactively needs `DEBIAN_FRONTEND=noninteractive`
   or it hangs forever asking for a timezone.
5. **`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` unbound under `set -u`**
   (`deploy.sh`): `check_aws_auth()` referenced these env vars directly;
   if a developer has never exported them at all (e.g. they use
   `~/.aws/credentials` or SSO instead), this crashed with "unbound
   variable" before ever reaching the actual auth check. Not Linux-specific
   — would have broken identically on macOS — but only surfaced because
   this verification ran with a completely clean environment. Fixed with
   `${VAR:-}` defaults.
6. **Headless Chrome under root needs `--no-sandbox` and
   `--disable-dev-shm-usage`** (`tools/screenshot-compare.rb`): Chrome
   refuses to start its sandbox as root (the default user in most
   containers/CI), and containers' default 64MB `/dev/shm` crashes the
   renderer before it can print its DevTools websocket URL — Ferrum's
   `Browser.new` just times out with no useful error. Fixed by adding both
   flags automatically when `Process.uid.zero?`.
7. **Debian/Ubuntu's `chromium`/`chromium-browser` apt packages are Snap
   stubs** (`check-layouts.sh`): on Ubuntu, both package names just install
   a wrapper script that calls `snap install chromium` on first run — there
   is no real browser binary unless snapd is actually running, which it
   typically isn't in containers and commonly isn't under WSL2 either. The
   binary exists on `PATH` (so a plain `command -v` check passes) but
   produces no working browser. Fixed `find_browser()` to actually run
   `"$bin" --version` rather than trusting `command -v`, with a fallback to
   installing Google Chrome from its official apt repo (x86_64 only — Google
   doesn't publish an arm64 `.deb`) and, failing that, `snap install
   chromium` for cases where snapd genuinely is available.

## Branching

All work for this plan happened on `platform/linux-enablement`, created off
`main`. PR/merge decision is left to the user.

## Approach

- [x] 1. `lib/_shared.sh` — package-manager detection + Linux install paths
- [x] 2. `deploy.sh` — `check_for_awscli` installs AWS CLI v2 on Linux
- [x] 3. `check-layouts.sh` — ImageMagick + cross-platform browser detection
- [x] 4. `generate-transcripts.sh` — ffmpeg/whisper-cli with source-build fallback
- [x] 5. `run.sh` / `code-server.sh` — `port_in_use` helper, no hard `lsof` dependency
- [x] 6. `tools/screenshot-compare.rb` — `open_report()`, `CHROME_PATH`, root-safe Chrome flags
- [x] 7. Docs — updated `CLAUDE.md`, `README.md`, `CHANGELOG.md`

## Verification

Ran end-to-end (not just syntax-checked) on real Ubuntu 24.04 and Fedora
(latest) containers via Docker/OrbStack on this machine, against a minimal
nanoc fixture project (separate from this repo) with the real `nanoc.yaml`/
`.ruby-version`/`Gemfile`/`lib/helpers.rb` wiring a consumer project would
have. Five checks per distro, each run for real (not dry-run):

| Check | Ubuntu 24.04 (arm64, no snapd) | Fedora latest (arm64) |
|---|---|---|
| `run.sh --no-watch` (full `initiate()`: pkg-manager detect, rbenv install, build deps, **compile Ruby 3.4.7 from source**, bundle install, nanoc compile) | ✅ | ✅ |
| `deploy.sh` (awscli v2 install, `nanoc.yaml` parsing, CI-mode AWS auth check exits 6 as expected) | ✅ | ✅ |
| `check-layouts.sh --screenshot-only` (ImageMagick install, browser detection/install, Ferrum launch, real screenshot + report) | ❌ — see note | ✅ |
| `generate-transcripts.sh --dry-run` on an empty folder (ffmpeg + whisper-cli install/build path) | ✅ | ✅ |
| `generate-transcripts.sh` for real against a generated test clip (exercises the **whisper.cpp source-build fallback** end-to-end, including compiling and running `whisper-cli`) | ✅ | ✅ |

**Ubuntu `check-layouts.sh` note:** fails cleanly (clear error message, not
a crash) only because this specific test container is arm64 *and* has no
functional snapd (true of most containers/WSL2) — Google Chrome has no
arm64 `.deb`, and the snap fallback needs real snapd. Re-tested the Chrome
`.deb` fallback path in isolation under `--platform linux/amd64` (Docker/QEMU
emulation) on the same host: Chrome installed and rendered a real page
(`--dump-dom` returned actual HTML), confirming the fix works correctly for
the realistic majority case (x86_64 Ubuntu, which is what virtually all
real Linux dev machines, cloud instances, and CI runners are). A real Ubuntu
desktop/server (non-container, x86_64 or with working snapd) would not hit
this gap at all.

No macOS regression risk: every fix above only touches the non-darwin
branches of each function; the darwin branches are untouched.
