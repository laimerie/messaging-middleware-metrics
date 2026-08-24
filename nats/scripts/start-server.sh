#!/usr/bin/env bash
# start-server.sh - bring up the NATS Core server via docker compose and wait for it to be healthy.
#
# Usage:
#   ./scripts/start-server.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

assert_docker_running

# Port conflict check (best-effort; ss/lsof availability varies by distro, so this is
# advisory only and never fails the script).
for port in 4222 8222; do
    if command -v ss >/dev/null 2>&1; then
        busy="$(ss -ltn "( sport = :$port )" 2>/dev/null | tail -n +2)"
    elif command -v lsof >/dev/null 2>&1; then
        busy="$(lsof -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
    else
        busy=""
    fi
    if [ -n "$busy" ]; then
        echo "Warning: port $port already in use - this may be our own container from a prior run, or a conflict:"
        echo "$busy"
    fi
done

cd "$PROJECT_ROOT"
docker compose up -d --build

echo "Waiting for NATS server to become healthy..."
varz="$(test_nats_server_up 15)"
server_id="$(printf '%s' "$varz" | jq -r '.server_id')"
version="$(printf '%s' "$varz" | jq -r '.version')"
echo "NATS server up: server_id=$server_id version=$version"
