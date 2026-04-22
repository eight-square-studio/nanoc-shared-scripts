#!/bin/bash
set -euo pipefail
# Visual regression screenshot comparison — catches layout changes between current branch and release.
# Run from the project root: bash check-layouts.sh (or via symlink: ./check-layouts.sh)

# Resolve symlink to find the real script directory, then source shared.sh
_s="${BASH_SOURCE[0]}"
while [[ -L "$_s" ]]; do _d="$(cd "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; [[ "$_s" != /* ]] && _s="$_d/$_s"; done
SHARED_SCRIPTS_DIR="$(cd "$(dirname "$_s")" && pwd)"
source "$SHARED_SCRIPTS_DIR/shared.sh"

# ── Prereqs: ImageMagick ──────────────────────────────────────────────────────
if ! command -v compare &>/dev/null || ! command -v convert &>/dev/null; then
    echo -e "${WARN} ImageMagick not found — installing via Homebrew..."
    brew install imagemagick
    if ! command -v compare &>/dev/null; then
        echo -e "${FAIL} ImageMagick install failed"
        exit 1
    fi
fi
echo -e "${PASS} ImageMagick available"

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
PROJECT_DIR="$current_dir" exec bundle exec ruby "$SHARED_SCRIPTS_DIR/tools/screenshot-compare.rb"
