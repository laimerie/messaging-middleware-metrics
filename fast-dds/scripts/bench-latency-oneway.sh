#!/usr/bin/env bash
# bench-latency-oneway.sh - true one-way (publisher -> subscriber) latency measurement.
#
# The direct counterpart of nats/scripts/bench-latency-oneway.sh, and the primary latency
# number for this project: it measures what a DDS deployment actually experiences, whereas
# bench-latency.sh (RTT via an echo peer) measures a round trip.
#
# --target-msgs-per-sec and --duration-sec are the primary, both-required parameters; the
# message count is derived (rate * duration) inside the tool and --msgs is rejected
# outright. There is deliberately no "unthrottled burst" mode - an unthrottled send
# measures the subscriber's queueing delay working through a backlog, not steady-state
# one-way latency. That was confirmed empirically on the NATS side (nats/TODO.md #4) and
# the reasoning is middleware-independent, so this tool was built that way from the start.
#
# Usage examples:
#   ./scripts/bench-latency-oneway.sh
#   ./scripts/bench-latency-oneway.sh --target-msgs-per-sec 5000 --duration-sec 30 --label rate5000
#   ./scripts/bench-latency-oneway.sh --size 512 --label size512
#   ./scripts/bench-latency-oneway.sh --reliability reliable --label reliable-1000
#   ./scripts/bench-latency-oneway.sh --transport shm --label shm-1000
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TOPIC="BENCH_LATENCY_ONEWAY"
TARGET_MSGS_PER_SEC=1000
DURATION_SEC=10
SIZE=128
SUB_COUNT=1
LABEL="default"

while [[ $# -gt 0 ]]; do
    if parse_common_arg "$1" "${2:-}"; then shift "$COMMON_ARG_CONSUMED"; continue; fi
    case "$1" in
        --topic) TOPIC="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --duration-sec) DURATION_SEC="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --sub-count) SUB_COUNT="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if ! awk -v v="$TARGET_MSGS_PER_SEC" 'BEGIN { exit (v+0 > 0) ? 0 : 1 }'; then
    echo "ERROR: --target-msgs-per-sec must be > 0 (no unthrottled-burst mode - see script header)." >&2
    exit 1
fi

assert_docker_running
ensure_image_built
ensure_discovery_server

run="$(new_run_dir latency "$LABEL")"
echo "Run dir: $run"
echo "topic=$TOPIC rate=${TARGET_MSGS_PER_SEC}/s duration=${DURATION_SEC}s size=$SIZE subCount=$SUB_COUNT reliability=$RELIABILITY transport=$TRANSPORT discovery=$DISCOVERY"

mapfile -t common_args < <(dds_common_args)

tool_exit=0
docker_run_and_copy_out "$run" dds-bench dds_bench \
    --measure latency --mode both \
    --topic "$TOPIC" --rate "$TARGET_MSGS_PER_SEC" --duration-sec "$DURATION_SEC" \
    --size "$SIZE" --sub-count "$SUB_COUNT" \
    "${common_args[@]}" --out /out || tool_exit=$?

params="$(jq -n \
    --arg topic "$TOPIC" --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
    --argjson durationSec "$DURATION_SEC" --argjson size "$SIZE" --argjson subCount "$SUB_COUNT" \
    --argjson common "$(common_params_json)" \
    '{topic:$topic, targetMsgsPerSec:$targetMsgsPerSec, durationSec:$durationSec,
      size:$size, subCount:$subCount} + $common')"
save_meta "$run" "$(tool_version "$run/result.json")" "$params"

msg_loss=0
if ! msg_loss="$(index_from_result_json "$run/result.json" "$run" latency "$LABEL")"; then
    echo "Warning: could not read result.json from the tool - skipping run-index.csv entry." >&2
fi

if [ "$tool_exit" -ne 0 ]; then
    echo
    echo "dds_bench exited with code $tool_exit. See result.json in $run" >&2
    exit "$tool_exit"
fi
echo
echo "Done. Results in: $run (oneway.csv, result.json, meta.json; msg_loss=$msg_loss)"
