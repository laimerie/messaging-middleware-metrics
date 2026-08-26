#!/usr/bin/env bash
# bench-rtt-2host.sh - round-trip latency between TWO REAL SERVERS.
#
# Unlike every other script here, this one runs ONE role and is meant to be invoked
# separately on each machine. There is no SSH orchestration: run the echo side on server B,
# then the ping side on server A.
#
#   server B:  ./scripts/bench-rtt-2host.sh --role echo --target-msgs-per-sec 10000 --duration-sec 30
#   server A:  ./scripts/bench-rtt-2host.sh --role ping --target-msgs-per-sec 10000 --duration-sec 30
#
# BOTH SIDES MUST BE GIVEN THE SAME --target-msgs-per-sec AND --duration-sec: each derives
# the expected message count independently (round(rate * duration)), and the echo side uses
# it to know when the run is over. Start the echo side FIRST — the ping side waits for it to
# match and gives up after --match-timeout-sec.
#
# WHY RTT AND NOT ONE-WAY. The one-way scripts (bench-latency-oneway.sh) embed a send
# timestamp and subtract it on receipt. That works only because both roles read the SAME
# kernel's clock. Two real servers have two unrelated std::chrono::steady_clock epochs, so
# the subtraction is meaningless — and it fails silently, producing plausible-looking or
# frankly negative latencies. RTT sidesteps this entirely: the ping side stamps the message
# and measures its return with its OWN clock, so no clock synchronisation is required.
#
# WHAT RTT IS NOT. RTT includes the echo peer's receive-and-republish cost on top of two
# network traversals, so RTT/2 OVERESTIMATES one-way latency — do not report it as one-way.
# It is a valid upper bound and valid for relative comparison. For a true cross-host one-way
# figure you need PTP-synchronised clocks (see README.md's "実サーバー間の片道レイテンシ").
#
# NETWORKING. This uses the `dds-bench-host` compose service (network_mode: host), which is
# required, not optional: on a bridge network a container advertises its private RTPS
# locator (e.g. 172.28.0.2) and the peer server cannot route to it — discovery succeeds and
# then no data arrives.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

ROLE=""
TOPIC="BENCH_RTT_2HOST"
TARGET_MSGS_PER_SEC=10000
DURATION_SEC=30
SIZE=1024
MATCH_TIMEOUT_SEC=60
LABEL="2host"

while [[ $# -gt 0 ]]; do
    if parse_common_arg "$1" "${2:-}"; then shift "$COMMON_ARG_CONSUMED"; continue; fi
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --topic) TOPIC="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --duration-sec) DURATION_SEC="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --match-timeout-sec) MATCH_TIMEOUT_SEC="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ "$ROLE" != "ping" ] && [ "$ROLE" != "echo" ]; then
    echo "ERROR: --role must be 'ping' (the measuring side) or 'echo' (the reflecting side)." >&2
    echo "       Start --role echo on one server first, then --role ping on the other." >&2
    exit 1
fi

if ! awk -v v="$TARGET_MSGS_PER_SEC" 'BEGIN { exit (v+0 > 0) ? 0 : 1 }'; then
    echo "ERROR: --target-msgs-per-sec must be > 0." >&2
    exit 1
fi

if [ "$TRANSPORT" = "shm" ]; then
    echo "ERROR: --transport shm cannot reach another server - shared memory is host-local." >&2
    exit 1
fi

assert_docker_running
ensure_image_built

# dds_bench's --mode names are pub/sub; for --measure rtt, pub is the measuring ping side
# and sub is the echo side. Translate here so the script's own vocabulary stays honest.
if [ "$ROLE" = "ping" ]; then dds_mode="pub"; else dds_mode="sub"; fi

mapfile -t common_args < <(dds_common_args)

if [ "$DISCOVERY" = "server" ] && [ "$DS_ADDRESS" = "172.28.0.10" ]; then
    echo "ERROR: --discovery server across two servers needs a REACHABLE address, but DS_ADDRESS" >&2
    echo "       is still the host-local compose default (172.28.0.10)." >&2
    echo "       Start the server on one machine:" >&2
    echo "         docker compose --profile host up -d discovery-server-host" >&2
    echo "       then set its real address on BOTH machines before running this script:" >&2
    echo "         DS_ADDRESS=<that server's IP> ./scripts/bench-rtt-2host.sh ..." >&2
    exit 1
fi

echo "role=$ROLE (dds_bench --mode $dds_mode)  topic=$TOPIC  rate=${TARGET_MSGS_PER_SEC}/s  duration=${DURATION_SEC}s  size=$SIZE"
echo "discovery=$DISCOVERY  transport=$TRANSPORT  reliability=$RELIABILITY  history=$HISTORY"
if [ "$DISCOVERY" = "simple" ]; then
    echo "NOTE: SIMPLE discovery needs UDP multicast to cross the LAN between these two servers."
    echo "      If matching times out, either enable multicast on that path or use the Discovery"
    echo "      Server (see the --discovery server hint this script prints on misconfiguration)."
fi

cd "$PROJECT_ROOT"

if [ "$ROLE" = "echo" ]; then
    # The echo side produces no measurement of its own - it exists so the ping side has
    # something to bounce off. It exits once the expected count has arrived (or the run's
    # idle timeout trips), so it does not need stopping by hand.
    echo
    echo "Echo side running. Start the ping side on the other server with the SAME"
    echo "--target-msgs-per-sec and --duration-sec. This will exit on its own afterwards."
    docker compose run --rm dds-bench-host dds_bench \
        --measure rtt --mode "$dds_mode" \
        --topic "$TOPIC" --rate "$TARGET_MSGS_PER_SEC" --duration-sec "$DURATION_SEC" \
        --size "$SIZE" --match-timeout-sec "$MATCH_TIMEOUT_SEC" \
        "${common_args[@]}" --out /out
    exit 0
fi

# --- ping side: this is where the measurement lands ---
run="$(new_run_dir crosshost "$LABEL")"
echo "Run dir: $run"

tool_exit=0
docker_run_and_copy_out "$run" dds-bench-host dds_bench \
    --measure rtt --mode "$dds_mode" \
    --topic "$TOPIC" --rate "$TARGET_MSGS_PER_SEC" --duration-sec "$DURATION_SEC" \
    --size "$SIZE" --match-timeout-sec "$MATCH_TIMEOUT_SEC" \
    "${common_args[@]}" --out /out || tool_exit=$?

params="$(jq -n \
    --arg role "$ROLE" --arg topic "$TOPIC" --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
    --argjson durationSec "$DURATION_SEC" --argjson size "$SIZE" \
    --argjson common "$(common_params_json)" \
    '{measure:"rtt", role:$role, topic:$topic, targetMsgsPerSec:$targetMsgsPerSec,
      durationSec:$durationSec, size:$size, hosts:"two real servers"} + $common')"
save_meta "$run" "$(tool_version "$run/result.json")" "$params"

msg_loss=0
if ! msg_loss="$(index_from_result_json "$run/result.json" "$run" crosshost "$LABEL")"; then
    echo "Warning: could not read result.json - skipping run-index.csv entry." >&2
    echo "         If matching timed out, the two servers did not discover each other." >&2
    exit 1
fi

if [ "$tool_exit" -ne 0 ]; then
    echo
    echo "dds_bench exited with code $tool_exit. See result.json in $run" >&2
    exit "$tool_exit"
fi
echo
echo "Done. Results in: $run (rtt.csv, result.json, meta.json; msg_loss=$msg_loss)"
echo "REMINDER: these are ROUND-TRIP figures including the echo peer's own processing."
echo "          RTT/2 overestimates one-way latency - do not report it as a one-way number."
