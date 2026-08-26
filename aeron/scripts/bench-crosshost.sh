#!/usr/bin/env bash
# bench-crosshost.sh - publisher and subscriber in SEPARATE Docker containers, each running
# its OWN media driver, simulating the "Linux host A / Linux host B" scenario.
#
# This is a closer analogue of two hosts than the equivalent script in fast-dds/, and for a
# concrete reason: the media driver is duplicated. In fast-dds/ the two containers each ran
# a client of a daemonless library; here each container runs the full Aeron stack it would
# run on a real server - conductor, sender, receiver, term buffers, flow control - and the
# two drivers talk to each other over UDP. Everything on the data path is real except the
# path itself.
#
# WHAT IT STILL DOES NOT REPRODUCE: a NIC, a cable or a switch. Same-Docker-host containers
# talk over a veth pair and a Linux bridge, which is an in-kernel memcpy. Measured in
# fast-dds/, crossing the container boundary cost NOTHING (p50 70us same-process vs 68us
# cross-container). Use --netem-delay-ms to approximate a real inter-host delay, and see
# README.md before reporting any of this as a host-to-host figure.
#
# ADDRESSING. Aeron has no discovery, so both sides need addresses fixed in advance:
# compose services aeron-bench-a (subscriber/echo, 172.29.0.20) and aeron-bench-b
# (publisher/ping, 172.29.0.21) carry static IPs for exactly this. That also means this
# script is the one place where the endpoint is NOT loopback.
#
# --transport ipc is rejected here: aeron:ipc is shared memory through ONE driver's term
# buffers, and these two containers have separate drivers and separate /dev/shm. It would
# not fail loudly - each side would sit waiting for a peer that is writing into memory the
# other cannot see.
#
# Results are retrieved via `docker cp` (docker_run_and_copy_out in common.sh), not a -v
# bind mount - a bind-mount path resolves against the DAEMON's filesystem, not the caller's,
# so it silently breaks the moment `docker` points at a remote Linux host via `docker
# context` over SSH.
#
# Usage examples:
#   ./scripts/bench-crosshost.sh
#   ./scripts/bench-crosshost.sh --netem-delay-ms 20 --label with-20ms-delay
#   ./scripts/bench-crosshost.sh --measure throughput --label throughput-crosshost
#
# netem-delay-ms guidance (rough, for injecting a plausible production-like one-way delay):
#   ~1ms     same datacenter / availability zone
#   10-30ms  same region, different AZ/datacenter
#   80-150ms cross-continent / intercontinental
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

MEASURE="latency"             # latency | throughput
MSGS=20000                    # --measure throughput only
TARGET_MSGS_PER_SEC=0         # --measure latency: 0 -> defaults to 1000 below.
                              # --measure throughput: 0 = unthrottled
DURATION_SEC=10               # --measure latency only
SIZE=128
NETEM_DELAY_MS=0
LABEL="default"

while [[ $# -gt 0 ]]; do
    if parse_common_arg "$1" "${2:-}"; then shift "$COMMON_ARG_CONSUMED"; continue; fi
    case "$1" in
        --measure) MEASURE="$2"; shift 2 ;;
        --msgs) MSGS="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --duration-sec) DURATION_SEC="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --netem-delay-ms) NETEM_DELAY_MS="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ "$MEASURE" != "latency" ] && [ "$MEASURE" != "throughput" ]; then
    echo "ERROR: --measure must be 'latency' or 'throughput' (got '$MEASURE')" >&2
    exit 1
fi

if [ "$MEASURE" = "latency" ] && [ "${TARGET_MSGS_PER_SEC%.*}" -le 0 ] 2>/dev/null; then
    # 0 means "unthrottled" for --measure throughput, but there is no unthrottled latency
    # mode - default to a reasonable rate rather than failing on a bare invocation.
    TARGET_MSGS_PER_SEC=1000
    echo "No --target-msgs-per-sec given for --measure latency; defaulting to 1000/s."
fi

if [ "$TRANSPORT" = "ipc" ]; then
    echo "ERROR: --transport ipc cannot cross containers - aeron:ipc is shared memory inside ONE" >&2
    echo "       media driver, and these two containers each run their own with separate /dev/shm." >&2
    echo "       Use --transport udp here, or the same-container scripts for ipc." >&2
    exit 1
fi

assert_docker_running
ensure_image_built

run="$(new_run_dir crosshost "$LABEL")"
echo "Run dir: $run"
SUB_ENDPOINT="${CROSS_A_ADDRESS}:${CROSS_PORT}"
if [ "$MEASURE" = "latency" ]; then
    echo "measure=$MEASURE endpoint=$SUB_ENDPOINT size=$SIZE rate=${TARGET_MSGS_PER_SEC}/s duration=${DURATION_SEC}s netemDelayMs=$NETEM_DELAY_MS transport=$TRANSPORT reliable=$RELIABLE"
else
    echo "measure=$MEASURE endpoint=$SUB_ENDPOINT size=$SIZE msgs=$MSGS targetMsgsPerSec=$TARGET_MSGS_PER_SEC netemDelayMs=$NETEM_DELAY_MS transport=$TRANSPORT reliable=$RELIABLE"
fi

cd "$PROJECT_ROOT"
mapfile -t common_args < <(aeron_common_args)
mapfile -t driver_env < <(driver_env_args)

# Separate subfolders: both pub and sub write their own result.json, and sharing one
# destination would let whichever finishes second overwrite the other's file.
mkdir -p "$run/sub" "$run/pub"

# Both sides must be given the SAME rate/duration (or the same --msgs), because each derives
# the expected message count from them independently - the pub side to know how many to
# send, the sub side to know when it has them all.
if [ "$MEASURE" = "latency" ]; then
    count_args=(--rate "$TARGET_MSGS_PER_SEC" --duration-sec "$DURATION_SEC")
    sub_timeout=$(( DURATION_SEC + 90 ))
else
    count_args=(--msgs "$MSGS" --rate "$TARGET_MSGS_PER_SEC")
    sub_timeout=180
fi

# Subscriber first: it BINDS the endpoint, so until it exists the publisher's offer() has
# nowhere to go and returns NOT_CONNECTED. The publisher's own connect-wait covers the race,
# but starting the subscriber first keeps that wait short.
( DOCKER_RUN_TIMEOUT="$sub_timeout" docker_run_and_copy_out "$run/sub" \
    "${driver_env[@]}" aeron-bench-a aeron_bench --measure "$MEASURE" --mode sub \
    --endpoint "$SUB_ENDPOINT" --size "$SIZE" "${count_args[@]}" \
    "${common_args[@]}" --out /out ) &
sub_pid=$!

sleep 2

pub_exit=0
docker_run_and_copy_out "$run/pub" "${driver_env[@]}" -e "NETEM_DELAY_MS=$NETEM_DELAY_MS" \
    aeron-bench-b aeron_bench --measure "$MEASURE" --mode pub \
    --endpoint "$SUB_ENDPOINT" --size "$SIZE" "${count_args[@]}" \
    "${common_args[@]}" --out /out || pub_exit=$?

wait "$sub_pid" || true

params="$(jq -n \
    --arg measure "$MEASURE" --argjson msgs "$MSGS" \
    --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" --argjson durationSec "$DURATION_SEC" \
    --argjson size "$SIZE" --argjson netemDelayMs "$NETEM_DELAY_MS" \
    --arg endpoint "$SUB_ENDPOINT" \
    --argjson common "$(common_params_json)" \
    '{measure:$measure, endpoint:$endpoint, msgs:$msgs, targetMsgsPerSec:$targetMsgsPerSec,
      durationSec:$durationSec, size:$size, netemDelayMs:$netemDelayMs,
      topology:"two containers, two media drivers"} + $common')"
save_meta "$run" "$(tool_version "$run/sub/result.json")" "$params"

# The sub side holds every metric that matters: it is the only one that saw the messages
# arrive, so it owns both the latency distribution and the received-count/loss figure.
msg_loss=0
if ! msg_loss="$(index_from_result_json "$run/sub/result.json" "$run" crosshost "$LABEL")"; then
    echo "Warning: could not read sub/result.json - skipping run-index.csv entry." >&2
    echo "         Check that the subscriber container really got $CROSS_A_ADDRESS (the static" >&2
    echo "         address in docker-compose.yml) - Aeron cannot find a peer at any other one." >&2
    exit 1
fi

if [ "$pub_exit" -ne 0 ]; then
    echo
    echo "Done with problems: the publisher container exited with code $pub_exit. Results in: $run" >&2
    exit 1
fi
if [ "${msg_loss:-0}" -gt 0 ] && loss_is_failure; then
    echo
    echo "Done with problems: msg_loss=$msg_loss with reliable delivery in effect. Results in: $run" >&2
    exit 1
fi
echo
report_back_pressure "$run/pub/result.json"
echo "Done. Results in: $run (msg_loss=${msg_loss})"
