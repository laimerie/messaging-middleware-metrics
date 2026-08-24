#!/usr/bin/env bash
# bench-scalability.sh - participant / topic scalability sweep.
#
# The counterpart of nats/scripts/bench-scalability.sh, but sweeping a genuinely different
# quantity. NATS sweeps CONNECTION count: N clients each holding a TCP connection to one
# broker, so the sweep measures how well that broker's connection handling scales.
# Fast DDS has no broker and no connections, so the equivalent axis is PARTICIPANT count:
# each subscriber participant is an independent RTPS peer that every publisher must
# discover, match, and then send to individually. This sweep therefore measures the cost of
# peer-to-peer fan-out and of discovery itself - which is where DDS deployments actually
# hit their ceiling.
#
# Two axes, usable together or separately:
#   --participant-counts   N subscriber participants (default sweep 1,5,10,25)
#   --topic-count          T topics per participant. DDS has no subject wildcards, so this
#                          is the analogue of NATS's --multisubject: T distinct topics with
#                          a reader each, rather than one wildcard subscription.
#
# Caution: participants are much heavier than NATS connections - each runs its own
# discovery state machine and builtin endpoints, and every added participant multiplies the
# discovery traffic (N participants discover each other pairwise). Expect the practical
# ceiling to be lower than a NATS connection sweep's, and expect --discovery server to
# raise it, since it replaces N-squared multicast announcements with a unicast rendezvous.
#
# Usage examples:
#   ./scripts/bench-scalability.sh
#   ./scripts/bench-scalability.sh --participant-counts 1,10,50
#   ./scripts/bench-scalability.sh --topic-count 100
#   ./scripts/bench-scalability.sh --discovery server --participant-counts 1,10,50,100
#   ./scripts/bench-scalability.sh --target-msgs-per-sec 5000
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TOPIC="BENCH_SCALE"
PARTICIPANT_COUNTS="1,5,10,25"
MSGS_PER_PARTICIPANT=10000
SIZE=128
TOPIC_COUNT=1
TARGET_MSGS_PER_SEC=0
LABEL="sweep"

while [[ $# -gt 0 ]]; do
    if parse_common_arg "$1" "${2:-}"; then shift "$COMMON_ARG_CONSUMED"; continue; fi
    case "$1" in
        --topic) TOPIC="$2"; shift 2 ;;
        --participant-counts) PARTICIPANT_COUNTS="$2"; shift 2 ;;
        --msgs-per-participant) MSGS_PER_PARTICIPANT="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --topic-count) TOPIC_COUNT="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

assert_docker_running
ensure_image_built
ensure_discovery_server

sweep_run="$(new_run_dir scalability "$LABEL")"
echo "Sweep dir: $sweep_run"

mapfile -t common_args < <(dds_common_args)

sweep_had_failure=false
# A comma-separated string split manually - no implicit type coercion to fight, unlike the
# PowerShell array-parameter trap recorded in nats/TODO.md #2.
IFS=',' read -ra COUNTS <<< "$PARTICIPANT_COUNTS"
for n in "${COUNTS[@]}"; do
    echo
    echo "=== participants=$n ==="
    iter_dir="$sweep_run/participants-$n"
    mkdir -p "$iter_dir"

    total_msgs=$(( MSGS_PER_PARTICIPANT * n ))

    tool_exit=0
    docker_run_and_copy_out "$iter_dir" dds-bench dds_bench \
        --measure throughput --mode both \
        --topic "$TOPIC" --topic-count "$TOPIC_COUNT" --msgs "$total_msgs" --size "$SIZE" \
        --sub-count "$n" --rate "$TARGET_MSGS_PER_SEC" \
        "${common_args[@]}" --out /out || tool_exit=$?

    iter_params="$(jq -n \
        --arg topic "$TOPIC" --argjson participants "$n" --argjson totalMsgs "$total_msgs" \
        --argjson size "$SIZE" --argjson topicCount "$TOPIC_COUNT" \
        --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
        --argjson common "$(common_params_json)" \
        '{topic:$topic, participants:$participants, totalMsgs:$totalMsgs, size:$size,
          topicCount:$topicCount, targetMsgsPerSec:$targetMsgsPerSec} + $common')"
    save_meta "$iter_dir" "$(tool_version "$iter_dir/result.json")" "$iter_params"

    msg_loss=0
    if ! msg_loss="$(index_from_result_json "$iter_dir/result.json" "$iter_dir" scalability "participants-$n")"; then
        echo "  WARNING: no result.json for participants=$n - the run produced nothing." >&2
        sweep_had_failure=true
        continue
    fi

    if [ "$tool_exit" -ne 0 ]; then
        echo "  WARNING: dds_bench exited with code $tool_exit at participants=$n - likely this environment's discovery/participant ceiling (see the caution in this script's header)." >&2
        sweep_had_failure=true
    fi
    echo "  msg_loss=$msg_loss"
    if [ "${msg_loss:-0}" -gt 0 ] && loss_is_failure; then sweep_had_failure=true; fi
done

if [ "$sweep_had_failure" = true ]; then
    echo
    echo "Done with problems - at least one participants=<N> iteration failed. Results in: $sweep_run" >&2
    exit 1
fi
echo
echo "Done. Results in: $sweep_run"
