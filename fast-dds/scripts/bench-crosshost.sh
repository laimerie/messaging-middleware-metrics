#!/usr/bin/env bash
# bench-crosshost.sh - publisher and subscriber in SEPARATE Docker containers, simulating
# the "Linux host A / Linux host B" scenario (see nats/TODO.md #3 for where this idea came
# from). Optionally injects artificial network delay via --netem-delay-ms to approximate
# real inter-host latency, since same-Docker-host containers otherwise talk over a
# near-zero-latency virtual bridge (veth), not a physical NIC.
#
# This matters more for Fast DDS than it did for NATS. With a broker, splitting the clients
# only changed where the client processes ran - the traffic still went client -> broker ->
# client either way. Fast DDS is peer-to-peer, so splitting the roles across containers
# changes the actual data path, and it is the only configuration in this project that
# exercises real cross-namespace RTPS traffic end to end.
#
# DISCOVERY, and why this script defaults differently from the others: SIMPLE discovery
# relies on UDP multicast, and multicast across a Docker bridge network is unreliable
# enough (IGMP snooping, br_netfilter, host kernel configuration) that a failure here says
# more about Docker than about Fast DDS. This script therefore defaults to
# --discovery server, which uses unicast to a fixed rendezvous address and is deterministic.
# Pass --discovery simple to deliberately test whether multicast works in your environment.
#
# Results are retrieved via `docker cp` (docker_run_and_copy_out in common.sh), not a -v
# bind mount - a bind-mount path resolves against the DAEMON's filesystem, not the caller's,
# so it silently breaks the moment `docker` points at a remote Linux host via `docker
# context` over SSH. `docker cp` does not have this problem.
#
# Usage examples:
#   ./scripts/bench-crosshost.sh
#   ./scripts/bench-crosshost.sh --netem-delay-ms 20 --label with-20ms-delay
#   ./scripts/bench-crosshost.sh --measure throughput --label throughput-crosshost
#   ./scripts/bench-crosshost.sh --discovery simple --label multicast-check
#
# netem-delay-ms guidance (rough, for injecting a plausible production-like one-way delay):
#   ~1ms     same datacenter / availability zone
#   10-30ms  same region, different AZ/datacenter
#   80-150ms cross-continent / intercontinental
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# See the header: unicast Discovery Server is the deterministic choice across containers.
DISCOVERY="server"

MEASURE="latency"             # latency | throughput
TOPIC="BENCH_CROSSHOST"
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
        --topic) TOPIC="$2"; shift 2 ;;
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

if [ "$TRANSPORT" = "shm" ]; then
    echo "ERROR: --transport shm cannot work across containers - each container gets its own /dev/shm." >&2
    echo "       Use --transport udp here, or run the same-host scripts (bench-latency-oneway.sh etc.) for SHM." >&2
    exit 1
fi

assert_docker_running
ensure_image_built
ensure_discovery_server

run="$(new_run_dir crosshost "$LABEL")"
echo "Run dir: $run"
if [ "$MEASURE" = "latency" ]; then
    echo "measure=$MEASURE topic=$TOPIC size=$SIZE rate=${TARGET_MSGS_PER_SEC}/s duration=${DURATION_SEC}s netemDelayMs=$NETEM_DELAY_MS discovery=$DISCOVERY reliability=$RELIABILITY"
else
    echo "measure=$MEASURE topic=$TOPIC size=$SIZE msgs=$MSGS targetMsgsPerSec=$TARGET_MSGS_PER_SEC netemDelayMs=$NETEM_DELAY_MS discovery=$DISCOVERY reliability=$RELIABILITY"
fi

cd "$PROJECT_ROOT"
mapfile -t common_args < <(dds_common_args)

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

# Subscriber first: it must be up and matched before the publisher starts, since
# BEST_EFFORT + VOLATILE discards anything written before a reader is matched. The
# publisher's own match-wait covers the race, but starting the subscriber first keeps that
# wait short.
( DOCKER_RUN_TIMEOUT="$sub_timeout" docker_run_and_copy_out "$run/sub" \
    dds-bench dds_bench --measure "$MEASURE" --mode sub \
    --topic "$TOPIC" --size "$SIZE" "${count_args[@]}" \
    "${common_args[@]}" --out /out ) &
sub_pid=$!

sleep 2

pub_exit=0
docker_run_and_copy_out "$run/pub" -e "NETEM_DELAY_MS=$NETEM_DELAY_MS" \
    dds-bench dds_bench --measure "$MEASURE" --mode pub \
    --topic "$TOPIC" --size "$SIZE" "${count_args[@]}" \
    "${common_args[@]}" --out /out || pub_exit=$?

wait "$sub_pid" || true

params="$(jq -n \
    --arg measure "$MEASURE" --arg topic "$TOPIC" --argjson msgs "$MSGS" \
    --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" --argjson durationSec "$DURATION_SEC" \
    --argjson size "$SIZE" --argjson netemDelayMs "$NETEM_DELAY_MS" \
    --argjson common "$(common_params_json)" \
    '{measure:$measure, topic:$topic, msgs:$msgs, targetMsgsPerSec:$targetMsgsPerSec,
      durationSec:$durationSec, size:$size, netemDelayMs:$netemDelayMs} + $common')"
save_meta "$run" "$(tool_version "$run/sub/result.json")" "$params"

# The sub side holds every metric that matters: it is the only one that saw the messages
# arrive, so it owns both the latency distribution and the received-count/loss figure.
msg_loss=0
if ! msg_loss="$(index_from_result_json "$run/sub/result.json" "$run" crosshost "$LABEL")"; then
    echo "Warning: could not read sub/result.json - skipping run-index.csv entry." >&2
    echo "         With --discovery simple this usually means multicast discovery never" >&2
    echo "         completed across the Docker bridge; retry with --discovery server." >&2
    exit 1
fi

if [ "$pub_exit" -ne 0 ]; then
    echo
    echo "Done with problems: the publisher container exited with code $pub_exit. Results in: $run" >&2
    exit 1
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
