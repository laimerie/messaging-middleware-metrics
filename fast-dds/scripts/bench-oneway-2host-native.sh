#!/usr/bin/env bash
# Run a true one-way latency measurement on two real Linux hosts without Docker.
# Start the subscriber first, then run the publisher on the other host.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

ROLE=""
TOPIC="BENCH_LATENCY_ONEWAY_2HOST"
TARGET_MSGS_PER_SEC=1000
DURATION_SEC=10
SIZE=128
MATCH_TIMEOUT_SEC=60
CLOCK="realtime"
LABEL="2host-native"

while [[ $# -gt 0 ]]; do
    if parse_common_arg "$1" "${2:-}"; then shift "$COMMON_ARG_CONSUMED"; continue; fi
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --topic) TOPIC="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --duration-sec) DURATION_SEC="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --match-timeout-sec) MATCH_TIMEOUT_SEC="$2"; shift 2 ;;
        --clock) CLOCK="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ "$ROLE" != "pub" && "$ROLE" != "sub" ]]; then
    echo "ERROR: --role must be 'pub' or 'sub'. Start sub first, then pub." >&2
    exit 1
fi
if [[ "$TRANSPORT" != "udp" ]]; then
    echo "ERROR: --transport must be udp for a two-host run." >&2
    exit 1
fi
if [[ "$DISCOVERY" != "simple" ]]; then
    echo "ERROR: native two-host mode currently supports only --discovery simple." >&2
    echo "       Use bench-rtt-2host.sh with Docker for Discovery Server mode." >&2
    exit 1
fi
for value in "$TARGET_MSGS_PER_SEC" "$DURATION_SEC" "$SIZE" "$MATCH_TIMEOUT_SEC"; do
    if ! awk -v v="$value" 'BEGIN { exit (v+0 > 0) ? 0 : 1 }'; then
        echo "ERROR: numeric benchmark options must be > 0." >&2
        exit 1
    fi
done
if [[ "$CLOCK" != "realtime" && "$CLOCK" != "monotonic" ]]; then
    echo "ERROR: --clock must be realtime or monotonic." >&2
    exit 1
fi

tool="$PKG_ROOT/bin/dds_bench"
[[ -x "$tool" ]] || { echo "ERROR: dds_bench was not found at $tool." >&2; exit 1; }
export LD_LIBRARY_PATH="$PKG_ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
run="$(new_run_dir crosshost "$LABEL")"

args=(--measure latency --mode "$ROLE" --topic "$TOPIC" --rate "$TARGET_MSGS_PER_SEC"
      --duration-sec "$DURATION_SEC" --size "$SIZE" --match-timeout-sec "$MATCH_TIMEOUT_SEC"
      --clock "$CLOCK" --transport udp --discovery simple --out "$run")
mapfile -t common_args < <(dds_common_args)
args+=("${common_args[@]}")

echo "role=$ROLE topic=$TOPIC rate=${TARGET_MSGS_PER_SEC}/s duration=${DURATION_SEC}s size=$SIZE clock=$CLOCK"
if [[ "$ROLE" == "sub" ]]; then
    echo "Subscriber must remain running while the publisher is started on the other host."
else
    echo "Publisher waits for DDS publication matching; start the subscriber first."
fi
"$tool" "${args[@]}"

if [[ "$ROLE" == "sub" && -f "$run/result.json" ]]; then
    index_from_result_json "$run/result.json" "$run" crosshost "$LABEL" >/dev/null
    jq -n --arg ts "$(date -Iseconds)" --arg role "$ROLE" --arg topic "$TOPIC" \
        --arg clock "$CLOCK" --argjson rate "$TARGET_MSGS_PER_SEC" \
        --argjson duration "$DURATION_SEC" --argjson size "$SIZE" \
        '{timestamp:$ts, role:$role, topic:$topic, clock:$clock, target_msgs_per_sec:$rate,
          duration_sec:$duration, size:$size, image:"none", server:"none (Fast DDS is daemonless)"}' \
        > "$run/meta.json"
fi
echo "Done. Results in: $run"