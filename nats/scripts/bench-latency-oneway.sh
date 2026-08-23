#!/usr/bin/env bash
# bench-latency-oneway.sh - true one-way (publisher -> subscriber) latency measurement.
#
# Unlike bench-latency.sh (nats bench service serve/request = round-trip time), this
# drives the custom C++ tool in docker/latency-tool/ (TODO.md #4), built to match the
# production runtime (CentOS 7 / gcc 11 / C++17) so the measurement client's own
# overhead isn't mistaken for NATS Core's latency.
#
# --target-msgs-per-sec and --duration-sec are the primary, both-required parameters
# (msgs count is derived as rate * duration inside the tool). There is deliberately no
# "unthrottled burst" mode - an unthrottled send measures the subscriber's queueing delay
# working through a backlog, not NATS's actual steady-state one-way latency (confirmed by
# measurement - see TODO.md #4). Always specify the rate you actually want measured.
#
# Usage examples:
#   ./scripts/bench-latency-oneway.sh
#   ./scripts/bench-latency-oneway.sh --target-msgs-per-sec 5000 --duration-sec 30 --label rate5000
#   ./scripts/bench-latency-oneway.sh --size 512 --label size512
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SUBJECT="BENCH.LATENCY.ONEWAY"
TARGET_MSGS_PER_SEC=1000
DURATION_SEC=10
SIZE=128
LABEL="default"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --subject) SUBJECT="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --duration-sec) DURATION_SEC="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if ! awk -v v="$TARGET_MSGS_PER_SEC" 'BEGIN { exit (v+0 > 0) ? 0 : 1 }'; then
    echo "ERROR: --target-msgs-per-sec must be > 0 (no unthrottled-burst mode - see script header)." >&2
    exit 1
fi

assert_docker_running
test_nats_server_up >/dev/null

run="$(new_run_dir latency "$LABEL")"
echo "Run dir: $run"

cd "$PROJECT_ROOT"
echo "Building latency-tool image (cached after first run)..."
docker compose build latency-tool

echo "subject=$SUBJECT rate=${TARGET_MSGS_PER_SEC}/s duration=${DURATION_SEC}s size=$SIZE"
# latency-tool's ENTRYPOINT is a generic wrapper (TODO.md #3), so the binary name must be
# passed explicitly as the first argument.
tool_exit=0
docker_run_and_copy_out "$run" latency-tool latency_oneway --mode both \
    --subject "$SUBJECT" --rate "$TARGET_MSGS_PER_SEC" --duration-sec "$DURATION_SEC" --size "$SIZE" \
    --server "nats://nats:4222" --out /out || tool_exit=$?

commonParams="$(jq -n \
    --arg subject "$SUBJECT" --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
    --argjson durationSec "$DURATION_SEC" --argjson size "$SIZE" \
    '{subject:$subject, targetMsgsPerSec:$targetMsgsPerSec, durationSec:$durationSec, size:$size}')"
save_meta "$run" "latency_oneway (CentOS 7 / gcc 11 / C++17, nats.c)" "$commonParams"

# The C++ tool already wrote its own result.json (TODO.md #6 schema) directly into $run -
# read it back here just to append the run-index.csv summary row, rather than duplicating
# the metrics computation in two languages.
if [ -f "$run/result.json" ]; then
    p50="$(jq -r '.metrics.latency_us.p50 // empty' "$run/result.json")"
    p99="$(jq -r '.metrics.latency_us.p99 // empty' "$run/result.json")"
    loss="$(jq -r '.msg_loss // empty' "$run/result.json")"
    metrics="$(jq -n --argjson p50 "${p50:-null}" --argjson p99 "${p99:-null}" --argjson loss "${loss:-null}" \
        '{p50_latency_us:$p50, p99_latency_us:$p99, msg_loss:$loss}')"
    add_run_index_entry "$run" latency "$LABEL" "$metrics"
else
    echo "Warning: could not read result.json from the tool - skipping run-index.csv entry." >&2
fi

if [ "$tool_exit" -ne 0 ]; then
    echo
    echo "latency-tool reported message loss or an error (exit $tool_exit). See result.json in $run" >&2
    exit "$tool_exit"
fi
echo
echo "Done. Results in: $run (oneway.csv, result.json, meta.json)"
