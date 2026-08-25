#!/usr/bin/env bash
# smoke-test.sh - end-to-end sanity check of the whole pipeline:
#   image builds -> media driver starts -> aeron_bench runs -> endpoints connect ->
#   results captured.
# Run this once after setup, before attempting full-scale benchmark runs.
#
# It checks four things in increasing order of fragility:
#   1) the media driver comes up at all. This is the Aeron-specific failure that every other
#      step depends on, and its usual cause is environmental rather than a bug: Docker gives
#      a container a 64MB /dev/shm by default, and Aeron maps three term buffers per
#      publication there. docker-compose.yml sets shm_size for this; the check exists to
#      catch a setup that bypassed it.
#   2) same-container pub/sub over UDP loopback. If this fails, the image or the tool is
#      broken, not the environment.
#   3) aeron:ipc in the same container. Exercises the shared-memory path, which skips the
#      driver's sender/receiver threads entirely.
#   4) cross-CONTAINER pub/sub, two separate media drivers over the bridge network. This is
#      the one with an environmental dependency - the static addresses in
#      docker-compose.yml have to actually be assigned, because Aeron has no discovery to
#      fall back on. A failure here is a hard failure: unlike fast-dds/'s multicast check,
#      there is no alternative mechanism to steer you to.
#
# Usage:
#   ./scripts/smoke-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

assert_docker_running

echo "1) Building the aeron-bench image (first build compiles Aeron from source)..."
ensure_image_built

run="$(new_run_dir smoke sanity)"
echo "   Run dir: $run"

cd "$PROJECT_ROOT"
mapfile -t driver_env < <(driver_env_args)

echo
echo "2) Media driver startup and /dev/shm sizing..."
shm_mb="$(docker compose run --rm --no-deps aeron-bench sh -c 'df -m /dev/shm | awk "NR==2 {print \$2}"' 2>/dev/null | tr -d '\r')"
echo "   /dev/shm in the bench container: ${shm_mb:-unknown}MB"
if [ -n "${shm_mb:-}" ] && [ "$shm_mb" -lt 256 ] 2>/dev/null; then
    echo
    echo "SMOKE TEST FAILED at step 2 - /dev/shm is only ${shm_mb}MB." >&2
    echo "Aeron maps three term buffers per publication there; the Docker default of 64MB is" >&2
    echo "too small and the driver will fail with an opaque mmap error. docker-compose.yml" >&2
    echo "sets shm_size: 1gb - check it was not overridden." >&2
    exit 1
fi

echo
echo "3) Same-container pub/sub over UDP loopback, 1000 msgs..."
mkdir -p "$run/loopback-udp"
udp_exit=0
docker_run_and_copy_out "$run/loopback-udp" "${driver_env[@]}" aeron-bench aeron_bench \
    --measure throughput --mode both --endpoint "$LOCAL_ENDPOINT" \
    --msgs 1000 --size 128 --rate 2000 --out /out || udp_exit=$?

udp_received="$(jq -r '.msgs_received // 0' "$run/loopback-udp/result.json" 2>/dev/null || echo 0)"
echo "   received: $udp_received / 1000 expected (exit $udp_exit)"

if [ "$udp_exit" -ne 0 ] || [ "$udp_received" != "1000" ]; then
    echo
    echo "SMOKE TEST FAILED at step 3 - the tool cannot deliver messages to itself." >&2
    echo "This is an image/tool problem, not an environment one. See the output above." >&2
    exit 1
fi

echo
echo "4) Same-container pub/sub over aeron:ipc (shared memory), 1000 msgs..."
mkdir -p "$run/loopback-ipc"
ipc_exit=0
docker_run_and_copy_out "$run/loopback-ipc" "${driver_env[@]}" aeron-bench aeron_bench \
    --measure throughput --mode both --transport ipc \
    --msgs 1000 --size 128 --rate 2000 --out /out || ipc_exit=$?

ipc_received="$(jq -r '.msgs_received // 0' "$run/loopback-ipc/result.json" 2>/dev/null || echo 0)"
echo "   received: $ipc_received / 1000 expected (exit $ipc_exit)"

if [ "$ipc_exit" -ne 0 ] || [ "$ipc_received" != "1000" ]; then
    echo
    echo "SMOKE TEST FAILED at step 4 - aeron:ipc did not deliver." >&2
    echo "UDP worked, so the driver is fine; this points at the shared-memory path." >&2
    exit 1
fi

echo
echo "5) Cross-container pub/sub, two media drivers over the bridge, 1000 msgs..."
mkdir -p "$run/cross-container"
cross_endpoint="${CROSS_A_ADDRESS}:${CROSS_PORT}"
echo "   subscriber binds $cross_endpoint (static address from docker-compose.yml)"

( DOCKER_RUN_TIMEOUT=120 docker_run_and_copy_out "$run/cross-container/sub" \
    "${driver_env[@]}" aeron-bench-a aeron_bench --measure throughput --mode sub \
    --endpoint "$cross_endpoint" --msgs 1000 --size 128 --out /out ) &
sub_pid=$!
sleep 3
cross_pub_exit=0
docker_run_and_copy_out "$run/cross-container/pub" \
    "${driver_env[@]}" aeron-bench-b aeron_bench --measure throughput --mode pub \
    --endpoint "$cross_endpoint" --msgs 1000 --size 128 --rate 2000 --out /out \
    || cross_pub_exit=$?
wait "$sub_pid" || true

cross_received="$(jq -r '.msgs_received // 0' "$run/cross-container/sub/result.json" 2>/dev/null || echo 0)"
echo "   received: $cross_received / 1000 expected (pub exit $cross_pub_exit)"

if [ "$cross_received" != "1000" ]; then
    echo
    echo "SMOKE TEST FAILED at step 5 - messages did not cross the container boundary." >&2
    echo "Aeron has no discovery, so this is almost always an addressing problem rather than" >&2
    echo "a transport one. Check that aeron-bench-a really got $CROSS_A_ADDRESS:" >&2
    echo "  docker compose run --rm aeron-bench-a hostname -i" >&2
    echo "If the subnet 172.29.0.0/24 collides with something on this host, change it in" >&2
    echo "docker-compose.yml AND CROSS_A_ADDRESS/CROSS_B_ADDRESS in scripts/common.sh." >&2
    echo "Same-container runs (bench-throughput.sh, bench-latency-oneway.sh, bench-latency.sh," >&2
    echo "bench-scalability.sh) are unaffected and still usable." >&2
    exit 1
fi

echo
echo "SMOKE TEST PASSED. Results in: $run"
echo "  media driver + /dev/shm sizing:     OK (${shm_mb}MB)"
echo "  same-container, UDP loopback:       OK"
echo "  same-container, aeron:ipc:          OK"
echo "  cross-container, two drivers:       OK"
