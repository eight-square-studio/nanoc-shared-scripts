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
  --vscode               Restart Tailscale, ensure TLS certs in ~/.config/certs/, then launch code-server on port ${VSCODE_PORT} (no nanoc)
  --vport PORT           code-server port (default: ${VSCODE_PORT})
  --restart-tailscale    Restart Tailscale and exit (no nanoc, no VS Code)
  -h, --help             Show this help message"
}

CLEAN=false
WATCH=true
HOST="127.0.0.1"
PORT="3000"
VSCODE_PORT=8080
VSCODE=false
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
        --vscode)
            VSCODE=true
            shift
            ;;
        --vport)
            VSCODE_PORT="$2"
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

if [[ "$VSCODE" == true ]]; then
    restart_tailscale

    if ! command -v code-server &> /dev/null; then
        echo -e "${WARN} code-server not found, installing..."
        curl -fsSL https://code-server.dev/install.sh | sh
    fi

    CERTS_DIR="$HOME/.config/certs"
    CERT_FILE=$(find "$CERTS_DIR" -name "*.crt" 2>/dev/null | head -1)
    KEY_FILE=$(find "$CERTS_DIR" -name "*.key" 2>/dev/null | head -1)

    if [[ -z "$CERT_FILE" || -z "$KEY_FILE" ]]; then
        echo -e "${WARN} Certs missing from ${CERTS_DIR}, generating via tailscale..."
        mkdir -p "$CERTS_DIR"
        CERT_TMPDIR=$(mktemp -d)
        TAILSCALE_HOSTNAME=$(tailscale status --json | python3 -c "import sys,json; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))")
        (cd "$CERT_TMPDIR" && sudo tailscale cert "$TAILSCALE_HOSTNAME")
        sudo cp "$CERT_TMPDIR/${TAILSCALE_HOSTNAME}.crt" "$CERTS_DIR/"
        sudo cp "$CERT_TMPDIR/${TAILSCALE_HOSTNAME}.key" "$CERTS_DIR/"
        sudo chown "$USER" "$CERTS_DIR/${TAILSCALE_HOSTNAME}.crt" "$CERTS_DIR/${TAILSCALE_HOSTNAME}.key"
        sudo rm -rf "$CERT_TMPDIR"
        CERT_FILE="$CERTS_DIR/${TAILSCALE_HOSTNAME}.crt"
        KEY_FILE="$CERTS_DIR/${TAILSCALE_HOSTNAME}.key"
        echo -e "${PASS} Certs saved to ${CERTS_DIR}"
    else
        echo -e "${PASS} Certs found in ${CERTS_DIR}"
    fi

    if lsof -i :"$VSCODE_PORT" -sTCP:LISTEN &>/dev/null; then
        echo -e "${FAIL} Port ${VSCODE_PORT} is in use. code-server cannot start."
        exit 1
    fi

    echo -e "${PASS} Starting code-server on port ${VSCODE_PORT}..."
    RETURN_DIR="$PWD"
    trap 'cd "$RETURN_DIR"' EXIT
    cd ~
    code-server --bind-addr "0.0.0.0:${VSCODE_PORT}" --cert "$CERT_FILE" --cert-key "$KEY_FILE"
else
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
fi
