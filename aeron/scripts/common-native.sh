#!/usr/bin/env bash
# common-native.sh - running the benchmark WITHOUT Docker.
#
# Sourced on top of common.sh, which it reuses wholesale for everything that is not
# Docker-specific (the shared knobs, new_run_dir, run-index.csv, loss_is_failure, ...):
#
#     source "$SCRIPT_DIR/common.sh"
#     source "$SCRIPT_DIR/common-native.sh"
#
# WHY THIS EXISTS
#
# The PTP-synchronised server pair this project needs for a true cross-server one-way
# measurement cannot run Docker. So aeron_bench and aeronmd are built in the CentOS 7 image as
# usual - preserving the gcc 11 / C++17 runtime that every nats/ and fast-dds/ number was also
# measured under, which is the whole basis of cross-middleware comparability - and then shipped
# as a relocatable tarball by scripts/package-native.sh.
#
# This is not a downgrade for measurement quality. It is an upgrade: every container-vs-host
# caveat (cgroup CPU quota throttling the busy-spinning driver threads, CAP_SYS_NICE not being
# in Docker's default capability set, the seccomp syscall filter, namespaced net.* sysctls that
# compose cannot set under network_mode: host) simply does not apply here.
#
# WHAT THE CONTAINER WAS SILENTLY DOING FOR US, THAT NOW HAS TO BE DONE BY HAND
#
#   1. Killing the driver.     `docker compose run` tore the container down on exit. Nothing
#                              does that here, and with the default --driver-idle noop an
#                              orphaned aeronmd busy-spins THREE cores at 100% indefinitely.
#                              native_driver_up installs a trap for this; it is the single
#                              most important line in this file.
#   2. A fresh AERON_DIR.      Every container run started clean, which is why entrypoint.sh
#                              can set AERON_DIR_DELETE_ON_START unconditionally. On a shared
#                              server a live driver may already own it, so the native path
#                              refuses instead of deleting (aeron_driver_assert_free).
#   3. Getting results out.    No `docker cp`, so aeron_bench writes straight into the run
#                              directory. docker_run_and_copy_out is not used at all here.
#   4. A known-good runtime.   Hence native_preflight.

# The tarball keeps the repo's own layout, so these paths are identical in both:
#   <root>/bin/{aeron_bench,aeronmd}   <root>/lib/{*.so,aeron-driver.sh}   <root>/scripts/
# The binaries carry RPATH $ORIGIN/../lib, so lib/ resolves with no LD_LIBRARY_PATH.
AERON_NATIVE_ROOT="${AERON_NATIVE_ROOT:-$PROJECT_ROOT}"
AERON_NATIVE_BIN="$AERON_NATIVE_ROOT/bin"

# Prefer the shipped binaries; fall back to PATH so a host that installed Aeron itself works.
if [ -x "$AERON_NATIVE_BIN/aeron_bench" ]; then
    PATH="$AERON_NATIVE_BIN:$PATH"
    export PATH
fi

# The media driver's lifecycle, shared verbatim with docker/aeron-bench/entrypoint.sh. Sourcing
# rather than reimplementing is the point: the three idle strategies it sets move measured p50
# by 8-14x, and a second copy would eventually drift from this one.
# shellcheck source=../lib/aeron-driver.sh
source "$AERON_NATIVE_ROOT/lib/aeron-driver.sh"

FORCE_CLEAN=0

native_preflight() {
    # Everything that must be true before a number produced here means anything. Cheap, and it
    # runs before the driver starts so failures land somewhere obvious.
    local failed=0

    local arch; arch="$(uname -m)"
    if [ "$arch" != "x86_64" ]; then
        echo "ERROR: this package is built for x86_64, but this host is $arch." >&2
        echo "       The binaries will not run. Rebuild the image on a $arch host." >&2
        failed=1
    fi

    for tool in jq awk; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "ERROR: $tool is required and not on PATH." >&2
            failed=1
        fi
    done

    for binary in aeron_bench aeronmd; do
        if ! command -v "$binary" >/dev/null 2>&1; then
            echo "ERROR: $binary not found (looked in $AERON_NATIVE_BIN and \$PATH)." >&2
            failed=1
            continue
        fi
        # The decisive check, and the reason it is here rather than in a comment: the package
        # was built against glibc 2.17 (CentOS 7). That is the OLD-to-NEW direction, which is
        # the safe one - glibc and libstdc++ are backward compatible, so a newer host provides
        # every symbol version this needs. `ldd` is what proves it on THIS host rather than in
        # principle.
        if ldd "$(command -v "$binary")" 2>/dev/null | grep -q "not found"; then
            echo "ERROR: $binary has unresolved shared libraries on this host:" >&2
            ldd "$(command -v "$binary")" 2>/dev/null | grep "not found" >&2
            echo "       If a GLIBC_* version is named, this host is OLDER than the CentOS 7" >&2
            echo "       build environment (glibc 2.17) and the package cannot run here." >&2
            failed=1
        fi
    done

    [ "$failed" -eq 0 ] || exit 1
}

native_warn_about_firewall() {
    # Aeron has NO DISCOVERY, so a blocked UDP port does not produce a connection error - it
    # produces a run that receives zero messages and then times out. Worth one line up front,
    # because the symptom points nowhere near the cause.
    local ports="$1"
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        echo "NOTE: firewalld is active. UDP $ports must be open in BOTH directions." >&2
        echo "      Aeron has no discovery: a blocked port shows up as 'received 0 messages'," >&2
        echo "      never as a connection error." >&2
    fi
}

ptp_offset_ns() {
    # Best-effort read of the current PTP offset from the local ptp4l, via linuxptp's pmc.
    # Echoes nothing if it cannot be determined - the caller records null rather than guessing.
    #
    # This value is not decoration: with --clock realtime, the residual offset between the two
    # servers IS the error bar on every latency number in the run. A one-way figure recorded
    # without it cannot be interpreted afterwards.
    command -v pmc >/dev/null 2>&1 || return 0
    pmc -u -b 0 'GET TIME_STATUS_NP' 2>/dev/null \
        | awk '/master_offset/ { print $2; exit }'
}

native_driver_up() {
    # Starts the media driver for this host, with the same configuration the container uses.
    aeron_driver_defaults

    if [ "$FORCE_CLEAN" = "1" ]; then
        echo "NOTE: --force-clean given; a stale $AERON_DIR will be deleted on driver start." >&2
        export AERON_DIR_DELETE_ON_START=true
    elif ! aeron_driver_assert_free; then
        exit 1
    fi
    export AERON_DIR_DELETE_ON_SHUTDOWN=true

    aeron_driver_check_shm

    # THE line this file exists for. Without it, Ctrl-C or any `set -e` failure leaves aeronmd
    # busy-spinning three cores on this server forever, with nothing to point at the cause.
    # EXIT alone is not enough under `set -e` plus a signal, so all three are trapped.
    trap 'aeron_driver_stop' EXIT INT TERM

    aeron_driver_start || exit 1
}

native_run_bench() {
    # native_run_bench <run_dir> <command...>
    # e.g. native_run_bench "$run" aeron_bench --measure latency --mode sub ...
    #
    # The native counterpart of common.sh's docker_run_and_copy_out, and it takes the same
    # shape (destination first, then the whole command) so the two call sites read alike. The
    # difference is that there is nothing to copy: without a container there is no /out to
    # retrieve from, so the tool writes result.json and oneway.csv straight into the run
    # directory. Returns the command's exit code.
    local dest="$1"; shift
    mkdir -p "$dest"
    local exit_code=0
    "$@" --out "$dest" || exit_code=$?
    return "$exit_code"
}

save_meta_native() {
    # save_meta_native <dir> <tool_version> <params_json> <ptp_json>
    #
    # A separate function rather than a flag on save_meta because the two disagree about every
    # field that matters: common.sh's version records image:"aeron-bench:local" and
    # "aeronmd in-container", and a native run recorded that way would be a result file that
    # lies about how it was produced.
    local dir="$1" tool_version="$2" params_json="$3" ptp_json="${4:-null}"
    jq -n \
        --arg ts "$(date -Iseconds)" \
        --argjson params "$params_json" \
        --arg tool "$tool_version" \
        --arg driver "aeronmd native (no container), threading=$DRIVER_THREADING, idle=$DRIVER_IDLE" \
        --arg host "$(uname -srm) / $(hostname)" \
        --argjson ptp "$ptp_json" \
        '{timestamp:$ts, params:$params, client_tool:$tool, image:"none (native binaries)",
          server:$driver, host:$host, ptp:$ptp}' \
        > "$dir/meta.json"
}
