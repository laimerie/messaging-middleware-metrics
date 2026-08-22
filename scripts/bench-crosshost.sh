#!/usr/bin/env bash
# bench-crosshost.sh - publisher and subscriber in SEPARATE Docker containers, simulating
# the "Linux host A / Linux host B" scenario from TODO.md #3 (not NATS clustering - the
# server stays a single node; only the client processes are split across network
# namespaces). Optionally injects artificial network delay via --netem-delay-ms to
# approximate real inter-host latency, since same-Docker-host containers otherwise talk
# over a near-zero-latency virtual bridge (veth), not a physical NIC (see TODO.md #3).
#
# Results are retrieved via `docker cp` (docker_run_and_copy_out in common.sh), not a -v
# bind mount - this also works when `docker` points at a remote Linux host via `docker
# context` over SSH (see README.md's "Running against a real Linux host"). A bind-mount
# path resolves against the DAEMON's filesystem, not the caller's, so it silently breaks
# the moment the daemon is remote; `docker cp` does not have this problem.
#
# Usage examples:
#   ./scripts/bench-crosshost.sh
#   ./scripts/bench-crosshost.sh --netem-delay-ms 20 --label with-20ms-delay
#   ./scripts/bench-crosshost.sh --tool nats-bench --label throughput-crosshost
#
# netem-delay-ms guidance (rough, for injecting a plausible production-like RTT):
#   ~1ms    same datacenter / availability zone
#   10-30ms same region, different AZ/datacenter
#   80-150ms cross-continent / intercontinental
#
# --target-msgs-per-sec / --duration-sec: for --tool latency-oneway, the underlying C++
# tool has no unthrottled-burst mode (see TODO.md #4), so --target-msgs-per-sec must be
# > 0 there and --duration-sec sets how long to sustain it. For --tool nats-bench,
# --target-msgs-per-sec keeps its original meaning (0 = unthrottled saturation test,
# matching bench-throughput.sh) and --duration-sec is unused (driven by --msgs instead).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

TOOL="latency-oneway"
SUBJECT="BENCH.CROSSHOST"
MSGS=20000                    # --tool nats-bench only
TARGET_MSGS_PER_SEC=0         # --tool latency-oneway: 0 -> defaults to 1000 below. --tool nats-bench: 0 = unthrottled
DURATION_SEC=10               # --tool latency-oneway only
SIZE=128
NETEM_DELAY_MS=0
LABEL="default"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tool) TOOL="$2"; shift 2 ;;
        --subject) SUBJECT="$2"; shift 2 ;;
        --msgs) MSGS="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --duration-sec) DURATION_SEC="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --netem-delay-ms) NETEM_DELAY_MS="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ "$TOOL" != "latency-oneway" ] && [ "$TOOL" != "nats-bench" ]; then
    echo "ERROR: --tool must be 'latency-oneway' or 'nats-bench' (got '$TOOL')" >&2
    exit 1
fi

if [ "$TOOL" = "latency-oneway" ] && [ "${TARGET_MSGS_PER_SEC%.*}" -le 0 ] 2>/dev/null; then
    # --target-msgs-per-sec's default (0) means "unthrottled" for --tool nats-bench, but
    # the latency-oneway tool has no unthrottled-burst mode - default to a reasonable
    # rate here instead of failing on a bare invocation.
    TARGET_MSGS_PER_SEC=1000
    echo "No --target-msgs-per-sec given for --tool latency-oneway; defaulting to 1000/s."
fi

assert_docker_running
test_nats_server_up >/dev/null

run="$(new_run_dir crosshost "$LABEL")"
echo "Run dir: $run"
if [ "$TOOL" = "latency-oneway" ]; then
    echo "tool=$TOOL subject=$SUBJECT size=$SIZE rate=${TARGET_MSGS_PER_SEC}/s duration=${DURATION_SEC}s netemDelayMs=$NETEM_DELAY_MS"
else
    echo "tool=$TOOL subject=$SUBJECT size=$SIZE msgs=$MSGS targetMsgsPerSec=$TARGET_MSGS_PER_SEC netemDelayMs=$NETEM_DELAY_MS"
fi

cd "$PROJECT_ROOT"
echo "Building latency-tool image (cached after first run)..."
docker compose build latency-tool

pub_exit=0
msg_loss=0

if [ "$TOOL" = "latency-oneway" ]; then
    # Separate subfolders: both pub and sub write their own result.json - sharing one
    # destination would let one overwrite the other's file.
    mkdir -p "$run/sub" "$run/pub"

    # pub and sub must be given the SAME --rate/--duration-sec so both sides derive the
    # same expected message count internally (see tools/latency_oneway/main.cpp).
    sub_timeout=$(( DURATION_SEC + 40 ))
    ( DOCKER_RUN_TIMEOUT="$sub_timeout" docker_run_and_copy_out "$run/sub" \
        latency-tool latency_oneway --mode sub --subject "$SUBJECT" \
        --rate "$TARGET_MSGS_PER_SEC" --duration-sec "$DURATION_SEC" --size "$SIZE" \
        --server "nats://nats:4222" --out /out ) &
    sub_pid=$!

    sleep 2

    docker_run_and_copy_out "$run/pub" -e "NETEM_DELAY_MS=$NETEM_DELAY_MS" \
        latency-tool latency_oneway --mode pub --subject "$SUBJECT" \
        --rate "$TARGET_MSGS_PER_SEC" --duration-sec "$DURATION_SEC" --size "$SIZE" \
        --server "nats://nats:4222" --out /out || pub_exit=$?

    wait "$sub_pid" || true

    if [ -f "$run/sub/result.json" ]; then
        loss="$(jq -r '.msg_loss // empty' "$run/sub/result.json")"
        msg_loss="${loss:-0}"
        commonParams="$(jq -n \
            --arg tool "$TOOL" --arg subject "$SUBJECT" --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
            --argjson durationSec "$DURATION_SEC" --argjson size "$SIZE" --argjson netemDelayMs "$NETEM_DELAY_MS" \
            '{tool:$tool, subject:$subject, targetMsgsPerSec:$targetMsgsPerSec, durationSec:$durationSec, size:$size, netemDelayMs:$netemDelayMs}')"
        save_meta "$run" "latency_oneway --mode pub/sub (CentOS 7 / gcc 11 / C++17, nats.c)" "$commonParams"

        p50="$(jq -r '.metrics.latency_us.p50 // empty' "$run/sub/result.json")"
        p99="$(jq -r '.metrics.latency_us.p99 // empty' "$run/sub/result.json")"
        metrics="$(jq -n --argjson p50 "${p50:-null}" --argjson p99 "${p99:-null}" --argjson loss "$msg_loss" \
            '{p50_latency_us:$p50, p99_latency_us:$p99, msg_loss:$loss}')"
        add_run_index_entry "$run" crosshost "$LABEL" "$metrics"
    else
        echo "Warning: could not read sub/result.json - skipping run-index.csv entry." >&2
        msg_loss=$(( TARGET_MSGS_PER_SEC * DURATION_SEC ))
    fi
else
    # nats-bench: plain nats CLI pub/sub, each in its own container. Both write into the
    # same $run destination directly (filenames differ: sub.csv vs pub.csv).
    sleep_duration="$(convert_to_nats_sleep_duration "$TARGET_MSGS_PER_SEC" 1 || true)"

    ( DOCKER_RUN_TIMEOUT=60 docker_run_and_copy_out "$run" \
        latency-tool nats bench sub "$SUBJECT" --msgs "$MSGS" --size "$SIZE" \
        --server "nats://nats:4222" --no-progress --csv /out/sub.csv ) &
    sub_pid=$!

    sleep 2

    pub_args=(latency-tool nats bench pub "$SUBJECT" --msgs "$MSGS" --size "$SIZE" \
        --server "nats://nats:4222" --no-progress --csv /out/pub.csv)
    if [ -n "$sleep_duration" ]; then pub_args+=(--sleep "$sleep_duration"); fi
    docker_run_and_copy_out "$run" -e "NETEM_DELAY_MS=$NETEM_DELAY_MS" "${pub_args[@]}" || pub_exit=$?

    wait "$sub_pid" || true

    commonParams="$(jq -n \
        --arg tool "$TOOL" --arg subject "$SUBJECT" --argjson msgs "$MSGS" --argjson size "$SIZE" \
        --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" --argjson netemDelayMs "$NETEM_DELAY_MS" \
        '{tool:$tool, subject:$subject, msgs:$msgs, size:$size, targetMsgsPerSec:$targetMsgsPerSec, netemDelayMs:$netemDelayMs}')"
    save_meta "$run" "nats $(nats --version 2>/dev/null || echo unknown)" "$commonParams"

    read -r pub_msgs pub_bytes pub_dur pub_mps pub_mbps <<< "$(parse_nats_bench_csv_aggregate "$run/pub.csv")"
    read -r sub_msgs sub_bytes sub_dur sub_mps sub_mbps <<< "$(parse_nats_bench_csv_aggregate "$run/sub.csv")"
    # Single sub instance here (not many) - expected = requested $MSGS, not pub's own
    # reported total (see TODO.md #5 for why the latter is a false-negative trap).
    msg_loss=$(( MSGS - sub_msgs ))
    if [ "$msg_loss" -lt 0 ]; then msg_loss=0; fi

    metrics="$(jq -n \
        --argjson pub_mps "$pub_mps" --argjson pub_mbps "$pub_mbps" \
        --argjson sub_mps "$sub_mps" --argjson sub_mbps "$sub_mbps" --argjson loss "$msg_loss" \
        '{pub_msgs_per_sec:$pub_mps, pub_mb_per_sec:$pub_mbps, sub_msgs_per_sec:$sub_mps, sub_mb_per_sec:$sub_mbps, msg_loss:$loss}')"
    save_result "$run" crosshost "$LABEL" "$commonParams" "$metrics"
fi

if [ "$pub_exit" -ne 0 ] || [ "$msg_loss" -gt 0 ]; then
    echo
    echo "Done with problems. Results in: $run (pub_exit_code=$pub_exit, msg_loss=$msg_loss)" >&2
    exit 1
fi
echo
echo "Done. Results in: $run (msg_loss=$msg_loss)"
