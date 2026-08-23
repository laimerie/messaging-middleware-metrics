#!/bin/sh
# Generic entrypoint for the dds-bench image: the same image runs `dds_bench ...` (the
# benchmark tool) and `fast-discovery-server ...` (the optional Discovery Server), so
# ENTRYPOINT cannot hardcode one binary — callers name it explicitly.
#
# If NETEM_DELAY_MS is set (and > 0), tries to inject an artificial one-way network delay
# via `tc netem` before running the real command. Same-Docker-host containers otherwise
# talk over a near-zero-latency virtual bridge (veth), not a physical NIC, so without this
# a "cross-host" run reproduces none of the network cost of real host-to-host traffic.
# Requires `cap_add: [NET_ADMIN]` (set in docker-compose.yml).
#
# KNOWN LIMITATION, inherited verbatim from nats/ where it was confirmed: Docker Desktop
# for Windows' bundled WSL2/Hyper-V kernel has no sch_netem qdisc module. Plain `tc` works
# (`tc qdisc add ... pfifo` succeeds) but `tc qdisc add ... netem` fails with "RTNETLINK
# answers: No such file or directory" regardless of capabilities. That is a host-kernel
# limitation, unfixable from inside a container, and it works on a real Linux Docker host.
# Rather than hard-failing a whole run over an optional enhancement, this is non-fatal:
# print a clear warning and continue WITHOUT the injected delay.
set -e

# /out is where dds_bench writes result.json / oneway.csv / rtt.csv / throughput.csv.
# Results are retrieved with `docker cp` rather than a `-v` bind mount (so a remote Docker
# daemon works too — see scripts/common.sh's docker_run_and_copy_out), which means nothing
# creates /out automatically. Without this, C++ std::ofstream fails to open its output
# files SILENTLY (it does not throw), so the tool prints a normal-looking summary while
# writing nothing at all.
mkdir -p /out

if [ -n "$NETEM_DELAY_MS" ] && [ "$NETEM_DELAY_MS" -gt 0 ] 2>/dev/null; then
    echo "entrypoint: attempting to inject ${NETEM_DELAY_MS}ms netem delay on eth0" >&2
    if ! tc qdisc add dev eth0 root netem delay "${NETEM_DELAY_MS}ms" 2>/tmp/netem-error.log; then
        echo "entrypoint: WARNING - netem delay injection failed, continuing WITHOUT it:" >&2
        cat /tmp/netem-error.log >&2
        echo "entrypoint: (known limitation on Docker Desktop/WSL2 - sch_netem kernel module missing)" >&2
    fi
fi

exec "$@"
