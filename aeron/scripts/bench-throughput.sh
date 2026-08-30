#!/usr/bin/env bash
# bench-throughput.sh - throughput measurement (msgs/sec, MB/sec) for Aeron pub/sub.
#
# Publisher and subscriber run as separate Aeron client connections inside ONE aeron_bench
# process (--mode both), talking to the one media driver in that container. Unlike Fast DDS
# there is no intra-process shortcut to disable: even same-process endpoints go through the
# driver, and over --transport udp they go through the kernel's UDP stack as well. For
# publisher and subscriber in separate containers with separate DRIVERS, see
# bench-crosshost.sh.
#
# READ THIS BEFORE COMPARING THE NUMBER TO NATS OR FAST DDS. Aeron's flow control is always
# on and receiver-driven. A publisher that outruns its slowest subscriber is not allowed to
# drop it - offer() returns BACK_PRESSURED and the publisher waits. So an unthrottled run
# here measures "the rate the subscriber could sustain", whereas the same run under Fast DDS
# BEST_EFFORT measures "the rate the publisher could emit while the subscriber lost the
# rest". Both are legitimate; they are not the same quantity. This script prints the
# back-pressure count precisely so the difference is visible rather than assumed.
#
# Usage examples:
#   ./scripts/bench-throughput.sh
#   ./scripts/bench-throughput.sh --size 16384 --label large-msg
#   ./scripts/bench-throughput.sh --pub-count 4 --sub-count 4 --label 4x4-clients
#   ./scripts/bench-throughput.sh --target-msgs-per-sec 5000 --label sustained-5k
#   ./scripts/bench-throughput.sh --stream-count 50 --label multi-stream
#   ./scripts/bench-throughput.sh --transport ipc --label shared-memory
#   ./scripts/bench-throughput.sh --driver-idle backoff --label stock-driver-defaults
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

MSGS=200000
SIZE=128
PUB_COUNT=1
SUB_COUNT=1
STREAM_COUNT=1
TARGET_MSGS_PER_SEC=0   # 0 = unthrottled (see the header for what that means under Aeron)
LABEL="default"

while [[ $# -gt 0 ]]; do
    if parse_common_arg "$1" "${2:-}"; then shift "$COMMON_ARG_CONSUMED"; continue; fi
    case "$1" in
        --msgs) MSGS="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --pub-count) PUB_COUNT="$2"; shift 2 ;;
        --sub-count) SUB_COUNT="$2"; shift 2 ;;
        --stream-count) STREAM_COUNT="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

assert_docker_running
ensure_image_built

run="$(new_run_dir throughput "$LABEL")"
echo "Run dir: $run"
echo "msgs=$MSGS size=$SIZE pubCount=$PUB_COUNT subCount=$SUB_COUNT streamCount=$STREAM_COUNT targetMsgsPerSec=$TARGET_MSGS_PER_SEC transport=$TRANSPORT reliable=$RELIABLE pollIdle=$POLL_IDLE driverIdle=$DRIVER_IDLE"

mapfile -t common_args < <(aeron_common_args)
mapfile -t driver_env < <(driver_env_args)

tool_exit=0
docker_run_and_copy_out "$run" "${driver_env[@]}" aeron-bench aeron_bench \
    --measure throughput --mode both \
    --endpoint "$LOCAL_ENDPOINT" --stream-count "$STREAM_COUNT" \
    --msgs "$MSGS" --size "$SIZE" \
    --pub-count "$PUB_COUNT" --sub-count "$SUB_COUNT" --rate "$TARGET_MSGS_PER_SEC" \
    "${common_args[@]}" --out /out || tool_exit=$?

params="$(jq -n \
    --argjson msgs "$MSGS" --argjson size "$SIZE" \
    --argjson pubCount "$PUB_COUNT" --argjson subCount "$SUB_COUNT" \
    --argjson streamCount "$STREAM_COUNT" --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
    --arg endpoint "$LOCAL_ENDPOINT" \
    --argjson common "$(common_params_json)" \
    '{endpoint:$endpoint, msgs:$msgs, size:$size, pubCount:$pubCount, subCount:$subCount,
      streamCount:$streamCount, targetMsgsPerSec:$targetMsgsPerSec} + $common')"
save_meta "$run" "$(tool_version "$run/result.json")" "$params"

# aeron_bench already wrote result.json (same schema as nats/ and fast-dds/) - lift the
# summary columns back out for run-index.csv rather than recomputing the metrics here.
msg_loss=0
if ! msg_loss="$(index_from_result_json "$run/result.json" "$run" throughput "$LABEL")"; then
    echo "Warning: could not read result.json from the tool - skipping run-index.csv entry." >&2
fi

if [ "$tool_exit" -ne 0 ]; then
    echo
    echo "aeron_bench exited with code $tool_exit. See result.json in $run" >&2
    exit "$tool_exit"
fi
if [ "${msg_loss:-0}" -gt 0 ] && loss_is_failure; then
    echo
    echo "Done with problems: msg_loss=$msg_loss with reliable delivery in effect. Results in: $run" >&2
    exit 1
fi
echo
report_back_pressure "$run/result.json"
echo "Done. Results in: $run (msg_loss=${msg_loss})"
