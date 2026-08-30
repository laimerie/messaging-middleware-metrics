#!/usr/bin/env bash
# bench-rtt-2host-native.sh - RTT benchmark on two real hosts without Docker.
# Run this script separately on each host. Start echo first, then ping.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

ROLE=""
PEER_ADDRESS=""
SELF_ADDRESS=""
REQ_PORT="$CROSS_PORT"
RESP_PORT="$CROSS_RESPONSE_PORT"
TARGET_MSGS_PER_SEC=10000
DURATION_SEC=30
SIZE=1024
CONNECT_TIMEOUT_SEC=60
LABEL="2host-native"
AERON_PREFIX="${AERON_PREFIX:-$PROJECT_ROOT/workspace/aeron-install}"
AERON_DIR="${AERON_DIR:-/dev/shm/aeron-bench}"
CXX_RUNTIME_DIR="${CXX_RUNTIME_DIR:-}"

while [[ $# -gt 0 ]]; do
    if parse_common_arg "$1" "${2:-}"; then shift "$COMMON_ARG_CONSUMED"; continue; fi
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --peer-address) PEER_ADDRESS="$2"; shift 2 ;;
        --self-address) SELF_ADDRESS="$2"; shift 2 ;;
        --req-port) REQ_PORT="$2"; shift 2 ;;
        --resp-port) RESP_PORT="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --duration-sec) DURATION_SEC="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --connect-timeout-sec) CONNECT_TIMEOUT_SEC="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --aeron-prefix) AERON_PREFIX="$2"; shift 2 ;;
        --aeron-dir) AERON_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ "$ROLE" != "ping" && "$ROLE" != "echo" ]]; then
    echo "ERROR: --role must be 'ping' or 'echo'." >&2
    exit 1
fi
if [[ -z "$PEER_ADDRESS" || -z "$SELF_ADDRESS" ]]; then
    echo "ERROR: --peer-address and --self-address are required." >&2
    exit 1
fi
if [[ "$REQ_PORT" == "$RESP_PORT" ]]; then
    echo "ERROR: --req-port and --resp-port must differ." >&2
    exit 1
fi
if [[ ! -x "$AERON_PREFIX/bin/aeronmd" || ! -x "$AERON_PREFIX/bin/aeron_bench" ]]; then
    echo "ERROR: aeronmd and aeron_bench were not found under $AERON_PREFIX/bin." >&2
    echo "       Run scripts/build-local.sh or set --aeron-prefix." >&2
    exit 1
fi

if [[ -z "$CXX_RUNTIME_DIR" ]] && command -v "${CXX:-c++}" >/dev/null 2>&1; then
    cxx_runtime="$("${CXX:-c++}" -print-file-name=libstdc++.so.6 2>/dev/null || true)"
    if [[ -f "$cxx_runtime" ]]; then
        CXX_RUNTIME_DIR="$(dirname "$cxx_runtime")"
    fi
fi

if [[ "$ROLE" == "ping" ]]; then
    AERON_MODE="pub"
    REQ_ENDPOINT="${PEER_ADDRESS}:${REQ_PORT}"
    RESP_ENDPOINT="${SELF_ADDRESS}:${RESP_PORT}"
else
    AERON_MODE="sub"
    REQ_ENDPOINT="${SELF_ADDRESS}:${REQ_PORT}"
    RESP_ENDPOINT="${PEER_ADDRESS}:${RESP_PORT}"
fi

mkdir -p "$AERON_DIR"
export AERON_DIR
export AERON_DIR_DELETE_ON_START=true
export AERON_DIR_DELETE_ON_SHUTDOWN=true
export AERON_THREADING_MODE="${AERON_THREADING_MODE:-$DRIVER_THREADING}"
export AERON_CONDUCTOR_IDLE_STRATEGY="${AERON_CONDUCTOR_IDLE_STRATEGY:-$DRIVER_IDLE}"
export AERON_SENDER_IDLE_STRATEGY="${AERON_SENDER_IDLE_STRATEGY:-$DRIVER_IDLE}"
export AERON_RECEIVER_IDLE_STRATEGY="${AERON_RECEIVER_IDLE_STRATEGY:-$DRIVER_IDLE}"
export LD_LIBRARY_PATH="$AERON_PREFIX/lib:$AERON_PREFIX/lib64${CXX_RUNTIME_DIR:+:$CXX_RUNTIME_DIR}:${LD_LIBRARY_PATH:-}"

driver_pid=""
cleanup() {
    if [[ -n "$driver_pid" ]]; then
        kill "$driver_pid" 2>/dev/null || true
        wait "$driver_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

"$AERON_PREFIX/bin/aeronmd" >"$AERON_DIR/aeronmd.log" 2>&1 &
driver_pid=$!
for _ in $(seq 1 100); do
    [[ -f "$AERON_DIR/cnc.dat" ]] && break
    if ! kill -0 "$driver_pid" 2>/dev/null; then
        cat "$AERON_DIR/aeronmd.log" >&2
        exit 1
    fi
    sleep 0.1
done
[[ -f "$AERON_DIR/cnc.dat" ]] || { echo "ERROR: aeronmd did not create $AERON_DIR/cnc.dat" >&2; exit 1; }

mapfile -t common_args < <(aeron_common_args)
if [[ "$ROLE" == "echo" ]]; then
    OUT_DIR="${AERON_OUT:-$AERON_DIR/result}"
else
    OUT_DIR="$(new_run_dir crosshost "$LABEL")"
fi
mkdir -p "$OUT_DIR"
echo "role=$ROLE transport=$TRANSPORT rate=${TARGET_MSGS_PER_SEC}/s duration=${DURATION_SEC}s"
echo "request=$REQ_ENDPOINT response=$RESP_ENDPOINT aeron_dir=$AERON_DIR"

"$AERON_PREFIX/bin/aeron_bench" \
    --measure rtt --mode "$AERON_MODE" \
    --endpoint "$REQ_ENDPOINT" --response-endpoint "$RESP_ENDPOINT" \
    --rate "$TARGET_MSGS_PER_SEC" --duration-sec "$DURATION_SEC" \
    --size "$SIZE" --connect-timeout-sec "$CONNECT_TIMEOUT_SEC" \
    --aeron-dir "$AERON_DIR" "${common_args[@]}" --out "$OUT_DIR"

if [[ "$ROLE" == "ping" ]]; then
    params="$(jq -n \
        --arg role "$ROLE" --arg reqEndpoint "$REQ_ENDPOINT" --arg respEndpoint "$RESP_ENDPOINT" \
        --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" --argjson durationSec "$DURATION_SEC" \
        --argjson size "$SIZE" --argjson common "$(common_params_json)" \
        '{measure:"rtt", role:$role, requestEndpoint:$reqEndpoint, responseEndpoint:$respEndpoint,
          targetMsgsPerSec:$targetMsgsPerSec, durationSec:$durationSec, size:$size,
          hosts:"two real servers, native processes"} + $common')"
    jq -n --arg ts "$(date -Iseconds)" --argjson params "$params" \
        --arg tool "$(tool_version "$OUT_DIR/result.json")" \
        --arg driver "aeronmd on host, threading=$AERON_THREADING_MODE, idle=$AERON_SENDER_IDLE_STRATEGY" \
        '{timestamp:$ts, params:$params, client_tool:$tool, image:"none", server:$driver}' \
        > "$OUT_DIR/meta.json"
    index_from_result_json "$OUT_DIR/result.json" "$OUT_DIR" crosshost "$LABEL" >/dev/null
    echo "Done. Results in: $OUT_DIR"
else
    echo "Echo side is ready; start the ping side on the other host."
fi