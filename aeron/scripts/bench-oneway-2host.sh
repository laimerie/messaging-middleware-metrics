#!/usr/bin/env bash
# bench-oneway-2host.sh - TRUE one-way latency between two PTP-synchronised servers, natively
# (no Docker).
#
#   server B (receiver, and where the measurement lands - START THIS FIRST):
#     ./scripts/bench-oneway-2host.sh --role sub \
#       --self-address 10.0.0.2 --peer-address 10.0.0.1 \
#       --target-msgs-per-sec 10000 --duration-sec 30 --label prod-profile
#
#   server A (sender):
#     ./scripts/bench-oneway-2host.sh --role pub \
#       --self-address 10.0.0.1 --peer-address 10.0.0.2 \
#       --target-msgs-per-sec 10000 --duration-sec 30
#
# BOTH SIDES MUST BE GIVEN THE SAME --target-msgs-per-sec AND --duration-sec: each derives the
# expected message count independently as round(rate * duration), and the sub side uses it to
# know when the run is over.
#
# THE MEASUREMENT LANDS ON THE SUB SIDE. This is the opposite of bench-rtt-2host.sh, where the
# PING side measures, and it follows directly from what one-way latency is: the publisher
# stamps the message, the SUBSCRIBER subtracts on receipt, so only the subscriber ever holds
# both halves. The pub side writes a result.json too, but it contains send-side counters only.
#
# WHY THIS NEEDS PTP, AND WHAT PTP ACTUALLY BUYS
#
# The one-way figure is (receive time on B) - (send time on A). Those are two different
# machines' clocks, so the subtraction is only as good as their synchronisation. This script
# therefore runs aeron_bench with --clock realtime: CLOCK_REALTIME is what PTP disciplines,
# and CLOCK_MONOTONIC - which the tool uses everywhere else, and which every same-host
# measurement in this project relies on - is NOT disciplined by PTP at all. That distinction is
# the entire reason this script exists; see tools/aeron_bench/main.cpp's header.
#
# The residual offset between the two clocks is the ERROR BAR on every number produced here.
# It is captured before and after the run into meta.json, and it is NOT optional reading:
# with a one-way latency in the tens of microseconds, software-timestamped PTP (tens of
# microseconds of error) measures nothing at all. Hardware timestamping is effectively a
# prerequisite - the script checks for it and says so.
#
# WHEN NOT TO USE THIS. If round-trip is good enough, bench-rtt-2host.sh needs no clock
# synchronisation whatsoever and cannot fail this way. And if the question is "which middleware
# is faster", the right answer is a SAME-HOST run (bench-latency-oneway.sh): same conditions,
# one kernel's clock, no network as a confounder, no PTP. See README.md.
#
# NATIVE, NOT CONTAINERISED. The PTP pair cannot run Docker, so this uses the binaries shipped
# by scripts/package-native.sh. See scripts/common-native.sh for what the container was doing
# for us that now has to be done explicitly - above all, killing the media driver, which with
# the default --driver-idle noop would otherwise busy-spin three cores on this server forever.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/common-native.sh"

ROLE=""
PEER_ADDRESS=""
SELF_ADDRESS=""
PORT="$CROSS_PORT"
TARGET_MSGS_PER_SEC=10000
DURATION_SEC=30
SIZE=1024
CONNECT_TIMEOUT_SEC=60
CLOCK="realtime"
LABEL="2host-oneway"

while [[ $# -gt 0 ]]; do
    if parse_common_arg "$1" "${2:-}"; then shift "$COMMON_ARG_CONSUMED"; continue; fi
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --peer-address) PEER_ADDRESS="$2"; shift 2 ;;
        --self-address) SELF_ADDRESS="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --target-msgs-per-sec) TARGET_MSGS_PER_SEC="$2"; shift 2 ;;
        --duration-sec) DURATION_SEC="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --connect-timeout-sec) CONNECT_TIMEOUT_SEC="$2"; shift 2 ;;
        --clock) CLOCK="$2"; shift 2 ;;
        --force-clean) FORCE_CLEAN=1; shift ;;
        --label) LABEL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ "$ROLE" != "pub" ] && [ "$ROLE" != "sub" ]; then
    echo "ERROR: --role must be 'pub' (the sending side) or 'sub' (the receiving side, which" >&2
    echo "       is where the measurement lands). Start --role sub on one server first, then" >&2
    echo "       --role pub on the other." >&2
    exit 1
fi
if [ -z "$PEER_ADDRESS" ] || [ -z "$SELF_ADDRESS" ]; then
    echo "ERROR: --peer-address and --self-address are both required." >&2
    echo "       Aeron has no discovery: each side must be told the other's address, and its" >&2
    echo "       own, because a subscription binds the address it listens on." >&2
    echo "       e.g. on the sub server: --self-address 10.0.0.2 --peer-address 10.0.0.1" >&2
    exit 1
fi
if [ "$CLOCK" != "realtime" ] && [ "$CLOCK" != "monotonic" ]; then
    echo "ERROR: --clock must be 'realtime' or 'monotonic'." >&2
    exit 1
fi
if ! awk -v v="$TARGET_MSGS_PER_SEC" 'BEGIN { exit (v+0 > 0) ? 0 : 1 }'; then
    echo "ERROR: --target-msgs-per-sec must be > 0." >&2
    exit 1
fi
if [ "$TRANSPORT" = "ipc" ]; then
    echo "ERROR: --transport ipc cannot reach another server - aeron:ipc is shared memory" >&2
    echo "       inside one host's media driver." >&2
    exit 1
fi

native_preflight

# --- Clock synchronisation checks -------------------------------------------------------
#
# Both of these warn rather than fail: the operator may be synchronising by some other means,
# and a deliberate --clock monotonic run (to demonstrate what unsynchronised clocks produce) is
# a legitimate thing to want. But they are loud, because a run that passes silently and reports
# a plausible p50 is precisely the failure this whole script is built to avoid.
if [ "$CLOCK" = "realtime" ]; then
    ptp_before="$(ptp_offset_ns || true)"
    if [ -z "${ptp_before:-}" ]; then
        echo "WARNING: could not read a PTP offset from this host (no pmc, or ptp4l not" >&2
        echo "         running). --clock realtime assumes CLOCK_REALTIME is disciplined and" >&2
        echo "         cannot verify it. If the two servers are NOT synchronised, this run" >&2
        echo "         will produce plausible-looking numbers that are wrong by the offset." >&2
    else
        echo "PTP master_offset before run: ${ptp_before} ns"
    fi

    # Hardware timestamping is close to a prerequisite here rather than an optimisation.
    # Software-timestamped PTP carries tens of microseconds of error, which is the same order
    # as the one-way latency being measured - i.e. the error bar swallows the result.
    iface="$(ip -o route get "$PEER_ADDRESS" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)"
    if [ -n "${iface:-}" ] && command -v ethtool >/dev/null 2>&1; then
        if ethtool -T "$iface" 2>/dev/null | grep -q "hardware-transmit\|HARDWARE_TRANSMIT"; then
            echo "Hardware timestamping: available on $iface"
        else
            echo "WARNING: $iface does not report hardware timestamping (ethtool -T)." >&2
            echo "         Software-timestamped PTP has tens of microseconds of error, which is" >&2
            echo "         the same order as the latency being measured here. Consider using" >&2
            echo "         bench-rtt-2host.sh instead - RTT needs no synchronisation at all." >&2
        fi
    fi
else
    echo "NOTE: --clock monotonic on two separate servers is measuring the difference between" >&2
    echo "      two unrelated clock epochs, not latency. Only useful deliberately." >&2
fi

native_warn_about_firewall "$PORT"

# The pub side publishes to the SUB's address; the sub side binds its own. One port, unlike
# the RTT script - there is no response channel in a one-way run.
if [ "$ROLE" = "sub" ]; then
    ENDPOINT="${SELF_ADDRESS}:${PORT}"
else
    ENDPOINT="${PEER_ADDRESS}:${PORT}"
fi

mapfile -t common_args < <(aeron_common_args)

echo "role=$ROLE  endpoint=$ENDPOINT  rate=${TARGET_MSGS_PER_SEC}/s  duration=${DURATION_SEC}s  size=$SIZE"
echo "clock=$CLOCK  transport=$TRANSPORT  reliable=$RELIABLE  pollIdle=$POLL_IDLE  driverIdle=$DRIVER_IDLE"

# Starts this host's media driver and installs the trap that stops it again.
native_driver_up

run="$(new_run_dir crosshost "${LABEL}-${ROLE}")"
echo "Run dir: $run"

if [ "$ROLE" = "pub" ]; then
    echo
    echo "Sending. Start the sub side FIRST on the other server with the SAME"
    echo "--target-msgs-per-sec and --duration-sec; the measurement is written THERE."
fi

tool_exit=0
native_run_bench "$run" aeron_bench \
    --measure latency --mode "$ROLE" \
    --endpoint "$ENDPOINT" \
    --rate "$TARGET_MSGS_PER_SEC" --duration-sec "$DURATION_SEC" \
    --size "$SIZE" --connect-timeout-sec "$CONNECT_TIMEOUT_SEC" \
    --clock "$CLOCK" \
    "${common_args[@]}" || tool_exit=$?

# Captured after the run as well as before: PTP is a control loop, and an offset that moved
# during the run is itself the explanation for a distribution that looks wrong.
ptp_json="null"
if [ "$CLOCK" = "realtime" ]; then
    ptp_after="$(ptp_offset_ns || true)"
    [ -n "${ptp_after:-}" ] && echo "PTP master_offset after run:  ${ptp_after} ns"
    ptp_json="$(jq -n \
        --arg before "${ptp_before:-}" --arg after "${ptp_after:-}" \
        '{master_offset_ns_before: (if $before == "" then null else ($before|tonumber) end),
          master_offset_ns_after:  (if $after  == "" then null else ($after|tonumber)  end)}')"
fi

params="$(jq -n \
    --arg role "$ROLE" --arg endpoint "$ENDPOINT" --arg clock "$CLOCK" \
    --argjson targetMsgsPerSec "$TARGET_MSGS_PER_SEC" \
    --argjson durationSec "$DURATION_SEC" --argjson size "$SIZE" \
    --argjson common "$(common_params_json)" \
    '{measure:"latency", oneway:true, role:$role, endpoint:$endpoint, clock:$clock,
      targetMsgsPerSec:$targetMsgsPerSec, durationSec:$durationSec, size:$size,
      hosts:"two real servers, native (no container)"} + $common')"
save_meta_native "$run" "$(tool_version "$run/result.json")" "$params" "$ptp_json"

if [ "$ROLE" = "pub" ]; then
    echo
    echo "Send side finished. The one-way figures are on the SUB server, not here."
    if [ -n "${ptp_before:-}" ]; then
        echo "Record THIS host's PTP offset (${ptp_before} ns) alongside the sub side's: the"
        echo "error bar on the measurement is bounded by the sum of the two, not by either one."
    fi
    exit "$tool_exit"
fi

# --- sub side: this is where the measurement lands ---
msg_loss=0
if ! msg_loss="$(index_from_result_json "$run/result.json" "$run" crosshost "$LABEL")"; then
    echo "Warning: could not read result.json - skipping run-index.csv entry." >&2
    echo "         If the connect wait timed out: check both addresses, and that UDP port" >&2
    echo "         $PORT is open in both directions. Aeron has no discovery, so an" >&2
    echo "         unreachable peer looks exactly like a peer that never started." >&2
    exit 1
fi

if [ "$tool_exit" -ne 0 ]; then
    echo
    echo "aeron_bench exited with code $tool_exit. See result.json in $run" >&2
    exit "$tool_exit"
fi

echo
echo "Done. Results in: $run (oneway.csv, result.json, meta.json; msg_loss=$msg_loss)"
if [ "$CLOCK" = "realtime" ]; then
    echo "REMINDER: these are TRUE one-way figures, valid only to the accuracy of the PTP"
    echo "          synchronisation. meta.json records this host's offset; combine it with the"
    echo "          pub host's before quoting a p50. Any NEGATIVE sample means the clocks were"
    echo "          not synchronised and the tool will have said so above."
fi
