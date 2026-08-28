#!/usr/bin/env bash
# bench-scalability.sh - subscriber / stream scalability sweep.
#
# The third variant of this sweep in the repo, and the axis differs again because the
# architectures do:
#
#   nats/       CONNECTION count. N clients each hold a TCP connection to one broker, and
#               the broker writes N copies. The sweep measures the broker's connection
#               handling.
#   fast-dds/   PARTICIPANT count. No broker, so each subscriber is an independent RTPS peer
#               that the publisher must discover, match and unicast to individually.
#               Measured there: publisher throughput collapsed 110k -> 1.1k msgs/s from 1 to
#               25 participants, with zero loss - pure peer-to-peer fan-out back-pressure.
#   aeron/      SUBSCRIBER-CLIENT count, and this is the interesting one. N subscribers on
#               ONE HOST share a single media driver, and therefore a single copy of the
#               data: the driver receives each message once into a term buffer and every
#               subscriber reads that same buffer at its own position. There is no per-
#               subscriber network cost at all.
#
# The prediction that makes this sweep worth running: Aeron should stay roughly FLAT where
# NATS degrades linearly and Fast DDS degrades sharply, and the limit should turn out to be
# CPU (one poll thread per subscriber) rather than network or discovery. Confirming or
# refuting that on real hardware is the single most informative result this project can
# produce - see TODO.md #1.
#
# CPU CAUTION, and it is not a footnote here: with the default --poll-idle busy, every
# subscriber busy-spins a core, and so do the media driver's three threads under the default
# --driver-idle noop. At --sub-count 25 that is 28 spinning threads. Past the core count
# they starve each other AND the driver, which does not merely slow the result down - the
# clients can decide the driver is unresponsive and abort the run. aeron_bench warns when it
# sees this. Pass --poll-idle yield for the wide end of a sweep.
#
# Two axes, usable together or separately:
#   --sub-counts       N subscriber clients (default sweep 1,5,10,25)
#   --stream-count     T streams, each with its own subscription per client. Aeron's
#                      analogue of NATS's --multisubject and Fast DDS's --topic-count. Note
#                      that T streams over one UDP endpoint still share ONE socket and one
#                      channel endpoint in the driver, unlike DDS's per-topic locators.
#
# Usage examples:
#   ./scripts/bench-scalability.sh
#   ./scripts/bench-scalability.sh --sub-counts 1,10,50 --poll-idle yield
#   ./scripts/bench-scalability.sh --stream-count 100
#   ./scripts/bench-scalability.sh --target-msgs-per-sec 5000
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SUB_COUNTS="1,5,10,25"
MSGS_PER_SUB=10000
SIZE=128
STREAM_COUNT=1
TARGET_MSGS_PER_SEC=0
LABEL="sweep"

while [[ $# -gt 0 ]]; do
    if parse_common_arg "$1" "${2:-}"; then shift "$COMMON_ARG_CONSUMED"; continue; fi
    case "$1" in
        --sub-counts) SUB_COUNTS="$2"; shift 2 ;;
        --msgs-per-sub) MSGS_PER_SUB="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --stream-count) STREAM_COUNT="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

assert_docker_running
ensure_image_built

sweep_run="$(new_run_dir scalability "$LABEL")"
echo "Sweep dir: $sweep_run"
echo "subCounts=$SUB_COUNTS msgsPerSub=$MSGS_PER_SUB size=$SIZE streamCount=$STREAM_COUNT pollIdle=$POLL_IDLE driverIdle=$DRIVER_IDLE"

mapfile -t common_args < <(aeron_common_args)
mapfile -t driver_env < <(driver_env_args)

sweep_had_failure=false
# A comma-separated string split manually - no implicit type coercion to fight, unlike the
# PowerShell array-parameter trap recorded in nats/TODO.md #2.
IFS=',' read -ra COUNTS <<< "$SUB_COUNTS"
for n in "${COUNTS[@]}"; do
    echo
    echo "=== subscribers=$n ==="
    iter_dir="$sweep_run/subscribers-$n"
    mkdir -p "$iter_dir"

    # Total published messages scale with the subscriber count so each sweep point moves a
    # comparable amount of data through the driver, matching fast-dds/'s sweep shape.
    total_msgs=$(( MSGS_PER_SUB * n ))

    tool_exit=0
    docker_run_and_copy_out "$iter_dir" "${driver_env[@]}" aeron-bench aeron_bench \
        --measure throughput --mode both \
        --endpoint "$LOCAL_ENDPOINT" --stream-count "$STREAM_COUNT" \
        --msgs "$total_msgs" --size "$SIZE" \
        --sub-count "$n" --rate "$TARGET_MSGS_PER_SEC" \
        "${common_args[@]}" --out /out || tool_exit=$?

    iter_params="$(jq -n \
        --argjson subscribers "$n" --argjson totalMsgs "$total_msgs" \
        --argjson size "$SIZE" --argjson streamCount "$STREAM_COUNT" \
        --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
        --arg endpoint "$LOCAL_ENDPOINT" \
        --argjson common "$(common_params_json)" \
        '{endpoint:$endpoint, subscribers:$subscribers, totalMsgs:$totalMsgs, size:$size,
          streamCount:$streamCount, targetMsgsPerSec:$targetMsgsPerSec} + $common')"
    save_meta "$iter_dir" "$(tool_version "$iter_dir/result.json")" "$iter_params"

    msg_loss=0
    if ! msg_loss="$(index_from_result_json "$iter_dir/result.json" "$iter_dir" scalability "subscribers-$n")"; then
        echo "  WARNING: no result.json for subscribers=$n - the run produced nothing." >&2
        sweep_had_failure=true
        continue
    fi

    if [ "$tool_exit" -ne 0 ]; then
        echo "  WARNING: aeron_bench exited with code $tool_exit at subscribers=$n - likely this environment's CPU ceiling (see the caution in this script's header; try --poll-idle yield)." >&2
        sweep_had_failure=true
    fi
    echo "  msg_loss=$msg_loss"
    report_back_pressure "$iter_dir/result.json" | sed 's/^/  /'
    if [ "${msg_loss:-0}" -gt 0 ] && loss_is_failure; then sweep_had_failure=true; fi
done

if [ "$sweep_had_failure" = true ]; then
    echo
    echo "Done with problems - at least one subscribers=<N> iteration failed. Results in: $sweep_run" >&2
    exit 1
fi
echo
echo "Done. Results in: $sweep_run"
