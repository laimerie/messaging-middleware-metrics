#!/usr/bin/env bash
# common.sh - shared helpers, sourced by the other scripts in this folder.
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
# Requires: docker, docker compose, jq, awk (all standard on any Linux box; on
# Debian/Ubuntu: apt-get install -y jq gawk; on RHEL/CentOS: yum install -y jq gawk).
#
# This project targets a real Linux host - see README.md. No Windows-only tooling here, and
# every path uses '/'.
#
# Two structural differences from the sibling projects' common.sh:
#
#   * There is no start-server.sh / stop-server.sh (nats/) and no
#     start-discovery-server.sh (fast-dds/). Aeron's media driver is not a shared service:
#     one runs inside each bench container, started by docker/aeron-bench/entrypoint.sh.
#     Nothing has to be brought up before a run.
#   * There is no discovery knob at all. Aeron addresses peers by literal endpoint in a
#     channel URI, so the cross-container scripts need the addresses below rather than a
#     rendezvous mechanism.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_ROOT="$PROJECT_ROOT/results"

# Only meaningful when these scripts are run from Git Bash on Windows during development;
# completely inert on the real Linux target, which has no MSYS layer to configure.
#
# Git Bash's MSYS layer rewrites arguments that look like absolute POSIX paths into Windows
# paths before exec. Two of those appear here and BOTH name a path inside the container:
# `--out /out` (where results are written) and `--aeron-dir /dev/shm/aeron` (where the media
# driver's memory-mapped files live). MSYS cannot know that, and turns them into something
# like "C:/Program Files/Git/out". The tool then writes nowhere - C++ std::ofstream fails
# silently, it does not throw - so the run prints a normal summary and produces no
# result.json. Confirmed in nats/ (TODO.md #3) and again in fast-dds/.
#
# Excluding only these prefixes is the narrow fix: MSYS_NO_PATHCONV=1 would also stop
# converting `docker cp`'s destination, which is a real Windows path and DOES need it.
export MSYS2_ARG_CONV_EXCL="/out;/dev/shm"

# ---------------------------------------------------------------------------------------
# Addressing
#
# Aeron has NO DISCOVERY. A channel is a URI naming a literal endpoint, so anything that
# crosses a container boundary needs an address known in advance. These must match the
# static ipv4_address entries in docker-compose.yml.
#
#   A = the subscriber / echo side   B = the publisher / ping side
#
# Same-container runs (--mode both) use loopback: there is one media driver, and the data
# still goes through it and through the kernel's UDP stack, so this is a real transport
# measurement rather than an in-process shortcut. (Aeron has no equivalent of Fast DDS's
# intra-process delivery bypass - see aeron/CLAUDE.md.)
# ---------------------------------------------------------------------------------------
LOCAL_ENDPOINT="${LOCAL_ENDPOINT:-127.0.0.1:40456}"
LOCAL_RESPONSE_ENDPOINT="${LOCAL_RESPONSE_ENDPOINT:-127.0.0.1:40457}"
CROSS_A_ADDRESS="${CROSS_A_ADDRESS:-172.29.0.20}"
CROSS_B_ADDRESS="${CROSS_B_ADDRESS:-172.29.0.21}"
CROSS_PORT="${CROSS_PORT:-40456}"
CROSS_RESPONSE_PORT="${CROSS_RESPONSE_PORT:-40457}"

# ---------------------------------------------------------------------------------------
# Shared benchmark knobs
#
# Every bench-*.sh exposes the same transport / QoS / consumption flags, defaulted here
# once. As in fast-dds/, the defaults are chosen to make a fair comparison possible rather
# than to show Aeron at its best:
#
#   --transport udp    a real network transport, not shared memory. `ipc` is Aeron's
#                      fastest path by a wide margin and has no NATS Core counterpart, so
#                      it is opt-in, exactly as fast-dds/'s --transport shm is.
#   --reliable yes     Aeron's default: lost datagrams are NAK'd and retransmitted.
#
# --poll-idle is the one knob with no counterpart in either sibling project, and it is not
# a tuning detail: Aeron does not call you back, your loop polls it, so how that loop waits
# IS part of the latency being measured. `busy` is the configuration Aeron's published
# numbers use and the one a latency-sensitive deployment would run; it costs a core per
# subscriber. Use `yield` when sweeping subscriber counts past the core count.
# ---------------------------------------------------------------------------------------
TRANSPORT="udp"
RELIABLE="yes"
STREAM_ID=1001
TERM_LENGTH=""       # empty = Aeron's default
MTU=""               # empty = Aeron's default (1408)
PUBLICATION="exclusive"
POLL_IDLE="busy"
POLL_IDLE_SLEEP_US=50
FRAGMENT_LIMIT=10
# How the publisher waits out each send interval. "auto" sleeps for the bulk of a long
# interval and busy-spins the last 200us, so a requested rate is actually achieved: under a
# sleep-only approach a requested 10000/s delivered ~5500/s on this repo's Fast DDS side,
# meaning runs silently measured a rate other than the one they reported.
PACING="auto"
# The media driver's threading mode, passed to the container as AERON_THREADING_MODE.
#   DEDICATED       conductor + sender + receiver on their own threads. Lowest latency,
#                   costs 3 cores. Aeron's published numbers use this.
#   SHARED_NETWORK  sender and receiver share a thread.
#   SHARED          all three share one thread. Cheapest, worst latency.
# This has no counterpart in nats/ or fast-dds/ - it is a property of having a driver at all.
DRIVER_THREADING="DEDICATED"
# How the media driver's threads wait when they have nothing to do. THE highest-impact
# setting in this project, by a wide margin. Aeron's own default is `backoff`, which parks
# an idle thread for up to a millisecond; a message arriving into a parked sender waits out
# that park. Measured here (same host, 1000 msgs/s, UDP loopback, nothing else changed):
#
#     --driver-idle backoff   p50 245-331us  (Aeron's out-of-the-box default)
#     --driver-idle noop      p50  21-41us   a consistent 8-14x faster
#
# `noop` is the default here because it is what Aeron's published numbers use and what a
# latency-sensitive deployment runs - leaving the stock value would mean every measurement
# described the idle policy rather than the transport. It costs three busy-spun cores in
# DEDICATED mode. Use `backoff` to measure out-of-the-box behaviour or on few cores.
DRIVER_IDLE="noop"
# Simulated per-message application work on the subscriber side. Under Fast DDS BEST_EFFORT
# raising this shows up as msg_loss; under Aeron it shows up as back-pressure on the
# publisher with loss still zero, because flow control is receiver-driven.
SUB_WORK_US=0

COMMON_ARG_CONSUMED=0

parse_common_arg() {
    # parse_common_arg "$1" "${2:-}"
    # Handles the flags shared by every bench-*.sh. Sets COMMON_ARG_CONSUMED to how many
    # argv entries it took and returns 0 (success) if it recognised the flag; returns 1 if
    # the caller must handle it itself. Used as:
    #
    #     if parse_common_arg "$1" "${2:-}"; then shift "$COMMON_ARG_CONSUMED"; continue; fi
    #
    # It deliberately reports through a global rather than stdout: a `$(...)` call would
    # run this in a subshell, and the assignments would be thrown away with it. (Learned
    # the hard way in fast-dds/ - see that project's TODO.md.)
    COMMON_ARG_CONSUMED=0
    case "$1" in
        --transport)          TRANSPORT="$2";          COMMON_ARG_CONSUMED=2 ;;
        --reliable)           RELIABLE="$2";           COMMON_ARG_CONSUMED=2 ;;
        --stream-id)          STREAM_ID="$2";          COMMON_ARG_CONSUMED=2 ;;
        --term-length)        TERM_LENGTH="$2";        COMMON_ARG_CONSUMED=2 ;;
        --mtu)                MTU="$2";                COMMON_ARG_CONSUMED=2 ;;
        --publication)        PUBLICATION="$2";        COMMON_ARG_CONSUMED=2 ;;
        --poll-idle)          POLL_IDLE="$2";          COMMON_ARG_CONSUMED=2 ;;
        --poll-idle-sleep-us) POLL_IDLE_SLEEP_US="$2"; COMMON_ARG_CONSUMED=2 ;;
        --fragment-limit)     FRAGMENT_LIMIT="$2";     COMMON_ARG_CONSUMED=2 ;;
        --pacing)             PACING="$2";             COMMON_ARG_CONSUMED=2 ;;
        --sub-work-us)        SUB_WORK_US="$2";        COMMON_ARG_CONSUMED=2 ;;
        --driver-threading)   DRIVER_THREADING="$2";   COMMON_ARG_CONSUMED=2 ;;
        --driver-idle)        DRIVER_IDLE="$2";        COMMON_ARG_CONSUMED=2 ;;
    esac
    [ "$COMMON_ARG_CONSUMED" -gt 0 ]
}

aeron_common_args() {
    # Echoes the shared flags one per line, for `mapfile -t common < <(aeron_common_args)`.
    printf '%s\n' --transport "$TRANSPORT" --reliable "$RELIABLE" \
        --stream-id "$STREAM_ID" --publication "$PUBLICATION" \
        --poll-idle "$POLL_IDLE" --poll-idle-sleep-us "$POLL_IDLE_SLEEP_US" \
        --fragment-limit "$FRAGMENT_LIMIT" --pacing "$PACING" --sub-work-us "$SUB_WORK_US"
    # Empty means "leave Aeron's default alone" - passing --term-length "" would be an
    # invalid URI parameter rather than a no-op.
    if [ -n "$TERM_LENGTH" ]; then printf '%s\n' --term-length "$TERM_LENGTH"; fi
    if [ -n "$MTU" ]; then printf '%s\n' --mtu "$MTU"; fi
}

driver_env_args() {
    # Echoes the `docker compose run` -e flags that configure the media driver started by
    # docker/aeron-bench/entrypoint.sh. The driver is configured by environment, not by CLI
    # flags, so this cannot go through aeron_common_args.
    #
    # All three idle strategies are set together: leaving one on the default would put a
    # millisecond-scale park back into the path and quietly undo the setting.
    printf '%s\n' -e "AERON_THREADING_MODE=$DRIVER_THREADING" \
        -e "AERON_CONDUCTOR_IDLE_STRATEGY=$DRIVER_IDLE" \
        -e "AERON_SENDER_IDLE_STRATEGY=$DRIVER_IDLE" \
        -e "AERON_RECEIVER_IDLE_STRATEGY=$DRIVER_IDLE"
}

common_params_json() {
    # The shared knobs as a JSON object, merged into every run's meta.json params so a
    # result is always self-describing about the conditions it was measured under.
    jq -n \
        --arg transport "$TRANSPORT" --arg reliable "$RELIABLE" \
        --argjson streamId "$STREAM_ID" --arg termLength "$TERM_LENGTH" --arg mtu "$MTU" \
        --arg publication "$PUBLICATION" --arg pollIdle "$POLL_IDLE" \
        --argjson pollIdleSleepUs "$POLL_IDLE_SLEEP_US" \
        --argjson fragmentLimit "$FRAGMENT_LIMIT" --arg pacing "$PACING" \
        --argjson subWorkUs "$SUB_WORK_US" --arg driverThreading "$DRIVER_THREADING" \
        --arg driverIdle "$DRIVER_IDLE" \
        '{transport:$transport, reliable:$reliable, streamId:$streamId,
          termLength:$termLength, mtu:$mtu, publication:$publication, pollIdle:$pollIdle,
          pollIdleSleepUs:$pollIdleSleepUs, fragmentLimit:$fragmentLimit, pacing:$pacing,
          subWorkUs:$subWorkUs, driverThreading:$driverThreading, driverIdle:$driverIdle}'
}

new_run_dir() {
    # Creates results/<category>/<yyyyMMdd-HHmmss>_<label>/ and echoes its full path.
    # Never overwrites a prior run - each call gets a fresh timestamped folder.
    local category="$1" label="$2"
    local timestamp safe_label dir
    timestamp="$(date +%Y%m%d-%H%M%S)"
    safe_label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_')"
    dir="$RESULTS_ROOT/$category/${timestamp}_${safe_label}"
    mkdir -p "$dir"
    printf '%s\n' "$dir"
}

assert_docker_running() {
    if ! docker info >/dev/null 2>&1; then
        echo "ERROR: Docker does not appear to be running. Start it and try again." >&2
        exit 1
    fi
}

ensure_image_built() {
    # The aeron-bench image is the whole runtime for this project - there is no host-side
    # CLI and nothing to install on the host. Building is a no-op once cached, but the
    # FIRST build compiles Aeron from source on CentOS 7 and takes a while; say so rather
    # than looking hung.
    cd "$PROJECT_ROOT"
    if ! docker image inspect aeron-bench:local >/dev/null 2>&1; then
        echo "Building the aeron-bench image for the first time (compiles Aeron from source; this takes several minutes)..."
    fi
    docker compose build aeron-bench
}

tool_version() {
    # Reads the version string straight out of a run's result.json, so meta.json records
    # what actually produced the numbers rather than a hardcoded guess.
    local result_json="$1"
    if [ -f "$result_json" ]; then
        jq -r '[.environment.aeron_bench_version, ("Aeron " + (.environment.aeron_version // "?")), .environment.runtime] | join(" / ")' \
            "$result_json" 2>/dev/null && return 0
    fi
    echo "aeron_bench (version unknown - result.json missing)"
}

save_meta() {
    # save_meta <dir> <tool_version> <params_json>
    # Writes meta.json: the parameters used plus reproducibility info.
    #
    # `server` records the media driver rather than "none": unlike Fast DDS, Aeron is not
    # daemonless, and the driver's threading mode materially affects every number in the
    # run - so it belongs in the reproducibility record.
    local dir="$1" tool_version="$2" params_json="$3"
    jq -n \
        --arg ts "$(date -Iseconds)" \
        --argjson params "$params_json" \
        --arg tool "$tool_version" \
        --arg driver "aeronmd in-container, threading=$DRIVER_THREADING, idle=$DRIVER_IDLE" \
        '{timestamp:$ts, params:$params, client_tool:$tool, image:"aeron-bench:local", server:$driver}' \
        > "$dir/meta.json"
}

csv_escape_field() {
    # Quotes a single CSV field if it contains a comma, quote, or newline.
    local v="$1"
    if [[ "$v" == *[,\"$'\n']* ]]; then
        v="${v//\"/\"\"}"
        printf '"%s"' "$v"
    else
        printf '%s' "$v"
    fi
}

add_run_index_entry() {
    # add_run_index_entry <dir> <category> <label> <metrics_json>
    # Appends one row to results/run-index.csv (created with a header on first use).
    # The column set is IDENTICAL to nats/results/run-index.csv and
    # fast-dds/results/run-index.csv on purpose: a sparse common schema across categories
    # (throughput runs leave the latency columns blank and vice versa) that also lines up
    # column-for-column with the other two projects, so the three index files can be
    # concatenated for a direct middleware comparison. Do not add a column here without
    # adding it to both siblings.
    local dir="$1" category="$2" label="$3" metrics_json="$4"
    local index_path="$RESULTS_ROOT/run-index.csv"
    local run_id rel_dir timestamp
    run_id="$(basename "$dir")"
    rel_dir="${dir#"$PROJECT_ROOT"/}"
    timestamp="$(date -Iseconds)"

    local columns=(run_id category label timestamp pub_msgs_per_sec pub_mb_per_sec \
        sub_msgs_per_sec sub_mb_per_sec p50_latency_us p99_latency_us msg_loss run_dir)

    local pub_mps pub_mbps sub_mps sub_mbps p50 p99 loss
    pub_mps="$(printf '%s' "$metrics_json" | jq -r '.pub_msgs_per_sec // empty')"
    pub_mbps="$(printf '%s' "$metrics_json" | jq -r '.pub_mb_per_sec // empty')"
    sub_mps="$(printf '%s' "$metrics_json" | jq -r '.sub_msgs_per_sec // empty')"
    sub_mbps="$(printf '%s' "$metrics_json" | jq -r '.sub_mb_per_sec // empty')"
    p50="$(printf '%s' "$metrics_json" | jq -r '.p50_latency_us // empty')"
    p99="$(printf '%s' "$metrics_json" | jq -r '.p99_latency_us // empty')"
    loss="$(printf '%s' "$metrics_json" | jq -r '.msg_loss // empty')"

    local values=("$run_id" "$category" "$label" "$timestamp" "$pub_mps" "$pub_mbps" \
        "$sub_mps" "$sub_mbps" "$p50" "$p99" "$loss" "$rel_dir")

    if [ ! -f "$index_path" ]; then
        (IFS=,; echo "${columns[*]}") > "$index_path"
    fi
    local line="" field
    for field in "${values[@]}"; do
        if [ -n "$line" ]; then line+=","; fi
        line+="$(csv_escape_field "$field")"
    done
    echo "$line" >> "$index_path"
}

index_from_result_json() {
    # index_from_result_json <result.json path> <run dir> <category> <label>
    # aeron_bench writes the full result.json itself (like dds_bench, and unlike the NATS
    # side where the official CLI emitted CSV and bash re-derived every metric). The scripts
    # therefore only lift the summary columns back out for run-index.csv - the metrics are
    # computed in exactly one place, in the tool, not duplicated in two languages.
    # Echoes the msg_loss value; returns non-zero if the file is missing.
    local result_json="$1" dir="$2" category="$3" label="$4"
    if [ ! -f "$result_json" ]; then
        echo "0"
        return 1
    fi
    local metrics
    metrics="$(jq '{
        pub_msgs_per_sec: (.metrics.pub.msgs_per_sec // null),
        pub_mb_per_sec:   (.metrics.pub.mb_per_sec // null),
        sub_msgs_per_sec: (.metrics.sub.msgs_per_sec // null),
        sub_mb_per_sec:   (.metrics.sub.mb_per_sec // null),
        p50_latency_us:   (.metrics.latency_us.p50 // null),
        p99_latency_us:   (.metrics.latency_us.p99 // null),
        msg_loss:         (.msg_loss // null)
    }' "$result_json")"
    add_run_index_entry "$dir" "$category" "$label" "$metrics"
    jq -r '.msg_loss // 0' "$result_json"
}

report_back_pressure() {
    # report_back_pressure <result.json path>
    # Prints the Aeron-only line that a throughput number is incomplete without.
    #
    # Under NATS Core (TCP) and Fast DDS BEST_EFFORT, "how fast did the publisher go" is a
    # publisher-side property. Under Aeron it is not: flow control is receiver-driven and
    # always on, so a publisher that outruns its slowest subscriber is held back rather than
    # dropping. Back-pressure events are therefore the difference between "this is how fast
    # Aeron can publish" and "this is how fast that subscriber could consume" - and the two
    # produce the same msgs/sec figure.
    local result_json="$1"
    [ -f "$result_json" ] || return 0
    local events secs
    events="$(jq -r '.metrics.pub.back_pressure_events // 0' "$result_json" 2>/dev/null || echo 0)"
    secs="$(jq -r '.metrics.pub.back_pressure_sec // 0' "$result_json" 2>/dev/null || echo 0)"
    if [ "${events:-0}" != "0" ]; then
        echo "Back-pressure: $events event(s), ${secs}s spent waiting for the subscriber."
        echo "  The publisher was limited by the SUBSCRIBER, not by Aeron's send path."
    fi
}

loss_is_failure() {
    # Whether a non-zero msg_loss should fail the run.
    #
    # A third distinct rule, and the reasoning is worth keeping straight across the repo:
    #   nats/      always a failure. NATS Core runs over TCP; loss means something broke.
    #   fast-dds/  a failure only under --reliability reliable. BEST_EFFORT is DEFINED to
    #              drop what the subscriber cannot keep up with.
    #   aeron/     a failure unless --reliable no. Aeron's flow control is always on and
    #              receiver-driven, so "the subscriber was slow" does NOT produce loss here
    #              - it produces back-pressure on the publisher. With retransmission in
    #              effect there is no benign explanation for a missing message.
    # tools/aeron_bench/main.cpp applies the identical rule to its own exit code.
    [ "$RELIABLE" != "no" ] && [ "$RELIABLE" != "false" ]
}

docker_run_and_copy_out() {
    # docker_run_and_copy_out <destination_dir> <docker compose "run" args...>
    # e.g. docker_run_and_copy_out "$run/pub" aeron-bench aeron_bench --mode pub ...
    #
    # Runs `docker compose run --name <generated> <args...>` (not --rm), then copies
    # everything the container wrote to its internal /out directory back to
    # <destination_dir> via `docker cp`, before removing the container. This replaces a
    # `-v <local>:/out` bind mount: a bind-mount path is resolved by the DOCKER DAEMON, not
    # by whoever runs the `docker` command, so it silently breaks the moment the daemon is
    # remote (e.g. `docker context` over SSH). `docker cp` works identically for local and
    # remote daemons.
    #
    # If DOCKER_RUN_TIMEOUT is set (seconds, >0), the `docker compose run` step is wrapped
    # in `timeout` - needed for a backgrounded subscriber side that must not hang forever
    # if the publisher side fails.
    local dest="$1"; shift
    mkdir -p "$dest"
    local container_name="aeronbench-$$-$RANDOM"
    local exit_code=0

    if [ -n "${DOCKER_RUN_TIMEOUT:-}" ] && [ "${DOCKER_RUN_TIMEOUT:-0}" -gt 0 ] 2>/dev/null; then
        timeout "$DOCKER_RUN_TIMEOUT" docker compose run --name "$container_name" "$@" || exit_code=$?
    else
        docker compose run --name "$container_name" "$@" || exit_code=$?
    fi

    docker cp "${container_name}:/out/." "$dest" 2>/dev/null || true
    docker rm "$container_name" >/dev/null 2>&1 || true

    return "$exit_code"
}
