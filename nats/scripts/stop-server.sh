#!/usr/bin/env bash
# stop-server.sh - tear down the NATS Core docker compose stack.
#
# Usage:
#   ./scripts/stop-server.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"
docker compose down
