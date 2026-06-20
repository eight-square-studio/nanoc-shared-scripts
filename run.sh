#!/bin/bash
set -euo pipefail
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
    echo -e "Usage: ./run.sh [-c|--clean] [-n|--no-watch] [-o|--host HOST] [-p|--port PORT] [--vscode] [--vport PORT] [--restart-tailscale] [-h|--help]

Sets up the environment and starts nanoc.

By default, compiles in watch mode and serves at http://localhost:3000.
Use --no-watch to do a one-off compile with no file watching or server.

Options:
  -c, --clean            Remove output/ before running
  -n, --no-watch         Compile once only (no watch, no serve)
  -o, --host HOST        Bind the server to HOST (default: 127.0.0.1)
                         Use 0.0.0.0 to listen on all interfaces
  -p, --port PORT        Listen on PORT (default: 3000)
  --restart-tailscale    Restart Tailscale and exit (no nanoc, no VS Code)
  -h, --help             Show this help message"
}

CLEAN=false
WATCH=true
HOST="127.0.0.1"
PORT="3000"
RESTART_TAILSCALE=false
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
        -o|--host)
            HOST="$2"
            shift 2
            ;;
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        --restart-tailscale)
            RESTART_TAILSCALE=true
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

function restart_tailscale() {
    if command -v tailscale &> /dev/null; then
        echo -e "${PASS} Restarting Tailscale..."
        tailscale down
        sleep 10
        tailscale up
    else
        echo -e "${WARN} tailscale not found, skipping"
    fi
}

if [[ "$RESTART_TAILSCALE" == true ]]; then
    restart_tailscale
    exit 0
fi

if [[ "$CLEAN" == true ]]; then
    echo -e "${PASS} Cleaning output directory..."
    rm -rf output/
fi

    initiate
    if [[ "$WATCH" == true ]]; then
        while lsof -i :"$PORT" -sTCP:LISTEN &>/dev/null; do
            echo -e "${WARN} Port ${PORT} is in use, trying $((PORT + 1))..."
            PORT=$((PORT + 1))
        done
        echo -e "${PASS} Running nanoc compile, view and watch (${HOST}:${PORT})..."
        bundle exec nanoc compile -W &
        bundle exec nanoc view -L -o "$HOST" -p "$PORT"
    else
        echo -e "${PASS} Running nanoc compile..."
        bundle exec nanoc compile
fi
