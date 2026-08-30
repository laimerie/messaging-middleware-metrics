#!/usr/bin/env bash
# bench-oneway-2host-native.sh - one-way latency with the server and publisher on host A
# and the subscriber on host B. Both hosts run the binaries from package-native.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

ROLE=""
SERVER_URL=""
MONITOR_URL=""
SUBJECT="BENCH.LATENCY.ONEWAY"
TARGET_MSGS_PER_SEC=1000
DURATION_SEC=10
SIZE=128
TIMEOUT_SEC=""
SUBSCRIPTION_TIMEOUT_SEC=120
SUBSCRIPTION_POLL_INTERVAL_SEC=0.2
CLOCK="realtime"
PACING="auto"
LABEL="2host-native"
NATS_SERVER_BIN="${NATS_SERVER_BIN:-$PKG_ROOT/bin/nats-server}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --server-url) SERVER_URL="$2"; shift 2 ;;
        --monitor-url) MONITOR_URL="$2"; shift 2 ;;
        --subject) SUBJECT="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --duration-sec) DURATION_SEC="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --timeout-sec) TIMEOUT_SEC="$2"; shift 2 ;;
        --subscription-timeout-sec) SUBSCRIPTION_TIMEOUT_SEC="$2"; shift 2 ;;
        --subscription-poll-interval-sec) SUBSCRIPTION_POLL_INTERVAL_SEC="$2"; shift 2 ;;
        --clock) CLOCK="$2"; shift 2 ;;
        --pacing) PACING="$2"; shift 2 ;;
        --nats-server) NATS_SERVER_BIN="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ "$ROLE" != "pub" && "$ROLE" != "sub" ]]; then
    echo "ERROR: --role must be 'pub' or 'sub'. Start sub first, then pub." >&2
    exit 1
fi
if [[ -z "$SERVER_URL" ]]; then
    echo "ERROR: --server-url is required (use the publisher host address, e.g. nats://10.0.0.1:4222)." >&2
    exit 1
fi
if [[ -z "$MONITOR_URL" ]]; then
    server_host="${SERVER_URL#nats://}"
    server_host="${server_host%%:*}"
    MONITOR_URL="http://${server_host}:8222"
fi
if [[ "$ROLE" == "pub" && ! -x "$NATS_SERVER_BIN" ]]; then
    echo "ERROR: nats-server was not found at $NATS_SERVER_BIN." >&2
    exit 1
fi
if ! awk -v v="$TARGET_MSGS_PER_SEC" 'BEGIN { exit (v+0 > 0) ? 0 : 1 }'; then
    echo "ERROR: --target-msgs-per-sec must be > 0." >&2
    exit 1
fi
if [[ "$CLOCK" != "realtime" && "$CLOCK" != "monotonic" ]]; then
    echo "ERROR: --clock must be 'realtime' or 'monotonic'." >&2
    exit 1
fi
if ! awk -v v="$SUBSCRIPTION_TIMEOUT_SEC" 'BEGIN { exit (v+0 > 0) ? 0 : 1 }'; then
    echo "ERROR: --subscription-timeout-sec must be > 0." >&2
    exit 1
fi
if ! awk -v v="$SUBSCRIPTION_POLL_INTERVAL_SEC" 'BEGIN { exit (v+0 > 0) ? 0 : 1 }'; then
    echo "ERROR: --subscription-poll-interval-sec must be > 0." >&2
    exit 1
fi

tool="$PKG_ROOT/bin/latency_oneway"
[[ -x "$tool" ]] || { echo "ERROR: latency_oneway was not found at $tool." >&2; exit 1; }
export LD_LIBRARY_PATH="$PKG_ROOT/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
run="$(new_run_dir crosshost "$LABEL")"
server_pid=""
cleanup() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

args=(--mode "$ROLE" --subject "$SUBJECT" --rate "$TARGET_MSGS_PER_SEC" \
      --duration-sec "$DURATION_SEC" --size "$SIZE" --server "$SERVER_URL" \
      --clock "$CLOCK" --pacing "$PACING" --out "$run")
if [[ -n "$TIMEOUT_SEC" ]]; then args+=(--timeout-sec "$TIMEOUT_SEC"); fi

if [[ "$ROLE" == "pub" ]]; then
    "$NATS_SERVER_BIN" -a 0.0.0.0 -p 4222 -m 8222 >"$run/nats-server.log" 2>&1 &
    server_pid=$!
    for _ in $(seq 1 100); do
        curl -fsS -m 1 "$MONITOR_URL/varz" >/dev/null 2>&1 && break
        kill -0 "$server_pid" 2>/dev/null || { cat "$run/nats-server.log" >&2; exit 1; }
        sleep 0.1
    done
    curl -fsS -m 2 "$MONITOR_URL/varz" >/dev/null
    echo "Waiting for subscription of subject '$SUBJECT' at $MONITOR_URL ..."
    connz_response="$run/connz.json"
    subscription_ready=0
    poll_attempts="$(awk -v timeout="$SUBSCRIPTION_TIMEOUT_SEC" -v interval="$SUBSCRIPTION_POLL_INTERVAL_SEC" \
        'BEGIN { attempts = int(timeout / interval); if (attempts < 1) attempts = 1; print attempts }')"
    for ((attempt = 1; attempt <= poll_attempts; attempt++)); do
        kill -0 "$server_pid" 2>/dev/null || {
            echo "ERROR: NATS server exited while waiting for subscription readiness." >&2
            cat "$run/nats-server.log" >&2
            exit 1
        }
        if curl -fsS -m 2 "$MONITOR_URL/connz?subs=1" >"$connz_response" 2>/dev/null && \
            jq -e --arg subject "$SUBJECT" \
                'type == "object" and any(.connections[]?.subscriptions_list[]?; . == $subject)' \
                "$connz_response" >/dev/null 2>&1; then
            subscription_ready=1
            break
        fi
        sleep "$SUBSCRIPTION_POLL_INTERVAL_SEC"
    done
    rm -f "$connz_response"
    if [[ "$subscription_ready" -ne 1 ]]; then
        echo "ERROR: subscription for subject '$SUBJECT' was not confirmed at $MONITOR_URL within ${SUBSCRIPTION_TIMEOUT_SEC}s; publisher was not started." >&2
        exit 1
    fi
    echo "Subscription ready for subject '$SUBJECT'. Starting publisher."
else
    echo "Waiting for NATS server at $SERVER_URL ..."
    for _ in $(seq 1 120); do
        curl -fsS -m 1 "$MONITOR_URL/varz" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -fsS -m 2 "$MONITOR_URL/varz" >/dev/null || {
        echo "ERROR: NATS server did not become reachable at $MONITOR_URL within 120s." >&2
        exit 1
    }
fi

echo "role=$ROLE server=$SERVER_URL subject=$SUBJECT rate=${TARGET_MSGS_PER_SEC}/s duration=${DURATION_SEC}s clock=$CLOCK"
"$tool" "${args[@]}"

if [[ "$ROLE" == "sub" && -f "$run/result.json" ]]; then
    p50="$(jq -r '.metrics.latency_us.p50 // empty' "$run/result.json")"
    p99="$(jq -r '.metrics.latency_us.p99 // empty' "$run/result.json")"
    loss="$(jq -r '.metrics.msg_loss // empty' "$run/result.json")"
    metrics="$(jq -n --argjson p50 "${p50:-null}" --argjson p99 "${p99:-null}" --argjson loss "${loss:-null}" \
        '{p50_latency_us:$p50, p99_latency_us:$p99, msg_loss:$loss}')"
    add_run_index_entry "$run" crosshost "$LABEL" "$metrics"
    jq -n --arg ts "$(date -Iseconds)" --arg role "$ROLE" --arg server "$SERVER_URL" \
        --arg clock "$CLOCK" --argjson rate "$TARGET_MSGS_PER_SEC" --argjson duration "$DURATION_SEC" \
        --argjson size "$SIZE" '{timestamp:$ts, role:$role, server_url:$server, clock:$clock,
        target_msgs_per_sec:$rate, duration_sec:$duration, size:$size, image:"none"}' > "$run/meta.json"
fi

echo "Done. Results in: $run"