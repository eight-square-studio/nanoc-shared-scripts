#!/bin/bash
set -euo pipefail
# Set up the development environment — install rbenv, Ruby, and bundle dependencies

# Resolve symlinks to find the real script directory
_s="${BASH_SOURCE[0]}"
while [[ -L "$_s" ]]; do _d="$(cd "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; [[ "$_s" != /* ]] && _s="$_d/$_s"; done
source "$(cd "$(dirname "$_s")" && pwd)/lib/_shared.sh"

if [[ ! -f "nanoc.yaml" ]]; then
    echo "Error: must be run from the project root (nanoc.yaml not found)"
    exit 1
fi

initiate
echo -e "${PASS} Setup complete"
