#!/usr/bin/env bash
# bench-latency.sh - latency measurement (HDR percentiles) via NATS request/reply.
#
# Uses `nats bench service serve` (responder) + `nats bench service request` (requester),
# which is what reports the HDR percentile table (10/50/75/90/99/99.9/99.99/...).
#
# Note: the CLI's printed summary does not include an exact p95 row (nearest are 90/99).
# If exact p95/p99.something is required, compute it from the raw --csv sample data -
# that's why --csv capture is mandatory here, not just the printed summary text.
#
# This measures ROUND-TRIP time (RTT), not one-way publisher->subscriber latency - see
# bench-latency-oneway.sh for that (TODO.md #4).
#
# Usage examples:
#   ./scripts/bench-latency.sh
#   ./scripts/bench-latency.sh --request-clients 10 --label 10-clients
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

SUBJECT="BENCH.LATENCY"
MSGS=10000
SIZE=128
SERVE_CLIENTS=1
REQUEST_CLIENTS=1
LABEL="default"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --subject) SUBJECT="$2"; shift 2 ;;
        --msgs) MSGS="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --serve-clients) SERVE_CLIENTS="$2"; shift 2 ;;
        --request-clients) REQUEST_CLIENTS="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

assert_docker_running
assert_nats_cli_installed
test_nats_server_up >/dev/null

run="$(new_run_dir latency "$LABEL")"
echo "Run dir: $run"
echo "subject=$SUBJECT msgs=$MSGS size=$SIZE serveClients=$SERVE_CLIENTS requestClients=$REQUEST_CLIENTS"

( nats bench service serve "$SUBJECT" --clients "$SERVE_CLIENTS" --server "$NATS_SERVER_URL" --no-progress ) &
serve_pid=$!

sleep 2

nats bench service request "$SUBJECT" --msgs "$MSGS" --size "$SIZE" --clients "$REQUEST_CLIENTS" \
    --server "$NATS_SERVER_URL" --no-progress --csv "$run/request.csv" \
    | tee "$run/request.summary.txt"

kill "$serve_pid" >/dev/null 2>&1 || true
wait "$serve_pid" 2>/dev/null || true

commonParams="$(jq -n \
    --arg subject "$SUBJECT" --argjson msgs "$MSGS" --argjson size "$SIZE" \
    --argjson serveClients "$SERVE_CLIENTS" --argjson requestClients "$REQUEST_CLIENTS" \
    '{subject:$subject, msgs:$msgs, size:$size, serveClients:$serveClients, requestClients:$requestClients}')"
save_meta "$run" "nats $(nats --version 2>/dev/null || echo unknown)" "$commonParams"

# result.json / run-index.csv (TODO.md #6). Note this is round-trip time (RTT), not the
# one-way latency bench-latency-oneway.sh measures - the p50/p99 recorded here are about
# twice the true one-way figure, not directly comparable to the "latency" category rows
# produced by that script. Kept separate (label suffix "-rtt") rather than merged.
p50=""
p99=""
if [ -f "$run/request.csv" ]; then
    row="$(tail -n +2 "$run/request.csv" | head -n 1)"
    if [ -n "$row" ]; then
        # Columns (nats bench --csv convention): ...,MinLatencyMicroSecs(8),
        # AvgLatencyMicroSecs(9), MaxLatencyMicroSecs(10), P50LatencyMicroSecs(11),
        # P90LatencyMicroSecs(12), P99LatencyMicroSecs(13), P99.9LatencyMicroSecs(14), ...
        p50="$(echo "$row" | awk -F, '{print $11}')"
        p99="$(echo "$row" | awk -F, '{print $13}')"
    fi
fi
read -r req_msgs req_bytes req_dur req_mps req_mbps <<< "$(parse_nats_bench_csv_aggregate "$run/request.csv")"
msg_loss=$(( MSGS - req_msgs ))
if [ "$msg_loss" -lt 0 ]; then msg_loss=0; fi

metrics_args=(--argjson loss "$msg_loss")
metrics_filter='{msg_loss:$loss}'
if [ -n "$p50" ]; then metrics_args+=(--argjson p50 "$p50"); metrics_filter='{p50_latency_us:$p50} + '"$metrics_filter"; fi
if [ -n "$p99" ]; then metrics_args+=(--argjson p99 "$p99"); metrics_filter='{p99_latency_us:$p99} + '"$metrics_filter"; fi
metrics="$(jq -n "${metrics_args[@]}" "$metrics_filter")"
save_result "$run" latency "${LABEL}-rtt" "$commonParams" "$metrics"

echo
echo "Done. Results in: $run"
