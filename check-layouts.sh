#!/bin/bash
set -euo pipefail
# Visual regression screenshot comparison — catches layout changes between current branch and release.
# Run from the project root: bash check-layouts.sh (or via symlink: ./check-layouts.sh)
# Flags:
#   --screenshot-only, -s   Screenshot current branch only; skip release comparison

# Resolve symlink to find the real script directory, then source lib/_shared.sh
_s="${BASH_SOURCE[0]}"
while [[ -L "$_s" ]]; do _d="$(cd "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; [[ "$_s" != /* ]] && _s="$_d/$_s"; done
SHARED_SCRIPTS_DIR="$(cd "$(dirname "$_s")" && pwd)"
source "$SHARED_SCRIPTS_DIR/lib/_shared.sh"

function print_help() {
    echo -e "Usage: ./check-layouts.sh [-h|--help]

Runs screenshots for both the current branch and the release branch, highlighting
differences between the branches to enable quick comparison to target reviews.

Options:
  -h, --help            Show this help message
  -s, --screenshot-only Only take screenshots of the current content and do no comparison"
}

# ── Parse flags ───────────────────────────────────────────────────────────────
SCREENSHOT_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --screenshot-only|-s) SCREENSHOT_ONLY=1 ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "Unknown flag: $arg"
            print_help
            exit 1
            ;;
    esac
done

# ── Prereqs: ImageMagick ──────────────────────────────────────────────────────
if [[ "$SCREENSHOT_ONLY" -eq 0 ]] && { ! command -v compare &>/dev/null || ! command -v convert &>/dev/null; }; then
    echo -e "${WARN} ImageMagick not found — installing..."
    pkg_install imagemagick ImageMagick imagemagick imagemagick imagemagick
    if ! command -v compare &>/dev/null; then
        echo -e "${FAIL} ImageMagick install failed"
        exit 1
    fi
fi
if [[ "$SCREENSHOT_ONLY" -eq 0 ]]; then echo -e "${PASS} ImageMagick available"; fi

# ── Prereqs: Chrome/Chromium ──────────────────────────────────────────────────
function find_browser() {
    # Sets CHROME_PATH if a usable browser binary is found; returns 1 otherwise.
    # On Debian/Ubuntu, `chromium`/`chromium-browser` from apt are often just
    # Snap-transitional stub scripts (no real binary) — they exist on PATH
    # but fail without a running snapd, which isn't available in containers
    # and is commonly disabled/absent under WSL2 too. So actually run
    # `--version` rather than trusting `command -v` alone.
    if [[ "$OSTYPE" == "darwin"* ]]; then
        if [[ -d "/Applications/Google Chrome.app" ]]; then
            CHROME_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            return 0
        fi
        return 1
    fi
    local bin candidate
    for bin in google-chrome google-chrome-stable chromium-browser chromium; do
        candidate="$(command -v "$bin" 2>/dev/null)" || continue
        if "$candidate" --version &>/dev/null; then
            CHROME_PATH="$candidate"
            return 0
        fi
    done
    return 1
}

function install_google_chrome_deb() {
    # Fallback for Debian/Ubuntu when chromium/chromium-browser turned out
    # to be a non-functional Snap stub — Google's official .deb is a real
    # binary with no Snap dependency. x86_64 only — Google doesn't publish
    # an arm64 build, so this is skipped on arm64 hosts.
    [[ "$(uname -m)" == "x86_64" ]] || return 1
    echo -e "${WARN} Installed chromium package is a non-functional stub — installing Google Chrome instead..."
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | ${SUDO} gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | ${SUDO} tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
    ${SUDO} apt-get update -qq
    ${SUDO} apt-get install -y google-chrome-stable
}

function install_chromium_via_snap() {
    # Fallback for the arm64 case above (or any distro where the package
    # manager's chromium is a Snap stub) — only works if snapd is actually
    # running, which it typically is on a real Ubuntu desktop/server but
    # not in containers or WSL2.
    command -v snap &>/dev/null || return 1
    ${SUDO} snap install chromium
}

if ! find_browser; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo -e "${FAIL} Google Chrome not found at /Applications/Google Chrome.app"
        echo "Install from https://www.google.com/chrome/ then re-run."
        exit 1
    fi
    echo -e "${WARN} No working Chrome/Chromium binary found — installing Chromium..."
    pkg_install chromium chromium chromium chromium chromium || pkg_install chromium-browser chromium chromium chromium chromium
    if ! find_browser && [[ "$PKG_MANAGER" == "apt" ]] && command -v curl &>/dev/null; then
        sudo_cmd
        install_google_chrome_deb
        find_browser
    fi
    if ! find_browser; then
        sudo_cmd
        install_chromium_via_snap
        find_browser
    fi
    if [[ -z "${CHROME_PATH:-}" ]]; then
        echo -e "${FAIL} Could not find or install a working Chrome/Chromium — install Chrome or Chromium manually and re-run."
        exit 1
    fi
fi
export CHROME_PATH
echo -e "${PASS} Browser found: ${CHROME_PATH}"

# ── Ruby, bundler, gems ───────────────────────────────────────────────────────
if ! grep -q "ferrum" "$current_dir/Gemfile"; then
    echo -e "${WARN} ferrum not in Gemfile — adding..."
    cat >> "$current_dir/Gemfile" <<'GEMEOF'

group :tools do
  gem 'ferrum', '~> 0.17'
end
GEMEOF
fi

initiate

# ── Execute ───────────────────────────────────────────────────────────────────
PROJECT_DIR="$current_dir" SCREENSHOT_ONLY="$SCREENSHOT_ONLY" CHROME_PATH="$CHROME_PATH" exec bundle exec ruby "$SHARED_SCRIPTS_DIR/tools/screenshot-compare.rb"
