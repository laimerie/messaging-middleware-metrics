#!/usr/bin/env bash
# smoke-test.sh - end-to-end sanity check of the whole pipeline:
#   image builds -> dds_bench runs -> endpoints discover and match -> results captured.
# Run this once after setup, before attempting full-scale benchmark runs.
#
# It checks three things in increasing order of fragility:
#   1) same-process pub/sub (--mode both) with the default SIMPLE discovery. If this fails,
#      the image or the tool is broken, not the environment.
#   2) cross-CONTAINER pub/sub with SIMPLE discovery. This is the one that fails on many
#      Docker setups, because it needs UDP multicast to cross a bridge network. A failure
#      here is reported as a WARNING, not an error - it tells you to use --discovery server
#      for cross-container work, which is exactly what bench-crosshost.sh already defaults
#      to. Nothing else in the project depends on it.
#   3) the Discovery Server path, if step 2 failed - proving there IS a working
#      cross-container configuration before you start a real run.
#
# Usage:
#   ./scripts/smoke-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

assert_docker_running

echo "1) Building the dds-bench image (first build compiles Fast DDS from source)..."
ensure_image_built

run="$(new_run_dir smoke sanity)"
echo "   Run dir: $run"

echo
echo "2) Same-process pub/sub, 1000 msgs, SIMPLE discovery..."
mkdir -p "$run/same-process"
same_exit=0
docker_run_and_copy_out "$run/same-process" dds-bench dds_bench \
    --measure throughput --mode both --topic SMOKE_TEST --msgs 1000 --size 128 \
    --rate 2000 --reliability reliable --out /out || same_exit=$?
# --reliability reliable on purpose: a smoke test should assert that every message arrived,
# which is only a meaningful assertion when delivery was actually promised. Under the
# project default (BEST_EFFORT) loss is legal, so "0 lost" would prove nothing.

same_received="$(jq -r '.msgs_received // 0' "$run/same-process/result.json" 2>/dev/null || echo 0)"
echo "   received: $same_received / 1000 expected (exit $same_exit)"

if [ "$same_exit" -ne 0 ] || [ "$same_received" != "1000" ]; then
    echo
    echo "SMOKE TEST FAILED at step 2 - the tool cannot deliver messages to itself." >&2
    echo "This is an image/tool problem, not an environment one. See the output above." >&2
    exit 1
fi

echo
echo "3) Cross-container pub/sub, 1000 msgs, SIMPLE discovery (multicast over the Docker bridge)..."
mkdir -p "$run/cross-container-simple"
cd "$PROJECT_ROOT"

( DOCKER_RUN_TIMEOUT=90 docker_run_and_copy_out "$run/cross-container-simple/sub" \
    dds-bench dds_bench --measure throughput --mode sub --topic SMOKE_CROSS \
    --msgs 1000 --size 128 --reliability reliable --out /out ) &
sub_pid=$!
sleep 2
cross_pub_exit=0
docker_run_and_copy_out "$run/cross-container-simple/pub" \
    dds-bench dds_bench --measure throughput --mode pub --topic SMOKE_CROSS \
    --msgs 1000 --size 128 --rate 2000 --reliability reliable --out /out || cross_pub_exit=$?
wait "$sub_pid" || true

cross_received="$(jq -r '.msgs_received // 0' "$run/cross-container-simple/sub/result.json" 2>/dev/null || echo 0)"
echo "   received: $cross_received / 1000 expected (pub exit $cross_pub_exit)"

multicast_ok=true
if [ "$cross_received" != "1000" ]; then
    multicast_ok=false
    echo
    echo "   WARNING: cross-container SIMPLE discovery did not work in this environment."
    echo "   This is a Docker networking limitation (UDP multicast across a bridge), not a"
    echo "   Fast DDS fault, and it is exactly why bench-crosshost.sh defaults to"
    echo "   --discovery server. Verifying that path now..."

    echo
    echo "4) Cross-container pub/sub via the Discovery Server..."
    mkdir -p "$run/cross-container-server"
    DISCOVERY="server"
    ensure_discovery_server

    ( DOCKER_RUN_TIMEOUT=90 docker_run_and_copy_out "$run/cross-container-server/sub" \
        dds-bench dds_bench --measure throughput --mode sub --topic SMOKE_CROSS_DS \
        --msgs 1000 --size 128 --reliability reliable \
        --discovery server --discovery-server-address "$DS_ADDRESS" \
        --discovery-server-port "$DS_PORT" --out /out ) &
    ds_sub_pid=$!
    sleep 2
    ds_pub_exit=0
    docker_run_and_copy_out "$run/cross-container-server/pub" \
        dds-bench dds_bench --measure throughput --mode pub --topic SMOKE_CROSS_DS \
        --msgs 1000 --size 128 --rate 2000 --reliability reliable \
        --discovery server --discovery-server-address "$DS_ADDRESS" \
        --discovery-server-port "$DS_PORT" --out /out || ds_pub_exit=$?
    wait "$ds_sub_pid" || true

    ds_received="$(jq -r '.msgs_received // 0' "$run/cross-container-server/sub/result.json" 2>/dev/null || echo 0)"
    echo "   received: $ds_received / 1000 expected (pub exit $ds_pub_exit)"

    if [ "$ds_received" != "1000" ]; then
        echo
        echo "SMOKE TEST FAILED - neither multicast nor the Discovery Server delivered" >&2
        echo "messages across containers. Cross-container benchmarks will not work here." >&2
        echo "Same-host runs (bench-throughput.sh, bench-latency-oneway.sh, bench-latency.sh," >&2
        echo "bench-scalability.sh) are unaffected and still usable." >&2
        exit 1
    fi
fi

echo
echo "SMOKE TEST PASSED. Results in: $run"
echo "  same-process pub/sub:               OK"
if [ "$multicast_ok" = true ]; then
    echo "  cross-container, SIMPLE discovery:  OK (multicast works here)"
else
    echo "  cross-container, SIMPLE discovery:  NOT WORKING (multicast blocked - expected on many Docker setups)"
    echo "  cross-container, Discovery Server:  OK  <- use --discovery server for cross-container runs"
fi
