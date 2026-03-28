#!/bin/bash
# Setup environment and run nanoc — watch + serve by default, or compile only with --no-watch

# Resolve symlinks to find the real script directory
_s="${BASH_SOURCE[0]}"
while [[ -L "$_s" ]]; do _d="$(cd "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; [[ "$_s" != /* ]] && _s="$_d/$_s"; done
source "$(cd "$(dirname "$_s")" && pwd)/shared.sh"

if [[ ! -f "nanoc.yaml" ]]; then
    echo "Error: must be run from the project root (nanoc.yaml not found)"
    exit 1
fi

function print_help() {
    echo -e "Usage: ./run.sh [-c|--clean] [-n|--no-watch] [-h|--help]

Sets up the environment and starts nanoc.

By default, compiles in watch mode and serves at http://localhost:3000.
Use --no-watch to do a one-off compile with no file watching or server.

Options:
  -c, --clean     Remove output/ before running
  -n, --no-watch  Compile once only (no watch, no serve)
  -h, --help      Show this help message"
}

CLEAN=false
WATCH=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--clean)
            CLEAN=true
            shift
            ;;
        -n|--no-watch)
            WATCH=false
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_help
            exit 1
            ;;
    esac
done

if [[ "$CLEAN" == true ]]; then
    echo -e "${PASS} Cleaning output directory..."
    rm -rf output/
fi

initiate

if [[ "$WATCH" == true ]]; then
    echo -e "${PASS} Running nanoc compile, view and watch..."
    bundle exec nanoc compile -W &
    bundle exec nanoc view -L
else
    echo -e "${PASS} Running nanoc compile..."
    bundle exec nanoc compile
fi
