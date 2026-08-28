#!/usr/bin/env bash
# bench-latency.sh - round-trip (RTT) latency through an echo peer.
#
# The SECONDARY latency metric for this project; bench-latency-oneway.sh is the primary one.
# RTT is kept because it is what most published benchmarks report (including Aeron's own
# aeron-benchmarks ping/pong harness and eProsima's LatencyTest), so it is the number that
# can actually be compared against the outside world. It is not one-way latency: it folds in
# the echo peer's receive-and-republish cost on top of two traversals, so RTT/2
# OVERESTIMATES one-way.
#
# Ping and echo run in one process here (--mode both) but on TWO DISTINCT ENDPOINTS. Aeron
# subscriptions bind their endpoint, so a shared request/response endpoint would make the
# ping side receive its own traffic. For the two-real-server version, see bench-rtt-2host.sh.
#
# Usage examples:
#   ./scripts/bench-latency.sh
#   ./scripts/bench-latency.sh --target-msgs-per-sec 2000 --duration-sec 20 --label rtt-2000
#   ./scripts/bench-latency.sh --transport ipc --label rtt-ipc
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TARGET_MSGS_PER_SEC=1000
DURATION_SEC=10
SIZE=128
LABEL="default"

while [[ $# -gt 0 ]]; do
    if parse_common_arg "$1" "${2:-}"; then shift "$COMMON_ARG_CONSUMED"; continue; fi
    case "$1" in
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --duration-sec) DURATION_SEC="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if ! awk -v v="$TARGET_MSGS_PER_SEC" 'BEGIN { exit (v+0 > 0) ? 0 : 1 }'; then
    echo "ERROR: --target-msgs-per-sec must be > 0 (no unthrottled-burst mode)." >&2
    exit 1
fi

assert_docker_running
ensure_image_built

run="$(new_run_dir latency "$LABEL")"
echo "Run dir: $run"
echo "rate=${TARGET_MSGS_PER_SEC}/s duration=${DURATION_SEC}s size=$SIZE transport=$TRANSPORT reliable=$RELIABLE pollIdle=$POLL_IDLE driverIdle=$DRIVER_IDLE"

mapfile -t common_args < <(aeron_common_args)
mapfile -t driver_env < <(driver_env_args)

tool_exit=0
docker_run_and_copy_out "$run" "${driver_env[@]}" aeron-bench aeron_bench \
    --measure rtt --mode both \
    --endpoint "$LOCAL_ENDPOINT" --response-endpoint "$LOCAL_RESPONSE_ENDPOINT" \
    --rate "$TARGET_MSGS_PER_SEC" --duration-sec "$DURATION_SEC" --size "$SIZE" \
    "${common_args[@]}" --out /out || tool_exit=$?

params="$(jq -n \
    --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
    --argjson durationSec "$DURATION_SEC" --argjson size "$SIZE" \
    --arg endpoint "$LOCAL_ENDPOINT" --arg responseEndpoint "$LOCAL_RESPONSE_ENDPOINT" \
    --argjson common "$(common_params_json)" \
    '{measure:"rtt", endpoint:$endpoint, responseEndpoint:$responseEndpoint,
      targetMsgsPerSec:$targetMsgsPerSec, durationSec:$durationSec, size:$size} + $common')"
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
echo "Done. Results in: $run (rtt.csv, result.json, meta.json; msg_loss=$msg_loss)"
echo "REMINDER: these are ROUND-TRIP figures including the echo peer's own processing."
echo "          RTT/2 overestimates one-way latency - use bench-latency-oneway.sh for that."
