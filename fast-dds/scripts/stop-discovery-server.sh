#!/usr/bin/env bash
# stop-discovery-server.sh - stops the optional Fast DDS Discovery Server.
#
# Only relevant if start-discovery-server.sh (or a --discovery server bench run) started
# one. With the default SIMPLE discovery there is no process to stop - Fast DDS is
# daemonless, so "cleaning up after benchmarking" is a no-op there.
#
# Usage:
#   ./scripts/stop-discovery-server.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

assert_docker_running
cd "$PROJECT_ROOT"

if [ "$(docker inspect -f '{{.State.Running}}' "$DS_CONTAINER" 2>/dev/null)" != "true" ]; then
    echo "Discovery Server is not running - nothing to stop."
    exit 0
fi

docker compose --profile discovery down
echo "Discovery Server stopped."
