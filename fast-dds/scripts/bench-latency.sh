#!/usr/bin/env bash
# bench-latency.sh - round-trip time (RTT) via an echo peer.
#
# The counterpart of nats/scripts/bench-latency.sh (`nats bench service serve/request`),
# kept for the same reason: RTT is what most published middleware benchmarks report, so
# having it makes this project's numbers comparable with the outside world - including with
# eProsima's own LatencyTest, which is also a ping/pong measurement.
#
# It is NOT the primary latency number here. Use bench-latency-oneway.sh for that: a
# one-way figure is what a real publish->subscribe deployment experiences, and RTT folds in
# the echo peer's own receive-and-republish cost on top of two network traversals.
#
# The ping side writes on <topic>_req and reads <topic>_resp; the echo side does the
# reverse, re-publishing each sample byte-for-byte so the original send timestamp survives
# the round trip. Both roles run in one process here (--mode both); bench-crosshost.sh
# splits them across containers.
#
# Rate-paced for the same reason as the one-way tool: an unthrottled ping flood measures
# queueing, not latency. --target-msgs-per-sec and --duration-sec are both required.
#
# Usage examples:
#   ./scripts/bench-latency.sh
#   ./scripts/bench-latency.sh --target-msgs-per-sec 2000 --duration-sec 20 --label rtt-2000
#   ./scripts/bench-latency.sh --reliability reliable --label rtt-reliable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TOPIC="BENCH_LATENCY_RTT"
TARGET_MSGS_PER_SEC=1000
DURATION_SEC=10
SIZE=128
LABEL="default"

while [[ $# -gt 0 ]]; do
    if parse_common_arg "$1" "${2:-}"; then shift "$COMMON_ARG_CONSUMED"; continue; fi
    case "$1" in
        --topic) TOPIC="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --duration-sec) DURATION_SEC="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if ! awk -v v="$TARGET_MSGS_PER_SEC" 'BEGIN { exit (v+0 > 0) ? 0 : 1 }'; then
    echo "ERROR: --target-msgs-per-sec must be > 0 (see script header)." >&2
    exit 1
fi

assert_docker_running
ensure_image_built
ensure_discovery_server

run="$(new_run_dir latency "$LABEL")"
echo "Run dir: $run"
echo "topic=$TOPIC rate=${TARGET_MSGS_PER_SEC}/s duration=${DURATION_SEC}s size=$SIZE reliability=$RELIABILITY transport=$TRANSPORT discovery=$DISCOVERY"

mapfile -t common_args < <(dds_common_args)

tool_exit=0
docker_run_and_copy_out "$run" dds-bench dds_bench \
    --measure rtt --mode both \
    --topic "$TOPIC" --rate "$TARGET_MSGS_PER_SEC" --duration-sec "$DURATION_SEC" \
    --size "$SIZE" \
    "${common_args[@]}" --out /out || tool_exit=$?

params="$(jq -n \
    --arg topic "$TOPIC" --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
    --argjson durationSec "$DURATION_SEC" --argjson size "$SIZE" \
    --argjson common "$(common_params_json)" \
    '{topic:$topic, targetMsgsPerSec:$targetMsgsPerSec, durationSec:$durationSec,
      size:$size, measure:"rtt"} + $common')"
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
echo "Done. Results in: $run (rtt.csv, result.json, meta.json; msg_loss=$msg_loss)"
echo "Note: these are ROUND-TRIP figures. For one-way latency use bench-latency-oneway.sh."
