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
# The big structural difference from nats/scripts/common.sh: Fast DDS is daemonless, so
# there is no server to health-check and no /varz to read versions from. Everything runs
# inside the dds-bench container, which also means there is no host-side CLI to install
# (nats/ needed install-nats-cli.sh; there is no counterpart here).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_ROOT="$PROJECT_ROOT/results"

# Only meaningful when these scripts are run from Git Bash on Windows during development;
# completely inert on the real Linux target, which has no MSYS layer to configure.
#
# Git Bash's MSYS layer rewrites arguments that look like absolute POSIX paths into Windows
# paths before exec. `dds_bench --out /out` names a directory INSIDE the container, but MSYS
# cannot know that and turns it into something like "C:/Program Files/Git/out". The tool
# then writes its results to a path that does not exist in the container, C++
# std::ofstream fails silently (it does not throw), and `docker cp` finds nothing - so the
# run prints a perfectly normal summary while producing no result.json at all. Confirmed
# here, and previously in nats/ (see nats/TODO.md #3).
#
# Excluding only arguments beginning with "/out" is the narrow fix: MSYS_NO_PATHCONV=1 would
# also stop converting `docker cp`'s destination, which is a real Windows path and DOES need
# converting.
export MSYS2_ARG_CONV_EXCL="/out"

# Discovery Server coordinates. The address is fixed in docker-compose.yml rather than
# resolved by name because Fast DDS locators are IP addresses - a hostname cannot be put
# into a locator at all. Keep these two in sync if you change the compose network.
DS_ADDRESS="172.28.0.10"
DS_PORT=11811
DS_CONTAINER="fast-dds-discovery"

# ---------------------------------------------------------------------------------------
# Shared benchmark knobs
#
# Every bench-*.sh exposes the same QoS / transport / discovery flags, defaulted here once.
# The defaults are chosen to be the closest apples-to-apples match for NATS Core rather
# than to show Fast DDS at its best: BEST_EFFORT + VOLATILE matches NATS Core's
# at-most-once, fire-and-forget delivery, and UDPv4 keeps the data on a real network
# transport instead of shared memory. Override per run to measure DDS's own strengths
# (--reliability reliable, --transport shm).
# ---------------------------------------------------------------------------------------
RELIABILITY="best_effort"
DURABILITY="volatile"
HISTORY="keep_last"
HISTORY_DEPTH=100
TRANSPORT="udp"
DISCOVERY="simple"
DOMAIN=0
INTRAPROCESS="off"

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
    # run this in a subshell, and the QoS assignments would be thrown away with it.
    COMMON_ARG_CONSUMED=0
    case "$1" in
        --reliability)   RELIABILITY="$2";   COMMON_ARG_CONSUMED=2 ;;
        --durability)    DURABILITY="$2";    COMMON_ARG_CONSUMED=2 ;;
        --history)       HISTORY="$2";       COMMON_ARG_CONSUMED=2 ;;
        --history-depth) HISTORY_DEPTH="$2"; COMMON_ARG_CONSUMED=2 ;;
        --transport)     TRANSPORT="$2";     COMMON_ARG_CONSUMED=2 ;;
        --discovery)     DISCOVERY="$2";     COMMON_ARG_CONSUMED=2 ;;
        --domain)        DOMAIN="$2";        COMMON_ARG_CONSUMED=2 ;;
        --intraprocess)  INTRAPROCESS="$2";  COMMON_ARG_CONSUMED=2 ;;
    esac
    [ "$COMMON_ARG_CONSUMED" -gt 0 ]
}

dds_common_args() {
    # Echoes the shared flags one per line, for `mapfile -t common < <(dds_common_args)`.
    printf '%s\n' --reliability "$RELIABILITY" --durability "$DURABILITY" \
        --history "$HISTORY" --history-depth "$HISTORY_DEPTH" \
        --transport "$TRANSPORT" --discovery "$DISCOVERY" --domain "$DOMAIN" \
        --intraprocess "$INTRAPROCESS"
    if [ "$DISCOVERY" = "server" ]; then
        printf '%s\n' --discovery-server-address "$DS_ADDRESS" \
            --discovery-server-port "$DS_PORT"
    fi
}

common_params_json() {
    # The shared knobs as a JSON object, merged into every run's meta.json/result.json
    # params so a result is always self-describing about the QoS it was measured under.
    jq -n \
        --arg reliability "$RELIABILITY" --arg durability "$DURABILITY" \
        --arg history "$HISTORY" --argjson historyDepth "$HISTORY_DEPTH" \
        --arg transport "$TRANSPORT" --arg discovery "$DISCOVERY" \
        --argjson domain "$DOMAIN" --arg intraprocess "$INTRAPROCESS" \
        '{reliability:$reliability, durability:$durability, history:$history,
          historyDepth:$historyDepth, transport:$transport, discovery:$discovery,
          domain:$domain, intraprocess:$intraprocess}'
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
    # The dds-bench image is the whole runtime for this project - there is no host-side
    # CLI. Building is a no-op once cached, but the FIRST build compiles Fast DDS from
    # source on CentOS 7 and takes a while; say so rather than looking hung.
    cd "$PROJECT_ROOT"
    if ! docker image inspect fast-dds-bench:local >/dev/null 2>&1; then
        echo "Building the dds-bench image for the first time (compiles Fast DDS from source; this takes several minutes)..."
    fi
    docker compose build dds-bench
}

ensure_discovery_server() {
    # Only relevant when --discovery server was requested. Starts the Discovery Server
    # container if it isn't already running; a no-op otherwise. Safe to call repeatedly.
    if [ "$DISCOVERY" != "server" ]; then
        return 0
    fi
    cd "$PROJECT_ROOT"
    if [ "$(docker inspect -f '{{.State.Running}}' "$DS_CONTAINER" 2>/dev/null)" = "true" ]; then
        return 0
    fi
    echo "Starting the Fast DDS Discovery Server ($DS_ADDRESS:$DS_PORT)..."
    docker compose --profile discovery up -d discovery-server
    # No health endpoint to poll (unlike NATS's /varz) - fast-discovery-server has no
    # monitoring interface. A short settle is enough: participants that connect before it
    # is listening retry discovery anyway.
    sleep 2
    if [ "$(docker inspect -f '{{.State.Running}}' "$DS_CONTAINER" 2>/dev/null)" != "true" ]; then
        echo "ERROR: the Discovery Server container failed to stay up. Check: docker compose --profile discovery logs discovery-server" >&2
        exit 1
    fi
}

tool_version() {
    # Reads the version string straight out of a run's result.json, so meta.json records
    # what actually produced the numbers rather than a hardcoded guess.
    local result_json="$1"
    if [ -f "$result_json" ]; then
        jq -r '[.environment.dds_bench_version, ("Fast DDS " + (.environment.fastdds_version // "?")), .environment.runtime] | join(" / ")' \
            "$result_json" 2>/dev/null && return 0
    fi
    echo "dds_bench (version unknown - result.json missing)"
}

save_meta() {
    # save_meta <dir> <tool_version> <params_json>
    # Writes meta.json: the parameters used plus reproducibility info. Fast DDS being
    # daemonless, there is no server version to record - the client tool version IS the
    # middleware version, since Fast DDS is linked into the measuring binary.
    local dir="$1" tool_version="$2" params_json="$3"
    jq -n \
        --arg ts "$(date -Iseconds)" \
        --argjson params "$params_json" \
        --arg tool "$tool_version" \
        '{timestamp:$ts, params:$params, client_tool:$tool, image:"fast-dds-bench:local", server:"none (Fast DDS is daemonless)"}' \
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
    # The column set is IDENTICAL to nats/results/run-index.csv on purpose: a sparse common
    # schema across categories (throughput runs leave the latency columns blank and vice
    # versa) that also lines up column-for-column with the NATS side, so the two projects'
    # index files can be concatenated for a direct middleware comparison.
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
    # dds_bench writes the full result.json itself (unlike the NATS side, where the CLI
    # emitted CSV and bash re-derived every metric). The scripts therefore only lift the
    # summary columns back out for run-index.csv - the metrics are computed in exactly one
    # place, in the tool, not duplicated in two languages.
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

loss_is_failure() {
    # Whether a non-zero msg_loss should fail the run.
    #
    # This is a REAL semantic difference from nats/, not a relaxed check. NATS Core runs
    # over TCP: any message loss there means something broke. Fast DDS under BEST_EFFORT is
    # defined to drop samples a subscriber cannot keep up with, and a saturation throughput
    # test is *expected* to lose - failing on that would make every default run "fail" while
    # telling you nothing. Under RELIABLE, delivery was promised, so loss is a real failure.
    # tools/dds_bench/main.cpp applies the identical rule to its own exit code.
    [ "$RELIABILITY" = "reliable" ]
}

docker_run_and_copy_out() {
    # docker_run_and_copy_out <destination_dir> <docker compose "run" args...>
    # e.g. docker_run_and_copy_out "$run/pub" dds-bench dds_bench --mode pub ...
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
    local container_name="ddsbench-$$-$RANDOM"
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
