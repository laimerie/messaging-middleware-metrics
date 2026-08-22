#!/bin/sh
# Generic entrypoint for the latency-tool image: this image now doubles as a general
# "host client" container (TODO.md #3) and runs either `latency_oneway ...` or
# `nats bench ...`, so ENTRYPOINT can no longer hardcode one binary.
#
# If NETEM_DELAY_MS is set (and > 0), tries to inject an artificial one-way network delay
# via `tc netem` before running the real command - this approximates real inter-host
# network latency, since same-Docker-host containers otherwise communicate over a
# near-zero-latency virtual bridge (veth), not a physical NIC (see TODO.md #3).
# Requires the container to run with `cap_add: [NET_ADMIN]` (set in docker-compose.yml).
#
# KNOWN LIMITATION (confirmed on this project's environment - TODO.md #3): Docker
# Desktop for Windows' bundled WSL2/Hyper-V kernel does not have the sch_netem qdisc
# module compiled in. Plain `tc` works fine (e.g. `tc qdisc add ... pfifo` succeeds) but
# `tc qdisc add ... netem` fails with "RTNETLINK answers: No such file or directory"
# regardless of capabilities. This is a host-kernel limitation, not something fixable
# from inside the container - it would work on a real Linux Docker host. Rather than
# hard-failing the whole run over an optional enhancement, this is treated as non-fatal:
# print a clear warning and continue WITHOUT the injected delay.
set -e

# /out is where latency_oneway / nats bench --csv write their results. It used to be
# auto-created by Docker as a bind-mount point (`-v <host>:/out`); now that results are
# retrieved via `docker cp` instead (works with a remote Docker daemon too - see
# scripts/common.sh's docker_run_and_copy_out), nothing creates it automatically, so
# do it here. Without this, the tools fail to open their output files silently (C++
# ofstream doesn't throw) and `docker cp` finds nothing to copy.
mkdir -p /out

if [ -n "$NETEM_DELAY_MS" ] && [ "$NETEM_DELAY_MS" -gt 0 ] 2>/dev/null; then
    echo "entrypoint: attempting to inject ${NETEM_DELAY_MS}ms netem delay on eth0" >&2
    if ! tc qdisc add dev eth0 root netem delay "${NETEM_DELAY_MS}ms" 2>/tmp/netem-error.log; then
        echo "entrypoint: WARNING - netem delay injection failed, continuing WITHOUT it:" >&2
        cat /tmp/netem-error.log >&2
        echo "entrypoint: (known limitation on Docker Desktop/WSL2 - sch_netem kernel module missing; see TODO.md #3)" >&2
    fi
fi

exec "$@"
