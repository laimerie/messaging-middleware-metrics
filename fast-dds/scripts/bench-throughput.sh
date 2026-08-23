#!/usr/bin/env bash
# bench-throughput.sh - throughput measurement (msgs/sec, MB/sec) for Fast DDS pub/sub.
#
# Publisher and subscriber run as separate DomainParticipants inside ONE dds_bench process
# (--mode both), with Fast DDS's intra-process shortcut disabled so samples really cross
# the transport. For the publisher and subscriber in separate containers, see
# bench-crosshost.sh.
#
# No `sleep 2` before publishing, unlike the NATS scripts: the tool waits for real
# publication-matched events instead, which is both stricter and faster. DDS discovery is
# asynchronous and BEST_EFFORT + VOLATILE silently discards anything written before a
# reader is matched, so a fixed sleep would be a guess in exactly the place a guess is
# expensive.
#
# Usage examples:
#   ./scripts/bench-throughput.sh
#   ./scripts/bench-throughput.sh --size 16384 --label large-msg
#   ./scripts/bench-throughput.sh --pub-count 4 --sub-count 4 --label 4x4-participants
#   ./scripts/bench-throughput.sh --target-msgs-per-sec 5000 --label sustained-5k
#   ./scripts/bench-throughput.sh --topic-count 100 --label multi-topic
#   ./scripts/bench-throughput.sh --reliability reliable --label reliable-baseline
#   ./scripts/bench-throughput.sh --transport shm --label shared-memory
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TOPIC="BENCH_THROUGHPUT"
MSGS=200000
SIZE=128
PUB_COUNT=1
SUB_COUNT=1
TOPIC_COUNT=1
TARGET_MSGS_PER_SEC=0   # 0 = unthrottled (max speed / saturation test)
LABEL="default"

while [[ $# -gt 0 ]]; do
    if parse_common_arg "$1" "${2:-}"; then shift "$COMMON_ARG_CONSUMED"; continue; fi
    case "$1" in
        --topic) TOPIC="$2"; shift 2 ;;
        --msgs) MSGS="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --pub-count) PUB_COUNT="$2"; shift 2 ;;
        --sub-count) SUB_COUNT="$2"; shift 2 ;;
        --topic-count) TOPIC_COUNT="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

assert_docker_running
ensure_image_built
ensure_discovery_server

run="$(new_run_dir throughput "$LABEL")"
echo "Run dir: $run"
echo "topic=$TOPIC msgs=$MSGS size=$SIZE pubCount=$PUB_COUNT subCount=$SUB_COUNT topicCount=$TOPIC_COUNT targetMsgsPerSec=$TARGET_MSGS_PER_SEC reliability=$RELIABILITY transport=$TRANSPORT discovery=$DISCOVERY"

mapfile -t common_args < <(dds_common_args)

tool_exit=0
docker_run_and_copy_out "$run" dds-bench dds_bench \
    --measure throughput --mode both \
    --topic "$TOPIC" --topic-count "$TOPIC_COUNT" --msgs "$MSGS" --size "$SIZE" \
    --pub-count "$PUB_COUNT" --sub-count "$SUB_COUNT" --rate "$TARGET_MSGS_PER_SEC" \
    "${common_args[@]}" --out /out || tool_exit=$?

params="$(jq -n \
    --arg topic "$TOPIC" --argjson msgs "$MSGS" --argjson size "$SIZE" \
    --argjson pubCount "$PUB_COUNT" --argjson subCount "$SUB_COUNT" \
    --argjson topicCount "$TOPIC_COUNT" --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
    --argjson common "$(common_params_json)" \
    '{topic:$topic, msgs:$msgs, size:$size, pubCount:$pubCount, subCount:$subCount,
      topicCount:$topicCount, targetMsgsPerSec:$targetMsgsPerSec} + $common')"
save_meta "$run" "$(tool_version "$run/result.json")" "$params"

# dds_bench already wrote result.json (the TODO.md #4 schema, matching nats/'s) - lift the
# summary columns back out for run-index.csv rather than recomputing the metrics here.
msg_loss=0
if ! msg_loss="$(index_from_result_json "$run/result.json" "$run" throughput "$LABEL")"; then
    echo "Warning: could not read result.json from the tool - skipping run-index.csv entry." >&2
fi

if [ "$tool_exit" -ne 0 ]; then
    echo
    echo "dds_bench exited with code $tool_exit. See result.json in $run" >&2
    exit "$tool_exit"
fi
if [ "${msg_loss:-0}" -gt 0 ] && loss_is_failure; then
    echo
    echo "Done with problems: msg_loss=$msg_loss under --reliability reliable. Results in: $run" >&2
    exit 1
fi
note=""
if [ "${msg_loss:-0}" -gt 0 ]; then
    note=" - expected under BEST_EFFORT, see README.md's \"msg_lossの読み方\""
fi
echo
echo "Done. Results in: $run (msg_loss=${msg_loss}${note})"
