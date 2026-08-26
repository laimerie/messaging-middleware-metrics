#!/usr/bin/env bash
# bench-latency-oneway.sh - true one-way (publisher -> subscriber) latency measurement.
#
# The direct counterpart of nats/scripts/bench-latency-oneway.sh and
# fast-dds/scripts/bench-latency-oneway.sh, and the primary latency number for this project:
# it measures what a deployment actually experiences, whereas bench-latency.sh (RTT via an
# echo peer) measures a round trip.
#
# --target-msgs-per-sec and --duration-sec are the primary, both-required parameters; the
# message count is derived (rate * duration) inside the tool and --msgs is rejected
# outright. There is deliberately no "unthrottled burst" mode - an unthrottled send measures
# the subscriber's queueing delay working through a backlog, not steady-state one-way
# latency. Confirmed empirically on the NATS side (nats/TODO.md #4); middleware-independent.
#
# TWO KNOBS DOMINATE THIS NUMBER, and both default to the low-latency setting here:
#   --driver-idle   how the MEDIA DRIVER's threads wait. Aeron's stock `backoff` parks for
#                   up to a millisecond. Measured: p50 245us (backoff) vs 21us (noop).
#   --poll-idle     how THIS TOOL's subscriber loop waits. Aeron does not call you back.
# Run with --driver-idle backoff --poll-idle sleep to see out-of-the-box behaviour instead.
#
# Usage examples:
#   ./scripts/bench-latency-oneway.sh
#   ./scripts/bench-latency-oneway.sh --target-msgs-per-sec 5000 --duration-sec 30 --label rate5000
#   ./scripts/bench-latency-oneway.sh --size 512 --label size512
#   ./scripts/bench-latency-oneway.sh --transport ipc --label ipc-1000
#   ./scripts/bench-latency-oneway.sh --driver-idle backoff --label stock-driver-defaults
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TARGET_MSGS_PER_SEC=1000
DURATION_SEC=10
SIZE=128
SUB_COUNT=1
LABEL="default"

while [[ $# -gt 0 ]]; do
    if parse_common_arg "$1" "${2:-}"; then shift "$COMMON_ARG_CONSUMED"; continue; fi
    case "$1" in
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

run="$(new_run_dir latency "$LABEL")"
echo "Run dir: $run"
echo "rate=${TARGET_MSGS_PER_SEC}/s duration=${DURATION_SEC}s size=$SIZE subCount=$SUB_COUNT transport=$TRANSPORT reliable=$RELIABLE pollIdle=$POLL_IDLE driverIdle=$DRIVER_IDLE"

mapfile -t common_args < <(aeron_common_args)
mapfile -t driver_env < <(driver_env_args)

tool_exit=0
docker_run_and_copy_out "$run" "${driver_env[@]}" aeron-bench aeron_bench \
    --measure latency --mode both \
    --endpoint "$LOCAL_ENDPOINT" \
    --rate "$TARGET_MSGS_PER_SEC" --duration-sec "$DURATION_SEC" \
    --size "$SIZE" --sub-count "$SUB_COUNT" \
    "${common_args[@]}" --out /out || tool_exit=$?

params="$(jq -n \
    --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
    --argjson durationSec "$DURATION_SEC" --argjson size "$SIZE" --argjson subCount "$SUB_COUNT" \
    --arg endpoint "$LOCAL_ENDPOINT" \
    --argjson common "$(common_params_json)" \
    '{endpoint:$endpoint, targetMsgsPerSec:$targetMsgsPerSec, durationSec:$durationSec,
      size:$size, subCount:$subCount} + $common')"
save_meta "$run" "$(tool_version "$run/result.json")" "$params"

msg_loss=0
if ! msg_loss="$(index_from_result_json "$run/result.json" "$run" latency "$LABEL")"; then
    echo "Warning: could not read result.json from the tool - skipping run-index.csv entry." >&2
fi

if [ "$tool_exit" -ne 0 ]; then
    echo
    echo "aeron_bench exited with code $tool_exit. See result.json in $run" >&2
    exit "$tool_exit"
fi
echo
report_back_pressure "$run/result.json"
echo "Done. Results in: $run (oneway.csv, result.json, meta.json; msg_loss=$msg_loss)"
