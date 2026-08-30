#!/bin/sh
# Generic entrypoint for the aeron-bench image. Two jobs, in this order:
#
#   1. Start the Aeron MEDIA DRIVER for this container, unless told not to.
#   2. Optionally inject artificial network latency via `tc netem`.
#   3. exec whatever command the caller named (`aeron_bench ...`, `aeronmd`, a shell).
#
# WHY THE DRIVER LIVES IN THIS CONTAINER
#
# Aeron is not daemonless. Every host running an Aeron application also runs a media
# driver: the process that owns the UDP sockets, the term buffers, and the flow-control
# state. Applications talk to it through memory-mapped files in AERON_DIR, not through a
# socket.
#
# It is NOT a broker. It never sits between two hosts — each host has its own, and data
# goes driver-to-driver over UDP, or app-to-app through shared memory for aeron:ipc.
# "One driver per container" is therefore the accurate model of "one driver per host", and
# it is what makes bench-crosshost.sh a genuine two-driver measurement rather than two
# processes sharing one transport.
#
# It also removes the alternative's failure mode. Sharing one driver between containers
# would mean sharing AERON_DIR through a Docker volume, and Aeron's files are mmap'd: if
# the volume turns out not to be a single shared tmpfs (which depends on the volume driver
# and is not something the caller can see), the two sides map different memory, discover
# nothing, and the run reports zero messages with no error anywhere.
#
# The driver's actual configuration and startup sequence are NOT here - they live in
# /usr/local/lib/aeron-driver.sh (aeron/lib/aeron-driver.sh in the repo), because
# scripts/common-native.sh has to start the same driver the same way on the PTP servers that
# cannot run Docker. One copy, two callers: the three idle strategies it sets move measured
# p50 by 8-14x, and two copies of that would eventually disagree.
set -e

. /usr/local/lib/aeron-driver.sh

aeron_driver_defaults

# /out is where aeron_bench writes result.json / oneway.csv / rtt.csv / throughput.csv.
# Results are retrieved with `docker cp` rather than a `-v` bind mount (so a remote Docker
# daemon works too — see scripts/common.sh's docker_run_and_copy_out), which means nothing
# creates /out automatically. Without this, C++ std::ofstream fails to open its output
# files SILENTLY (it does not throw), so the tool prints a normal-looking summary while
# writing nothing at all.
mkdir -p /out

if [ -n "$NETEM_DELAY_MS" ] && [ "$NETEM_DELAY_MS" -gt 0 ] 2>/dev/null; then
    # Same-Docker-host containers otherwise talk over a near-zero-latency virtual bridge
    # (veth), not a physical NIC, so without this a "cross-host" run reproduces none of the
    # network cost of real host-to-host traffic. Requires cap_add: [NET_ADMIN].
    #
    # KNOWN LIMITATION, inherited verbatim from nats/ and fast-dds/ where it was confirmed:
    # Docker Desktop for Windows' bundled WSL2/Hyper-V kernel has no sch_netem qdisc module.
    # Plain `tc` works but `tc qdisc add ... netem` fails with "RTNETLINK answers: No such
    # file or directory" regardless of capabilities. Host-kernel limitation, unfixable from
    # inside a container, works on a real Linux Docker host. Non-fatal on purpose: warn and
    # continue WITHOUT the injected delay rather than losing a whole run to an optional
    # enhancement.
    echo "entrypoint: attempting to inject ${NETEM_DELAY_MS}ms netem delay on eth0" >&2
    if ! tc qdisc add dev eth0 root netem delay "${NETEM_DELAY_MS}ms" 2>/tmp/netem-error.log; then
        echo "entrypoint: WARNING - netem delay injection failed, continuing WITHOUT it:" >&2
        cat /tmp/netem-error.log >&2
        echo "entrypoint: (known limitation on Docker Desktop/WSL2 - sch_netem kernel module missing)" >&2
    fi
fi

# AERON_NO_DRIVER=1 for callers that ARE the driver (`aeronmd`) or that deliberately want
# to attach to a driver started elsewhere.
if [ "${AERON_NO_DRIVER:-0}" != "1" ] && [ "$1" != "aeronmd" ]; then
    # Checked before starting anything, so that a caller running this image WITHOUT compose
    # (which sets shm_size) is told why rather than hitting an opaque mmap error.
    aeron_driver_check_shm

    # A driver whose previous run was killed leaves its files behind, and the next driver
    # refuses to start against them ("active driver detected"). Unconditional here, and ONLY
    # here: every container run starts fresh, so there is never a driver worth preserving.
    # The native path must not assume that - see aeron_driver_assert_free().
    export AERON_DIR_DELETE_ON_START=true
    export AERON_DIR_DELETE_ON_SHUTDOWN=true

    aeron_driver_start || exit 1

    # Not `exec` here, unlike the no-driver path: this shell has to outlive the command so
    # it can stop the driver afterwards. Leaving aeronmd running would keep the container
    # alive past the benchmark and hang `docker compose run`.
    "$@"
    status=$?
    aeron_driver_stop
    exit "$status"
fi

exec "$@"
