#!/usr/bin/env bash
# bench-rtt-2host.sh - round-trip latency between TWO REAL SERVERS.
#
# Unlike every other script here, this one runs ONE role and is meant to be invoked
# separately on each machine. There is no SSH orchestration: run the echo side on server B,
# then the ping side on server A.
#
#   server B:  ./scripts/bench-rtt-2host.sh --role echo --peer-address <A> --self-address <B> \
#                --target-msgs-per-sec 10000 --duration-sec 30
#   server A:  ./scripts/bench-rtt-2host.sh --role ping --peer-address <B> --self-address <A> \
#                --target-msgs-per-sec 10000 --duration-sec 30
#
# BOTH SIDES MUST BE GIVEN THE SAME --target-msgs-per-sec AND --duration-sec: each derives
# the expected message count independently (round(rate * duration)), and the echo side uses
# it to know when the run is over. Start the echo side FIRST - the ping side waits for it and
# gives up after --connect-timeout-sec.
#
# ADDRESSING. Aeron has no discovery, and unlike the Fast DDS version of this script there
# is nothing optional about that: there is no multicast fallback to try first, and no
# rendezvous server. Each side must be told both addresses explicitly.
#   --self-address   the address THIS machine binds its subscription to
#   --peer-address   the address this machine publishes to
# The two ports (request and response) must differ, because an Aeron subscription binds its
# endpoint - sharing one would make each side receive its own traffic.
#
# WHY RTT AND NOT ONE-WAY. The one-way script (bench-latency-oneway.sh) embeds a send
# timestamp and subtracts it on receipt. That works only because both roles read the SAME
# kernel's clock. Two real servers have two unrelated std::chrono::steady_clock epochs, so
# the subtraction is meaningless - and it fails silently, producing plausible-looking or
# frankly negative latencies (negative values were actually observed on real hardware in
# fast-dds/). RTT sidesteps this entirely: the ping side stamps the message and measures its
# return with its OWN clock, so no clock synchronisation is required.
#
# WHAT RTT IS NOT. RTT includes the echo peer's receive-and-republish cost on top of two
# network traversals, so RTT/2 OVERESTIMATES one-way latency - do not report it as one-way.
# It is a valid upper bound and valid for relative comparison. For a true cross-host one-way
# figure you need PTP-synchronised clocks; see README.md.
#
# NETWORKING. This uses the `aeron-bench-host` compose service (network_mode: host), which
# is required, not optional: a bridged container cannot bind the host address it would have
# to advertise, so the peer's driver has nowhere to send.
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
LABEL="2host"

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
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ "$ROLE" != "ping" ] && [ "$ROLE" != "echo" ]; then
    echo "ERROR: --role must be 'ping' (the measuring side) or 'echo' (the reflecting side)." >&2
    echo "       Start --role echo on one server first, then --role ping on the other." >&2
    exit 1
fi
if [ -z "$PEER_ADDRESS" ] || [ -z "$SELF_ADDRESS" ]; then
    echo "ERROR: --peer-address and --self-address are both required." >&2
    echo "       Aeron has no discovery: each side must be told the other's address, and its" >&2
    echo "       own, because a subscription binds the address it listens on." >&2
    echo "       e.g. on server A: --self-address 10.0.0.1 --peer-address 10.0.0.2" >&2
    exit 1
fi
if [ "$REQ_PORT" = "$RESP_PORT" ]; then
    echo "ERROR: --req-port and --resp-port must differ. An Aeron subscription binds its" >&2
    echo "       endpoint, so a shared port makes each side receive its own traffic." >&2
    exit 1
fi

if ! awk -v v="$TARGET_MSGS_PER_SEC" 'BEGIN { exit (v+0 > 0) ? 0 : 1 }'; then
    echo "ERROR: --target-msgs-per-sec must be > 0." >&2
    exit 1
fi

if [ "$TRANSPORT" = "ipc" ]; then
    echo "ERROR: --transport ipc cannot reach another server - aeron:ipc is shared memory inside" >&2
    echo "       one host's media driver." >&2
    exit 1
fi

assert_docker_running
ensure_image_built

# aeron_bench's --mode names are pub/sub; for --measure rtt, pub is the measuring ping side
# and sub is the echo side. Translate here so the script's own vocabulary stays honest.
#
# The endpoint mapping is the part worth reading twice. The REQUEST channel is bound by the
# ECHO side, and the RESPONSE channel is bound by the PING side. So:
#   ping: --endpoint <echo's address>:REQ   --response-endpoint <own address>:RESP
#   echo: --endpoint <own address>:REQ      --response-endpoint <ping's address>:RESP
# aeron_bench publishes to --endpoint / subscribes to --response-endpoint when it is the
# ping side, and does the reverse as the echo side.
if [ "$ROLE" = "ping" ]; then
    aeron_mode="pub"
    REQ_ENDPOINT="${PEER_ADDRESS}:${REQ_PORT}"    # publish to the echo side
    RESP_ENDPOINT="${SELF_ADDRESS}:${RESP_PORT}"  # subscribe on our own address
else
    aeron_mode="sub"
    REQ_ENDPOINT="${SELF_ADDRESS}:${REQ_PORT}"    # subscribe on our own address
    RESP_ENDPOINT="${PEER_ADDRESS}:${RESP_PORT}"  # publish back to the ping side
fi

mapfile -t common_args < <(aeron_common_args)
mapfile -t driver_env < <(driver_env_args)

echo "role=$ROLE (aeron_bench --mode $aeron_mode)  rate=${TARGET_MSGS_PER_SEC}/s  duration=${DURATION_SEC}s  size=$SIZE"
echo "request channel:  $REQ_ENDPOINT"
echo "response channel: $RESP_ENDPOINT"
echo "transport=$TRANSPORT  reliable=$RELIABLE  pollIdle=$POLL_IDLE  driverIdle=$DRIVER_IDLE"

cd "$PROJECT_ROOT"

if [ "$ROLE" = "echo" ]; then
    # The echo side produces no measurement of its own - it exists so the ping side has
    # something to bounce off. It exits once the expected count has arrived (or the run's
    # idle timeout trips), so it does not need stopping by hand.
    echo
    echo "Echo side running. Start the ping side on the other server with the SAME"
    echo "--target-msgs-per-sec and --duration-sec. This will exit on its own afterwards."
    # No --profile flag: `docker compose run <svc>` auto-enables that service's own
    # profiles. (And `run --profile X` would be a hard error anyway - --profile is a compose
    # GLOBAL flag, not a run flag. Confirmed in fast-dds/.)
    docker compose run --rm "${driver_env[@]}" aeron-bench-host aeron_bench \
        --measure rtt --mode "$aeron_mode" \
        --endpoint "$REQ_ENDPOINT" --response-endpoint "$RESP_ENDPOINT" \
        --rate "$TARGET_MSGS_PER_SEC" --duration-sec "$DURATION_SEC" \
        --size "$SIZE" --connect-timeout-sec "$CONNECT_TIMEOUT_SEC" \
        "${common_args[@]}" --out /out
    exit 0
fi

# --- ping side: this is where the measurement lands ---
run="$(new_run_dir crosshost "$LABEL")"
echo "Run dir: $run"

tool_exit=0
docker_run_and_copy_out "$run" "${driver_env[@]}" aeron-bench-host aeron_bench \
    --measure rtt --mode "$aeron_mode" \
    --endpoint "$REQ_ENDPOINT" --response-endpoint "$RESP_ENDPOINT" \
    --rate "$TARGET_MSGS_PER_SEC" --duration-sec "$DURATION_SEC" \
    --size "$SIZE" --connect-timeout-sec "$CONNECT_TIMEOUT_SEC" \
    "${common_args[@]}" --out /out || tool_exit=$?

params="$(jq -n \
    --arg role "$ROLE" --arg reqEndpoint "$REQ_ENDPOINT" --arg respEndpoint "$RESP_ENDPOINT" \
    --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
    --argjson durationSec "$DURATION_SEC" --argjson size "$SIZE" \
    --argjson common "$(common_params_json)" \
    '{measure:"rtt", role:$role, requestEndpoint:$reqEndpoint, responseEndpoint:$respEndpoint,
      targetMsgsPerSec:$targetMsgsPerSec, durationSec:$durationSec, size:$size,
      hosts:"two real servers"} + $common')"
save_meta "$run" "$(tool_version "$run/result.json")" "$params"

msg_loss=0
if ! msg_loss="$(index_from_result_json "$run/result.json" "$run" crosshost "$LABEL")"; then
    echo "Warning: could not read result.json - skipping run-index.csv entry." >&2
    echo "         If the connect wait timed out, check the two addresses and that UDP ports" >&2
    echo "         $REQ_PORT and $RESP_PORT are open in both directions." >&2
    exit 1
fi

if [ "$tool_exit" -ne 0 ]; then
    echo
    echo "aeron_bench exited with code $tool_exit. See result.json in $run" >&2
    exit "$tool_exit"
fi
echo
echo "Done. Results in: $run (rtt.csv, result.json, meta.json; msg_loss=$msg_loss)"
echo "REMINDER: these are ROUND-TRIP figures including the echo peer's own processing."
echo "          RTT/2 overestimates one-way latency - do not report it as a one-way number."
