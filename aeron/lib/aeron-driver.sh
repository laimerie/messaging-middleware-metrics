#!/bin/sh
# aeron-driver.sh - the Aeron media driver's lifecycle, in ONE place.
#
# WHY THIS FILE EXISTS AT ALL, AND WHY IT IS NOT UNDER scripts/
#
# The driver has to be started two different ways in this project:
#
#   in a container   docker/aeron-bench/entrypoint.sh, for every docker compose run
#   natively         scripts/common-native.sh, for the PTP-synchronised server pair that
#                    cannot run Docker at all (see README.md)
#
# The configuration it applies is the single highest-impact setting in this project - the
# three idle strategies below move measured p50 latency by 8-14x - so having two copies of it
# would mean one of them silently drifting and every number measured under it being wrong in
# a way that looks fine. Hence: one file, sourced by both.
#
# It lives at aeron/lib/ rather than aeron/scripts/ because .dockerignore excludes scripts/
# from the build context (deliberately, to keep builds fast against a remote daemon), and
# the image needs this file. Do not move it under scripts/ without also dealing with that.
#
# POSIX sh, not bash: entrypoint.sh is #!/bin/sh. Keep it that way so both callers work.
#
# Sourced, not executed:
#   . "$SOME_DIR/aeron-driver.sh"

# ---------------------------------------------------------------------------------------
# aeron_driver_defaults
#
# Exports AERON_DIR and the driver's configuration. Every variable is set with ${VAR:-...}
# so a caller that already exported one (scripts/common.sh's driver_env_args, or a bare
# `docker run -e`) wins.
# ---------------------------------------------------------------------------------------
aeron_driver_defaults() {
    AERON_DIR="${AERON_DIR:-/dev/shm/aeron}"
    export AERON_DIR

    # DEDICATED = one thread each for the conductor, sender and receiver. This is Aeron's
    # low-latency configuration and the one its published numbers use; SHARED and
    # SHARED_NETWORK trade latency for cores.
    export AERON_THREADING_MODE="${AERON_THREADING_MODE:-DEDICATED}"

    # THE highest-impact setting in this project. Aeron's default is BackoffIdleStrategy:
    # after some spins and yields an idle driver thread PARKS for up to a millisecond, so a
    # message arriving into an idle sender waits for that park to expire. Measured here, same
    # host, 1000 msgs/s over UDP loopback, changing nothing else:
    #
    #     backoff (Aeron's default)   p50 245-331us
    #     noop    (busy spin)         p50  21-41us    <- a consistent 8-14x
    #
    # Both numbers are "Aeron"; they answer different questions. `noop` is what Aeron's own
    # published figures use and what a latency-sensitive deployment runs, so it is the default
    # here - the same call fast-dds/ made when it overrode Fast DDS's 3-second heartbeat
    # period, and for the same reason: leaving the stock value in place would mean every
    # measurement described the idle policy instead of the transport.
    #
    # It is not free. `noop` busy-spins all three driver threads, i.e. three whole cores in
    # DEDICATED mode. Pass --driver-idle backoff to any bench-*.sh to measure the
    # out-of-the-box behaviour, or on a core-starved machine.
    #
    # ALL THREE MUST BE SET TOGETHER. Leaving one on the default puts the millisecond park
    # back into the path and quietly undoes the setting.
    export AERON_CONDUCTOR_IDLE_STRATEGY="${AERON_CONDUCTOR_IDLE_STRATEGY:-noop}"
    export AERON_SENDER_IDLE_STRATEGY="${AERON_SENDER_IDLE_STRATEGY:-noop}"
    export AERON_RECEIVER_IDLE_STRATEGY="${AERON_RECEIVER_IDLE_STRATEGY:-noop}"
}

# ---------------------------------------------------------------------------------------
# aeron_driver_check_shm
#
# Aeron maps THREE term buffers per publication into AERON_DIR's filesystem, at the default
# term length of tens of megabytes each, plus the CnC and loss-report files. Docker's default
# /dev/shm is 64MB, which is not enough for even one publication, and the resulting failure is
# an opaque mmap error deep inside the driver that never mentions /dev/shm.
#
# Warns rather than failing: a caller may legitimately be running with a small --term-length.
# A real Linux host defaults /dev/shm to half of RAM, so this normally passes there - it is
# kept in the shared path anyway because hardened hosts do sometimes shrink it, and the
# failure mode is just as opaque there as in a container.
# ---------------------------------------------------------------------------------------
aeron_driver_check_shm() {
    shm_dir="$(dirname "$AERON_DIR")"
    shm_kb="$(df -k "$shm_dir" 2>/dev/null | awk 'NR==2 {print $2}')"
    if [ -n "$shm_kb" ] && [ "$shm_kb" -lt 262144 ] 2>/dev/null; then
        echo "aeron-driver: WARNING - $shm_dir is only $((shm_kb / 1024))MB." >&2
        echo "aeron-driver: Aeron maps three term buffers per publication there." >&2
        echo "aeron-driver: In Docker: use docker-compose.yml (it sets shm_size) or --shm-size=1g." >&2
        echo "aeron-driver: On a real host: mount -o remount,size=1G $shm_dir" >&2
    fi
}

# ---------------------------------------------------------------------------------------
# aeron_driver_assert_free
#
# Refuses to start if something already owns AERON_DIR. THIS IS THE NATIVE-ONLY CHECK, and it
# exists because the container path's assumption does not survive the move to a real host.
#
# In a container, AERON_DIR_DELETE_ON_START=true is unconditionally safe: every run gets a
# fresh container, so there is never a driver worth preserving. On a bare server that
# assumption is simply false - a driver left over from an interrupted run, or someone else's
# run, may be live right now. Deleting the memory-mapped files out from under a running driver
# does not produce an error; it produces corruption, and then a benchmark result.
#
# Detection is deliberately conservative. Reading the CnC file's heartbeat would mean parsing
# Aeron's binary layout in shell, which would rot at the next version bump. So: if the CnC
# file is there at all, stop and make a human decide. `fuser`/`pgrep` are used only to make
# the message more specific, never to decide it is safe to proceed.
# ---------------------------------------------------------------------------------------
aeron_driver_assert_free() {
    [ -f "$AERON_DIR/cnc.dat" ] || return 0

    echo "aeron-driver: ERROR - $AERON_DIR/cnc.dat already exists." >&2
    if command -v fuser >/dev/null 2>&1 && fuser "$AERON_DIR/cnc.dat" >/dev/null 2>&1; then
        echo "aeron-driver: A LIVE PROCESS currently holds it:" >&2
        fuser -v "$AERON_DIR/cnc.dat" >&2 2>/dev/null || true
    elif command -v pgrep >/dev/null 2>&1 && pgrep -x aeronmd >/dev/null 2>&1; then
        echo "aeron-driver: An aeronmd process is running (pid(s): $(pgrep -x aeronmd | tr '\n' ' '))." >&2
    else
        echo "aeron-driver: No live holder detected - this is most likely a leftover from an" >&2
        echo "aeron-driver: interrupted run, but that cannot be confirmed from shell." >&2
    fi
    echo "aeron-driver:" >&2
    echo "aeron-driver: Deleting these files while a driver is using them corrupts it SILENTLY" >&2
    echo "aeron-driver: and the corruption surfaces as benchmark numbers, not as an error." >&2
    echo "aeron-driver: Either stop the driver, or re-run with --force-clean if you are certain" >&2
    echo "aeron-driver: nothing is using $AERON_DIR." >&2
    return 1
}

# ---------------------------------------------------------------------------------------
# aeron_driver_start
#
# Starts aeronmd in the background and blocks until it is actually usable. Sets
# AERON_DRIVER_PID on success.
#
# Set AERON_DIR_DELETE_ON_START=true beforehand to have the driver clear a stale directory
# (the container path does; the native path only does so after --force-clean).
# ---------------------------------------------------------------------------------------
aeron_driver_start() {
    AERON_DRIVER_LOG="${AERON_DRIVER_LOG:-/tmp/aeronmd.log}"

    if ! command -v aeronmd >/dev/null 2>&1; then
        echo "aeron-driver: ERROR - aeronmd is not on PATH." >&2
        return 1
    fi

    mkdir -p "$AERON_DIR"
    aeronmd > "$AERON_DRIVER_LOG" 2>&1 &
    AERON_DRIVER_PID=$!

    # Wait for the CnC file, not for a fixed sleep: the client's Aeron::connect() maps this
    # file, and attempting it before the driver has created it throws.
    waited=0
    while [ ! -f "$AERON_DIR/cnc.dat" ]; do
        if ! kill -0 "$AERON_DRIVER_PID" 2>/dev/null; then
            echo "aeron-driver: ERROR - the Aeron media driver exited during startup:" >&2
            cat "$AERON_DRIVER_LOG" >&2
            return 1
        fi
        if [ "$waited" -ge 100 ]; then
            echo "aeron-driver: ERROR - no $AERON_DIR/cnc.dat after 10s. Driver log:" >&2
            cat "$AERON_DRIVER_LOG" >&2
            aeron_driver_stop
            return 1
        fi
        waited=$((waited + 1))
        sleep 0.1
    done

    echo "aeron-driver: media driver up (pid $AERON_DRIVER_PID, dir $AERON_DIR," \
         "threading ${AERON_THREADING_MODE}, idle ${AERON_SENDER_IDLE_STRATEGY})" >&2
}

# ---------------------------------------------------------------------------------------
# aeron_driver_stop
#
# Idempotent, and safe to call from a trap. Getting this wrong is a bigger deal natively than
# it looks: with the default --driver-idle noop the driver busy-spins THREE cores, so an
# aeronmd that outlives its script does not idle quietly in the background - it pins three
# cores at 100% on that server until someone notices. In a container `docker compose run`
# cleaned up for us; natively nothing does.
# ---------------------------------------------------------------------------------------
aeron_driver_stop() {
    [ -n "${AERON_DRIVER_PID:-}" ] || return 0
    kill "$AERON_DRIVER_PID" 2>/dev/null || true
    wait "$AERON_DRIVER_PID" 2>/dev/null || true
    AERON_DRIVER_PID=""
}
