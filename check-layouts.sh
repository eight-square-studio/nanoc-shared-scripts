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
    echo -e "${WARN} ImageMagick not found — installing via Homebrew..."
    brew install imagemagick
    if ! command -v compare &>/dev/null; then
        echo -e "${FAIL} ImageMagick install failed"
        exit 1
    fi
fi
if [[ "$SCREENSHOT_ONLY" -eq 0 ]]; then echo -e "${PASS} ImageMagick available"; fi

# ── Prereqs: Google Chrome ────────────────────────────────────────────────────
if [[ ! -d "/Applications/Google Chrome.app" ]]; then
    echo -e "${FAIL} Google Chrome not found at /Applications/Google Chrome.app"
    echo "Install from https://www.google.com/chrome/ then re-run."
    exit 1
fi
echo -e "${PASS} Google Chrome found"

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
PROJECT_DIR="$current_dir" SCREENSHOT_ONLY="$SCREENSHOT_ONLY" exec bundle exec ruby "$SHARED_SCRIPTS_DIR/tools/screenshot-compare.rb"
