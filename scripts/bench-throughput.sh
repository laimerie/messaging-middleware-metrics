#!/usr/bin/env bash
# bench-throughput.sh - throughput measurement (msgs/sec, MB/sec) for NATS Core pub/sub.
#
# `nats bench sub` and `nats bench pub` are separate processes. The subscriber is started
# first (backgrounded) and given a moment to register its subscription, since NATS Core
# does not queue/persist messages published before a subscriber attaches - anything
# published too early would just be dropped and understate throughput.
#
# Usage examples:
#   ./scripts/bench-throughput.sh
#   ./scripts/bench-throughput.sh --size 16384 --label large-msg
#   ./scripts/bench-throughput.sh --pub-clients 4 --sub-clients 4 --label 4x4-clients
#   ./scripts/bench-throughput.sh --target-msgs-per-sec 5000 --label sustained-5k
#   ./scripts/bench-throughput.sh --use-multi-subject --multi-subject-max 100 --label multisubject
#
# Run this multiple times with different --size/--pub-clients/--sub-clients/--subject to
# cover a range of message sizes, publisher/subscriber counts, and subjects - each call
# gets its own timestamped results folder, nothing is overwritten.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SUBJECT="BENCH.THROUGHPUT"
MSGS=1000000
SIZE=128
PUB_CLIENTS=1
SUB_CLIENTS=1
TARGET_MSGS_PER_SEC=0   # 0 = unthrottled (max speed / saturation test)
USE_MULTI_SUBJECT=false
MULTI_SUBJECT_MAX=100
LABEL="default"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --subject) SUBJECT="$2"; shift 2 ;;
        --msgs) MSGS="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --pub-clients) PUB_CLIENTS="$2"; shift 2 ;;
        --sub-clients) SUB_CLIENTS="$2"; shift 2 ;;
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

run="$(new_run_dir throughput "$LABEL")"
echo "Run dir: $run"
echo "subject=$SUBJECT msgs=$MSGS size=$SIZE pubClients=$PUB_CLIENTS subClients=$SUB_CLIENTS targetMsgsPerSec=$TARGET_MSGS_PER_SEC multiSubject=$USE_MULTI_SUBJECT"

# --multisubject must be passed to BOTH pub and sub: pub spreads messages across subjects
# derived from the base subject, and sub needs the same flag to subscribe to the matching
# wildcard pattern instead of just the literal base subject (omitting it on sub silently
# drops every message - see the equivalent note in bench-scalability.sh).
# NOTE: `nats bench sub` only accepts --multisubject (no --multisubjectmax - that flag is
# pub-only; passing it to sub makes the command fail with a usage error and exit).
pub_multi_subject_args=()
sub_multi_subject_args=()
if [ "$USE_MULTI_SUBJECT" = true ]; then
    pub_multi_subject_args=(--multisubject --multisubjectmax "$MULTI_SUBJECT_MAX")
    sub_multi_subject_args=(--multisubject)
fi

( nats bench sub "$SUBJECT" --msgs "$MSGS" --size "$SIZE" --clients "$SUB_CLIENTS" \
    --server "$NATS_SERVER_URL" --no-progress --csv "$run/sub.csv" \
    "${sub_multi_subject_args[@]}" ) &
sub_pid=$!

sleep 2

sleep_duration="$(convert_to_nats_sleep_duration "$TARGET_MSGS_PER_SEC" "$PUB_CLIENTS" || true)"
pub_args=("$SUBJECT" --msgs "$MSGS" --size "$SIZE" --clients "$PUB_CLIENTS" \
    --server "$NATS_SERVER_URL" --no-progress --csv "$run/pub.csv")
pub_args+=("${pub_multi_subject_args[@]}")
if [ -n "$sleep_duration" ]; then pub_args+=(--sleep "$sleep_duration"); fi

pub_exit=0
nats bench pub "${pub_args[@]}" | tee "$run/pub.summary.txt" || pub_exit=$?
if [ "$pub_exit" -ne 0 ]; then
    echo "WARNING: nats bench pub exited with code $pub_exit - results below are likely incomplete (e.g. too many concurrent connections for this environment)." >&2
fi

wait "$sub_pid" || true

commonParams="$(jq -n \
    --arg subject "$SUBJECT" --argjson msgs "$MSGS" --argjson size "$SIZE" \
    --argjson pubClients "$PUB_CLIENTS" --argjson subClients "$SUB_CLIENTS" \
    --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
    --argjson useMultiSubject "$USE_MULTI_SUBJECT" --argjson multiSubjectMax "$MULTI_SUBJECT_MAX" \
    '{subject:$subject, msgs:$msgs, size:$size, pubClients:$pubClients, subClients:$subClients, targetMsgsPerSec:$targetMsgsPerSec, useMultiSubject:$useMultiSubject, multiSubjectMax:$multiSubjectMax}')"
save_meta "$run" "nats $(nats --version 2>/dev/null || echo unknown)" "$commonParams"

# result.json / run-index.csv (TODO.md #6): each independent subscriber client receives a
# full copy of the published stream (fan-out, not a work queue - confirmed empirically),
# so expected deliveries = total published * SUB_CLIENTS.
# IMPORTANT: use $MSGS (what we asked pub to send), NOT pub's own reported total, as the
# "total published" figure - if `nats bench pub` fails outright, pub.csv is empty and its
# reported total is 0, which would make expected deliveries 0 and silently report
# msg_loss=0 even though nothing was delivered (see TODO.md #5).
read -r pub_msgs pub_bytes pub_dur pub_mps pub_mbps <<< "$(parse_nats_bench_csv_aggregate "$run/pub.csv")"
read -r sub_msgs sub_bytes sub_dur sub_mps sub_mbps <<< "$(parse_nats_bench_csv_aggregate "$run/sub.csv")"

expected_deliveries=$(( MSGS * SUB_CLIENTS ))
msg_loss=$(( expected_deliveries - sub_msgs ))
if [ "$msg_loss" -lt 0 ]; then msg_loss=0; fi

metrics="$(jq -n \
    --argjson pub_mps "$pub_mps" --argjson pub_mbps "$pub_mbps" \
    --argjson sub_mps "$sub_mps" --argjson sub_mbps "$sub_mbps" --argjson loss "$msg_loss" \
    '{pub_msgs_per_sec:$pub_mps, pub_mb_per_sec:$pub_mbps, sub_msgs_per_sec:$sub_mps, sub_mb_per_sec:$sub_mbps, msg_loss:$loss}')"
save_result "$run" throughput "$LABEL" "$commonParams" "$metrics"

if [ "$pub_exit" -ne 0 ] || [ "$msg_loss" -gt 0 ]; then
    echo
    echo "Done with problems. Results in: $run (pub_exit_code=$pub_exit, msg_loss=$msg_loss)" >&2
    exit 1
fi
echo
echo "Done. Results in: $run (msg_loss=$msg_loss)"
