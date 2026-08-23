#!/usr/bin/env bash
# common.sh - shared helpers, sourced by the other scripts in this folder.
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
# Requires: docker, docker compose, jq, awk, curl (all standard on any Linux box; on
# Debian/Ubuntu: apt-get install -y jq gawk curl; on RHEL/CentOS: yum install -y jq gawk curl).
#
# This project targets a real Linux host (see TODO.md #3 and README.md's "Running against
# a real Linux host" section) - no Windows-only tooling here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_ROOT="$PROJECT_ROOT/results"
NATS_SERVER_URL="nats://localhost:4222"
NATS_MONITOR_URL="http://localhost:8222"

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

assert_nats_cli_installed() {
    if ! command -v nats >/dev/null 2>&1; then
        echo "ERROR: The 'nats' CLI is not on PATH. Run ./scripts/install-nats-cli.sh first." >&2
        exit 1
    fi
}

test_nats_server_up() {
    # Polls the NATS monitoring endpoint (/varz) for up to ~timeout_sec (default 10).
    # Echoes the /varz JSON on success; on failure, prints an actionable error and
    # returns non-zero.
    local timeout_s="${1:-10}" deadline varz
    deadline=$(( $(date +%s) + timeout_s ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if varz="$(curl -fsS -m 2 "$NATS_MONITOR_URL/varz" 2>/dev/null)"; then
            printf '%s\n' "$varz"
            return 0
        fi
        sleep 0.5
    done
    echo "ERROR: NATS server not reachable at $NATS_MONITOR_URL/varz after ${timeout_s}s. Is Docker running? Try: ./scripts/start-server.sh" >&2
    return 1
}

save_meta() {
    # save_meta <dir> <tool_version> <params_json>
    # Writes meta.json into a run directory: the parameters used plus reproducibility
    # info (client tool version, server version/id from /varz, image tag, timestamp).
    local dir="$1" tool_version="$2" params_json="$3"
    local server_json server_id server_ver
    server_json="$(curl -fsS -m 2 "$NATS_MONITOR_URL/varz" 2>/dev/null || echo '{}')"
    server_id="$(printf '%s' "$server_json" | jq -r '.server_id // empty')"
    server_ver="$(printf '%s' "$server_json" | jq -r '.version // empty')"
    jq -n \
        --arg ts "$(date -Iseconds)" \
        --argjson params "$params_json" \
        --arg tool "$tool_version" \
        --arg sid "$server_id" \
        --arg sver "$server_ver" \
        '{timestamp:$ts, params:$params, client_tool:$tool, server_id:$sid, server_ver:$sver, image:"nats:2.11-alpine"}' \
        > "$dir/meta.json"
}

convert_to_nats_sleep_duration() {
    # convert_to_nats_sleep_duration <target_msgs_per_sec> <clients>
    # Echoes the per-client --sleep=DURATION value `nats bench pub` understands (Go
    # duration syntax, e.g. "12.5ms") for a target AGGREGATE publish rate across all
    # clients. `nats bench` has no direct "--rate msgs/sec" flag - --sleep is the closest
    # approximation (each client sleeps this long between its own publishes), so
    # aggregate rate ~= clients / sleepSeconds. Echoes nothing (and returns 1) if rate<=0
    # (no throttling - caller should omit --sleep entirely in that case).
    local rate="$1" clients="$2"
    awk -v r="$rate" -v c="$clients" 'BEGIN {
        if (r+0 <= 0) { exit 1 }
        printf "%.6fs", c/r
    }'
}

parse_nats_bench_csv_aggregate() {
    # parse_nats_bench_csv_aggregate <csv_path>
    # Aggregates a `nats bench --csv` output file (one row per client) into overall
    # totals, echoing "total_msgs total_bytes max_duration_secs msgs_per_sec mb_per_sec"
    # (space-separated). Duration uses the MAX across rows (clients ran concurrently), not
    # the sum. The header line is '#'-prefixed (e.g. "#RunID,ClientID,MsgCount,..."), so
    # it's skipped via `tail -n +2` rather than parsed. Echoes all zeros if the file is
    # missing or empty (e.g. `nats bench pub` failed outright - see TODO.md #5 for why
    # callers must still compare against the REQUESTED message count, not this).
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "0 0 0 0 0"
        return
    fi
    tail -n +2 "$path" | awk -F, '
        { msgs += $3; bytes += $4; if ($7 > maxdur) maxdur = $7 }
        END {
            if (maxdur > 0) {
                mps = msgs / maxdur
                mbps = (bytes / maxdur) / 1048576
            } else {
                mps = 0; mbps = 0
            }
            printf "%d %d %f %.2f %.3f", msgs+0, bytes+0, maxdur+0, mps, mbps
        }'
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
    # Appends one row to results/run-index.csv (created with a header on first use). A
    # sparse common schema across all categories - throughput/scalability runs leave the
    # latency columns blank and vice versa - so this single file supports cross-category
    # comparison without per-category index files. <metrics_json> should be a JSON object
    # that may contain any of: pub_msgs_per_sec, pub_mb_per_sec, sub_msgs_per_sec,
    # sub_mb_per_sec, p50_latency_us, p99_latency_us, msg_loss - missing keys become blank.
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

save_result() {
    # save_result <dir> <category> <label> <params_json> <metrics_json>
    # Writes result.json into a run directory (normalized metrics, per the schema agreed
    # in TODO.md #6) and appends one summary row to results/run-index.csv via
    # add_run_index_entry. Call this in addition to save_meta, not instead of it:
    # meta.json is reproducibility info (versions), result.json is the parsed metrics
    # meant for later comparison/analysis.
    local dir="$1" category="$2" label="$3" params_json="$4" metrics_json="$5"
    jq -n \
        --arg run_id "$(basename "$dir")" \
        --arg category "$category" \
        --arg label "$label" \
        --arg ts "$(date -Iseconds)" \
        --argjson params "$params_json" \
        --argjson metrics "$metrics_json" \
        '{run_id:$run_id, category:$category, label:$label, timestamp:$ts, params:$params, metrics:$metrics}' \
        > "$dir/result.json"
    add_run_index_entry "$dir" "$category" "$label" "$metrics_json"
}

docker_run_and_copy_out() {
    # docker_run_and_copy_out <destination_dir> <docker compose "run" args...>
    # e.g. docker_run_and_copy_out "$run/pub" latency-tool latency_oneway --mode pub ...
    #
    # Runs `docker compose run --name <generated> <args...>` (not --rm), then copies
    # everything the container wrote to its internal /out directory back to
    # <destination_dir> via `docker cp`, before removing the container. This replaces a
    # `-v <local>:/out` bind mount: a bind-mount path is resolved by the DOCKER DAEMON,
    # not by whoever runs the `docker` command, so it silently breaks the moment the
    # daemon is remote (e.g. `docker context` over SSH). `docker cp` works identically
    # for local and remote daemons.
    #
    # If DOCKER_RUN_TIMEOUT is set (seconds, >0) in the environment, the `docker compose
    # run` step is wrapped in `timeout` - useful for a backgrounded subscriber side that
    # must not hang forever if the publisher side fails (see bench-throughput.sh /
    # bench-crosshost.sh for the background+wait pattern this enables without any
    # PowerShell-style "safe receive" helper).
    #
    # Prints the container's own exit code on stdout as the LAST line (in addition to
    # returning it), so callers using command substitution (e.g. inside a backgrounded
    # subshell where $? alone isn't retrievable after `wait`) can still recover it.
    local dest="$1"; shift
    mkdir -p "$dest"
    local container_name="bench-$$-$RANDOM"
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
