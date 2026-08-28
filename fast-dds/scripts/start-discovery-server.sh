#!/usr/bin/env bash
# start-discovery-server.sh - starts the OPTIONAL Fast DDS Discovery Server.
#
# Fast DDS is daemonless: with the default SIMPLE discovery there is nothing to start, and
# the bench scripts work with no server running at all. This script exists only for
# --discovery server runs, where `fast-discovery-server` acts as a unicast rendezvous point
# instead of multicast.
#
# What it does and does not do: it brokers DISCOVERY ONLY. Participants use it to learn
# about each other; once they have, sample data flows directly peer-to-peer and never
# passes through this process. It is not a message broker, and it is not on the data path -
# so unlike NATS's server, it does not appear in any latency or throughput measurement
# except through the discovery time at the start of a run.
#
# You rarely need to run this by hand: every bench-*.sh calls ensure_discovery_server
# (common.sh), which starts it automatically when --discovery server is in effect.
#
# Usage:
#   ./scripts/start-discovery-server.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

assert_docker_running
ensure_image_built

DISCOVERY="server"   # makes ensure_discovery_server actually do its work
ensure_discovery_server

echo "Discovery Server is up at $DS_ADDRESS:$DS_PORT (container: $DS_CONTAINER)."
echo "Pass --discovery server to any bench-*.sh to use it."
echo "Logs: docker compose --profile discovery logs -f discovery-server"
