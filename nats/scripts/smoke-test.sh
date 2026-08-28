#!/usr/bin/env bash
# smoke-test.sh - end-to-end sanity check of the whole pipeline:
#   Docker container up -> nats CLI reachable -> bench runs -> results captured.
# Run this once after setup, before attempting full-scale benchmark runs.
#
# Usage:
#   ./scripts/smoke-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

assert_docker_running
assert_nats_cli_installed

echo "1) Ensuring NATS server is up..."
cd "$PROJECT_ROOT"
docker compose up -d
varz="$(test_nats_server_up 15)"
echo "   OK - server_id=$(printf '%s' "$varz" | jq -r '.server_id') version=$(printf '%s' "$varz" | jq -r '.version')"

echo "2) nats CLI version:"
nats --version

echo "3) Running smoke pub/sub (1000 msgs)..."
run="$(new_run_dir smoke sanity)"
subject="SMOKE.TEST"

( nats bench sub "$subject" --msgs 1000 --server "$NATS_SERVER_URL" --no-progress --csv "$run/sub.csv" ) &
sub_pid=$!

sleep 2   # let the subscription register before publishing - NATS Core does not
          # persist/queue messages published before a subscriber attaches.

nats bench pub "$subject" --msgs 1000 --server "$NATS_SERVER_URL" --no-progress --csv "$run/pub.csv" \
    | tee "$run/pub.summary.txt"

wait "$sub_pid" || true

echo "4) Verifying results..."
pub_ok=false
sub_ok=false
[ -s "$run/pub.csv" ] && pub_ok=true
[ -s "$run/sub.csv" ] && sub_ok=true

received=""
if [ -f "$run/sub.csv" ]; then
    # sub.csv header: #RunID,ClientID,MsgCount,MsgBytes,MsgsPerSec,BytesPerSec,DurationSecs
    received="$(tail -n +2 "$run/sub.csv" | awk -F, '{sum+=$3} END {print sum+0}')"
fi

echo "   pub.csv present & non-empty: $pub_ok"
echo "   sub.csv present & non-empty: $sub_ok"
echo "   sub received: $received / 1000 expected"

if [ "$pub_ok" = true ] && [ "$sub_ok" = true ] && [ "$received" = "1000" ]; then
    echo
    echo "SMOKE TEST PASSED - pipeline is ready (0 message loss). Results in: $run"
else
    echo
    echo "SMOKE TEST FAILED - see output above." >&2
    exit 1
fi
