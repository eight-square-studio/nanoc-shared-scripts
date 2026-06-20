#!/bin/bash
set -euo pipefail
# Setup environment and run nanoc — watch + serve by default, or compile only with --no-watch

# Resolve symlinks to find the real script directory
_s="${BASH_SOURCE[0]}"
while [[ -L "$_s" ]]; do _d="$(cd "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; [[ "$_s" != /* ]] && _s="$_d/$_s"; done

# Colours
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

FAIL="${RED}[FAIL]${NC}"
WARN="${YELLOW}[WARNING]${NC}"
PASS="${GREEN}[OK]${NC}"

trap 'status=$?; [[ $status -ne 0 ]] && echo "exiting $0 with status code $status"' EXIT

export PATH="$HOME/.local/bin:$PATH"

VSCODE_PORT=8080

if ! command -v code-server &> /dev/null; then
    echo -e "${WARN} code-server not found, installing..."
    curl -fsSL https://code-server.dev/install.sh | sh
fi

CERTS_DIR="$HOME/.config/certs"
CERT_FILE=$(find "$CERTS_DIR" -name "*.crt" 2>/dev/null | head -1)
KEY_FILE=$(find "$CERTS_DIR" -name "*.key" 2>/dev/null | head -1)

if [[ -z "$CERT_FILE" || -z "$KEY_FILE" ]]; then
    echo -e "${WARN} Certs missing from ${CERTS_DIR}..."
    exit 9
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
