#!/bin/bash

if command -v tailscale &> /dev/null; then
  tailscale down
  sleep 10
  tailscale up
else
  echo "tailscale not found, skipping"
fi

if command -v code &> /dev/null; then
  code serve-web --host 0.0.0.0 --port 8000 --without-connection-token --accept-server-license-terms
else
  echo "vs code not found, skipping"
fi
