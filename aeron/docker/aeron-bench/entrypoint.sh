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
set -e

AERON_DIR="${AERON_DIR:-/dev/shm/aeron}"
export AERON_DIR

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
    # Sanity-check the space available where the term buffers will be mapped, BEFORE
    # starting anything. Docker gives a container a 64MB /dev/shm by default, and Aeron's
    # default term length is tens of megabytes PER PUBLICATION (three terms are mapped per
    # publication, plus the CnC and loss-report files). 64MB is not enough for even one, and
    # the resulting failure is an opaque mmap error deep in the driver rather than anything
    # naming /dev/shm. docker-compose.yml sets shm_size for exactly this reason; this check
    # exists so that a caller running the image WITHOUT compose still gets told why.
    shm_kb="$(df -k "$(dirname "$AERON_DIR")" 2>/dev/null | awk 'NR==2 {print $2}')"
    if [ -n "$shm_kb" ] && [ "$shm_kb" -lt 262144 ] 2>/dev/null; then
        echo "entrypoint: WARNING - $(dirname "$AERON_DIR") is only $((shm_kb / 1024))MB." >&2
        echo "entrypoint: Aeron maps three term buffers per publication there; the Docker" >&2
        echo "entrypoint: default of 64MB is too small. Use docker-compose.yml (it sets" >&2
        echo "entrypoint: shm_size) or pass --shm-size=1g." >&2
    fi

    mkdir -p "$AERON_DIR"
    # --dir-delete-on-start: a driver whose previous run was killed leaves its files behind,
    # and the next driver refuses to start against them ("active driver detected"). Every
    # run here gets a fresh container anyway, so there is never a driver worth preserving.
    export AERON_DIR_DELETE_ON_START=true
    export AERON_DIR_DELETE_ON_SHUTDOWN=true
    # DEDICATED = one thread each for the conductor, sender and receiver. This is Aeron's
    # low-latency configuration and the one its published numbers use; SHARED and
    # SHARED_NETWORK trade latency for cores. Overridable from the environment so a
    # benchmark can measure the difference deliberately (bench-* scripts expose
    # --driver-threading).
    export AERON_THREADING_MODE="${AERON_THREADING_MODE:-DEDICATED}"

    # The driver's IDLE STRATEGIES, and this is the single highest-impact setting in the
    # whole project. Aeron's default is BackoffIdleStrategy: after some spins and yields an
    # idle driver thread PARKS for up to a millisecond, so a message arriving into an idle
    # sender waits for that park to expire. Measured here, same host, 1000 msgs/s over UDP
    # loopback, changing nothing else:
    #
    #     backoff (Aeron's default)   p50 245-331us
    #     noop    (busy spin)         p50  21-41us    <- a consistent 8-14x
    #
    # Both numbers are "Aeron"; they answer different questions. `noop` is what Aeron's own
    # published figures use and what a latency-sensitive deployment runs, so it is the
    # default here - the same call fast-dds/ made when it overrode Fast DDS's 3-second
    # heartbeat period, and for the same reason: leaving the stock value in place would mean
    # every measurement described the idle policy instead of the transport.
    #
    # It is not free. `noop` busy-spins all three driver threads, i.e. three whole cores in
    # DEDICATED mode. Pass --driver-idle backoff to any bench-*.sh to measure the
    # out-of-the-box behaviour, or on a core-starved machine.
    export AERON_CONDUCTOR_IDLE_STRATEGY="${AERON_CONDUCTOR_IDLE_STRATEGY:-noop}"
    export AERON_SENDER_IDLE_STRATEGY="${AERON_SENDER_IDLE_STRATEGY:-noop}"
    export AERON_RECEIVER_IDLE_STRATEGY="${AERON_RECEIVER_IDLE_STRATEGY:-noop}"

    aeronmd > /tmp/aeronmd.log 2>&1 &
    driver_pid=$!

    # Wait for the CnC file, not for a fixed sleep: the client's Aeron::connect() maps this
    # file, and attempting it before the driver has created it throws.
    waited=0
    while [ ! -f "$AERON_DIR/cnc.dat" ]; do
        if ! kill -0 "$driver_pid" 2>/dev/null; then
            echo "entrypoint: ERROR - the Aeron media driver exited during startup:" >&2
            cat /tmp/aeronmd.log >&2
            exit 1
        fi
        if [ "$waited" -ge 100 ]; then
            echo "entrypoint: ERROR - no $AERON_DIR/cnc.dat after 10s. Driver log:" >&2
            cat /tmp/aeronmd.log >&2
            exit 1
        fi
        waited=$((waited + 1))
        sleep 0.1
    done
    echo "entrypoint: Aeron media driver up (pid $driver_pid, dir $AERON_DIR, threading ${AERON_THREADING_MODE}, idle ${AERON_SENDER_IDLE_STRATEGY})" >&2

    # Not `exec` here, unlike the no-driver path: this shell has to outlive the command so
    # it can stop the driver afterwards. Leaving aeronmd running would keep the container
    # alive past the benchmark and hang `docker compose run`.
    "$@"
    status=$?
    kill "$driver_pid" 2>/dev/null || true
    wait "$driver_pid" 2>/dev/null || true
    exit "$status"
fi

exec "$@"
