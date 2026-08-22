#!/usr/bin/env bash
# bench-scalability.sh - connection / subject scalability sweep.
#
# Loops the pub/sub throughput pattern over a range of client (connection) counts, and
# optionally exercises many-subjects fan-out via --multisubject instead of (or in
# addition to) raw connection count.
#
# Caution: very high --connection-counts values open that many concurrent long-lived TCP
# connections into the container, and this project's original Windows + Docker Desktop
# environment had a much lower practical ceiling than "a few thousand" might suggest.
# CONFIRMED BY ACTUAL MEASUREMENT there (TODO.md #5): 1 and 10 unthrottled concurrent pub
# clients completed cleanly, but 50 and 100 both failed every single client with
# "flushing: nats: timeout". Passing --target-msgs-per-sec to pace the burst may push
# that ceiling higher (untested) - try that before assuming raw connection count alone is
# the limiting factor. This may differ on a real Linux host; re-measure there.
#
# Usage examples:
#   ./scripts/bench-scalability.sh
#   ./scripts/bench-scalability.sh --connection-counts 1,10,50,100
#   ./scripts/bench-scalability.sh --use-multi-subject --multi-subject-max 100
#   ./scripts/bench-scalability.sh --target-msgs-per-sec 5000
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SUBJECT="BENCH.SCALE"
CONNECTION_COUNTS="1,5,10,25"   # conservative default (measured-safe); pass explicit
                                  # higher values yourself once you've read the caution above
MSGS_PER_CLIENT=10000
SIZE=128
TARGET_MSGS_PER_SEC=0
USE_MULTI_SUBJECT=false
MULTI_SUBJECT_MAX=100
LABEL="sweep"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --subject) SUBJECT="$2"; shift 2 ;;
        --connection-counts) CONNECTION_COUNTS="$2"; shift 2 ;;
        --msgs-per-client) MSGS_PER_CLIENT="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --use-multi-subject) USE_MULTI_SUBJECT=true; shift ;;
        --multi-subject-max) MULTI_SUBJECT_MAX="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

assert_docker_running
assert_nats_cli_installed
test_nats_server_up >/dev/null

sweep_run="$(new_run_dir scalability "$LABEL")"
echo "Sweep dir: $sweep_run"

pub_multi_subject_args=()
sub_multi_subject_args=()
if [ "$USE_MULTI_SUBJECT" = true ]; then
    pub_multi_subject_args=(--multisubject --multisubjectmax "$MULTI_SUBJECT_MAX")
    sub_multi_subject_args=(--multisubject)
fi

sweep_had_failure=false
IFS=',' read -ra COUNTS <<< "$CONNECTION_COUNTS"
for n in "${COUNTS[@]}"; do
    echo
    echo "=== clients=$n ==="
    iter_dir="$sweep_run/clients-$n"
    mkdir -p "$iter_dir"

    total_msgs=$(( MSGS_PER_CLIENT * n ))

    ( nats bench sub "$SUBJECT" --msgs "$total_msgs" --size "$SIZE" --clients "$n" \
        --server "$NATS_SERVER_URL" --no-progress --csv "$iter_dir/sub.csv" \
        "${sub_multi_subject_args[@]}" ) &
    sub_pid=$!

    sleep 2

    sleep_duration="$(convert_to_nats_sleep_duration "$TARGET_MSGS_PER_SEC" "$n" || true)"
    pub_args=("$SUBJECT" --msgs "$total_msgs" --size "$SIZE" --clients "$n" \
        --server "$NATS_SERVER_URL" --no-progress --csv "$iter_dir/pub.csv")
    pub_args+=("${pub_multi_subject_args[@]}")
    if [ -n "$sleep_duration" ]; then pub_args+=(--sleep "$sleep_duration"); fi

    pub_exit=0
    nats bench pub "${pub_args[@]}" | tee "$iter_dir/pub.summary.txt" || pub_exit=$?
    if [ "$pub_exit" -ne 0 ]; then
        echo "  WARNING: nats bench pub exited with code $pub_exit at clients=$n - likely hit this environment's connection/flush ceiling (see caution comment above)." >&2
    fi

    wait "$sub_pid" || true

    iter_params="$(jq -n \
        --arg subject "$SUBJECT" --argjson clients "$n" --argjson totalMsgs "$total_msgs" --argjson size "$SIZE" \
        --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
        --argjson useMultiSubject "$USE_MULTI_SUBJECT" --argjson multiSubjectMax "$MULTI_SUBJECT_MAX" \
        '{subject:$subject, clients:$clients, totalMsgs:$totalMsgs, size:$size, targetMsgsPerSec:$targetMsgsPerSec, useMultiSubject:$useMultiSubject, multiSubjectMax:$multiSubjectMax}')"
    save_meta "$iter_dir" "nats $(nats --version 2>/dev/null || echo unknown)" "$iter_params"

    # sub uses $n independent client subscriptions, each receiving a full copy of the
    # published stream (fan-out, not a work queue), so expected deliveries = total * $n.
    # Use $total_msgs (requested), not pub's own reported total - see bench-throughput.sh
    # for why (TODO.md #5's false-negative trap when pub fails outright).
    read -r pub_msgs pub_bytes pub_dur pub_mps pub_mbps <<< "$(parse_nats_bench_csv_aggregate "$iter_dir/pub.csv")"
    read -r sub_msgs sub_bytes sub_dur sub_mps sub_mbps <<< "$(parse_nats_bench_csv_aggregate "$iter_dir/sub.csv")"

    expected_deliveries=$(( total_msgs * n ))
    msg_loss=$(( expected_deliveries - sub_msgs ))
    if [ "$msg_loss" -lt 0 ]; then msg_loss=0; fi

    metrics="$(jq -n \
        --argjson pub_mps "$pub_mps" --argjson pub_mbps "$pub_mbps" \
        --argjson sub_mps "$sub_mps" --argjson sub_mbps "$sub_mbps" --argjson loss "$msg_loss" \
        '{pub_msgs_per_sec:$pub_mps, pub_mb_per_sec:$pub_mbps, sub_msgs_per_sec:$sub_mps, sub_mb_per_sec:$sub_mbps, msg_loss:$loss}')"
    save_result "$iter_dir" scalability "clients-$n" "$iter_params" "$metrics"

    if [ "$msg_loss" -eq 0 ]; then
        echo "  msg_loss=$msg_loss"
    else
        echo "  msg_loss=$msg_loss" >&2
    fi

    if [ "$pub_exit" -ne 0 ] || [ "$msg_loss" -gt 0 ]; then sweep_had_failure=true; fi
done

if [ "$sweep_had_failure" = true ]; then
    echo
    echo "Done with problems - at least one clients=<N> iteration failed. Results in: $sweep_run" >&2
    exit 1
fi
echo
echo "Done. Results in: $sweep_run"
