#!/usr/bin/env bash
# Run a Direct or hierarchical Leaf fan-out experiment on two native Linux hosts.
# The Leaf tier and the sub-side server tier both run on the subscriber host, so only
# the Core->Leaf links cross the wire and the publisher NIC no longer carries one copy
# per subscriber.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

ROLE=""
MODE="direct"
PUB_HOST=""
SUB_HOST=""
LEAF_COUNT=5
SUB_SERVER_COUNT=0
SUBSCRIBER_COUNT=100
SUBJECT="BENCH.LEAF.ONEWAY"
RATE=1000
DURATION=30
SIZE=500
CLOCK="realtime"
PACING="auto"
LABEL="leaf-2host"
CPU_LIMIT=80
CPU_INTERVAL=1
CPU_CONSECUTIVE=3
PORT_OFFSET=0
NATS_SERVER_BIN="${NATS_SERVER_BIN:-$PKG_ROOT/bin/nats-server}"
TOOL="$PKG_ROOT/bin/latency_oneway"

usage() {
    sed -n 's/^# //p' "$0" | head -n 4
    cat <<'USAGE'

Usage: bench-leaf-2host-native.sh --role pub|sub --pub-host HOST [options]

Topology in leaf mode (L = --leaf-count, S = --sub-server-count, N = --subscriber-count):

    PUB host                     SUB host
    publisher                    leaf-0 .. leaf-(L-1)          remote -> PUB core leaf port
        |                            |
    core-nats  === L TCP links ==----+
                                     |
                                 subserver-0 .. subserver-(S-1)  remote -> leaf-(j mod L)
                                     |
                                 subscriber-0 .. subscriber-(N-1) -> subserver-(i mod S)

  With S = 0 the subscribers attach straight to leaf-(i mod L).

Options:
  --role pub|sub            Which host this invocation drives (required).
  --mode direct|leaf        direct: every subscriber connects to the Core on the PUB
                            host. leaf: the hierarchy above. Default: direct.
  --pub-host HOST           Address of the PUB host (required on both roles).
  --sub-host HOST           Address of the SUB host. Required for --role pub in leaf
                            mode so the publisher can confirm every subscriber is ready.
  --leaf-count L            Leaf servers on the SUB host (default: 5). 0 means direct.
  --sub-server-count S      Sub-side servers below the Leaf tier (default: 0, meaning
                            the subscribers attach straight to the Leaf tier).
  --subscriber-count N      Subscribers on the SUB host (default: 100).
  --subject SUBJECT         Subject to publish and subscribe (default: BENCH.LEAF.ONEWAY).
  --rate R                  Target messages per second (also --target-msgs-per-sec).
  --duration-sec D          Publish duration in seconds (default: 30).
  --size BYTES              Payload size, at least 24 (default: 500).
  --clock monotonic|realtime  Timestamp clock (default: realtime).
  --pacing MODE             Publisher pacing mode (default: auto).
  --cpu-limit PCT           Abort when host CPU stays at or above PCT (default: 80).
  --cpu-interval-sec SEC    Sampling interval (default: 1).
  --cpu-consecutive N       Consecutive over-limit samples before aborting (default: 3).
  --port-offset N           Added to every port so separate runs can coexist.
  --label LABEL             Result directory label.
  --nats-server PATH        nats-server binary (default: <package>/bin/nats-server).
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --pub-host) PUB_HOST="$2"; shift 2 ;;
        --sub-host) SUB_HOST="$2"; shift 2 ;;
        --leaf-count) LEAF_COUNT="$2"; shift 2 ;;
        --sub-server-count) SUB_SERVER_COUNT="$2"; shift 2 ;;
        --subscriber-count) SUBSCRIBER_COUNT="$2"; shift 2 ;;
        --subject) SUBJECT="$2"; shift 2 ;;
        --rate|--target-msgs-per-sec) RATE="$2"; shift 2 ;;
        --duration-sec) DURATION="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --clock) CLOCK="$2"; shift 2 ;;
        --pacing) PACING="$2"; shift 2 ;;
        --cpu-limit) CPU_LIMIT="$2"; shift 2 ;;
        --cpu-interval-sec) CPU_INTERVAL="$2"; shift 2 ;;
        --cpu-consecutive) CPU_CONSECUTIVE="$2"; shift 2 ;;
        --port-offset) PORT_OFFSET="$2"; shift 2 ;;
        --label) LABEL="$2"; shift 2 ;;
        --nats-server) NATS_SERVER_BIN="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ "$ROLE" == pub || "$ROLE" == sub ]] || { echo "ERROR: --role must be pub or sub" >&2; exit 1; }
[[ "$MODE" == direct || "$MODE" == leaf ]] || { echo "ERROR: --mode must be direct or leaf" >&2; exit 1; }
[[ -n "$PUB_HOST" ]] || { echo "ERROR: --pub-host is required" >&2; exit 1; }
[[ "$LEAF_COUNT" =~ ^[0-9]+$ ]] || { echo "ERROR: --leaf-count must be a non-negative integer" >&2; exit 1; }
[[ "$SUB_SERVER_COUNT" =~ ^[0-9]+$ ]] || { echo "ERROR: --sub-server-count must be a non-negative integer" >&2; exit 1; }
if [[ "$MODE" == leaf && "$LEAF_COUNT" == 0 ]]; then
    MODE="direct"
fi
if [[ "$MODE" == direct ]]; then
    # Without a Leaf tier there is nothing for a sub-side server to attach to.
    SUB_SERVER_COUNT=0
fi
[[ "$PORT_OFFSET" =~ ^[0-9]+$ ]] || { echo "ERROR: --port-offset must be a non-negative integer" >&2; exit 1; }
[[ "$SUBSCRIBER_COUNT" -gt 0 && "$RATE" -gt 0 && "$DURATION" -gt 0 && "$SIZE" -ge 24 ]] || {
    echo "ERROR: subscriber-count, rate, duration must be positive and size must be at least 24" >&2; exit 1;
}
if [[ "$ROLE" == pub && "$MODE" == leaf && -z "$SUB_HOST" ]]; then
    echo "ERROR: --sub-host is required for --role pub in leaf mode." >&2
    echo "       The Leaf and sub-side servers run on the SUB host, so the publisher has to" >&2
    echo "       reach their monitoring ports to confirm every subscriber is ready." >&2
    exit 1
fi
if ((SUB_SERVER_COUNT > 0 && SUB_SERVER_COUNT < LEAF_COUNT)); then
    echo "WARNING: --sub-server-count $SUB_SERVER_COUNT is below --leaf-count $LEAF_COUNT;" >&2
    echo "         $((LEAF_COUNT - SUB_SERVER_COUNT)) Leaf(s) will carry no downstream interest." >&2
fi
[[ -x "$TOOL" ]] || { echo "ERROR: latency_oneway was not found at $TOOL" >&2; exit 1; }
export LD_LIBRARY_PATH="$PKG_ROOT/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# The Core runs on the PUB host; every other server runs on the SUB host.
CORE_CLIENT_PORT=$((4222 + PORT_OFFSET))
CORE_MONITOR_PORT=$((8222 + PORT_OFFSET))
CORE_LEAF_PORT=$((7422 + PORT_OFFSET))
LEAF_CLIENT_BASE=$((5000 + PORT_OFFSET))
LEAF_MONITOR_BASE=$((8200 + PORT_OFFSET))
LEAF_LEAF_BASE=$((7600 + PORT_OFFSET))
SUB_SERVER_CLIENT_BASE=$((5200 + PORT_OFFSET))
SUB_SERVER_MONITOR_BASE=$((8400 + PORT_OFFSET))
NPROC="$(nproc)"
PIDS=()
APP_PIDS=()
declare -A PID_LABEL=()
declare -A PID_CATEGORY=()
# The role is part of the directory name so that both hosts can write into one shared
# results tree (NFS/NAS) without colliding when they start in the same second, and so the
# summarizer can pair a run's two halves by name.
RUN="$(new_run_dir crosshost "$LABEL-$MODE-$ROLE")"
CPU_SAMPLES="$RUN/cpu-samples.jsonl"
PROCESS_CPU_SAMPLES="$RUN/process-cpu-samples.jsonl"
SYSTEM_SAMPLES="$RUN/system-samples.jsonl"
TCP_QUEUE_SAMPLES="$RUN/tcp-queue-samples.jsonl"
TCP_QUEUE_METRICS="$RUN/tcp-queue.json"
NETDEV_SAMPLES="$RUN/netdev-samples.jsonl"
NATS_SAMPLES="$RUN/nats-samples.jsonl"
NATS_QUEUE_METRICS="$RUN/nats-queue.json"
# Scratch area for the concurrent per-server monitoring fetches; one file per server,
# rewritten every interval, so the parallel writers never interleave in nats-samples.jsonl.
SAMPLE_TMP="$RUN/.sample-tmp"
mkdir -p "$SAMPLE_TMP"

# Which local server a subscriber attaches to, and how that tier is named in metadata.
subscriber_server_port() {
    local index="$1"
    if ((SUB_SERVER_COUNT > 0)); then
        echo $((SUB_SERVER_CLIENT_BASE + index % SUB_SERVER_COUNT))
    else
        echo $((LEAF_CLIENT_BASE + index % LEAF_COUNT))
    fi
}

subscriber_assignment() {
    local index="$1"
    if [[ "$MODE" == direct ]]; then
        echo "core"
    elif ((SUB_SERVER_COUNT > 0)); then
        echo "subserver-$((index % SUB_SERVER_COUNT))"
    else
        echo "leaf-$((index % LEAF_COUNT))"
    fi
}

# Monitoring endpoints of the tier the subscribers attach to, as seen from HOST.
subscriber_tier_monitor_urls() {
    local host="$1" i
    if ((SUB_SERVER_COUNT > 0)); then
        for ((i=0; i<SUB_SERVER_COUNT; i++)); do echo "http://$host:$((SUB_SERVER_MONITOR_BASE + i))"; done
    else
        for ((i=0; i<LEAF_COUNT; i++)); do echo "http://$host:$((LEAF_MONITOR_BASE + i))"; done
    fi
}

cleanup() {
    local pid
    for pid in "${PIDS[@]:-}"; do kill -TERM "$pid" 2>/dev/null || true; done
    sleep 0.2
    for pid in "${PIDS[@]:-}"; do kill -KILL "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
    rm -rf "$SAMPLE_TMP" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cpu_total() {
    awk '/^cpu / {total=$2+$3+$4+$5+$6+$7+$8+$9; idle=$5+$6; iowait=$6; printf "%.6f %.6f %.6f\n", total, idle, iowait; exit}' /proc/stat
}

netdev_snapshot() {
    awk 'NR > 2 {gsub(/:/, "", $1); print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $10 "\t" $11 "\t" $12 "\t" $13}' /proc/net/dev
}

netdev_json() {
    netdev_snapshot | jq -Rn '[inputs | split("\t") |
        {interface:.[0],rx_bytes:(.[1]|tonumber),rx_packets:(.[2]|tonumber),
         rx_errors:(.[3]|tonumber),rx_drops:(.[4]|tonumber),tx_bytes:(.[5]|tonumber),
         tx_packets:(.[6]|tonumber),tx_errors:(.[7]|tonumber),tx_drops:(.[8]|tonumber)}]'
}

tcp_queue_snapshot() {
    ss -tinH 2>/dev/null | awk '$1 ~ /^(ESTAB|SYN-SENT|SYN-RECV|FIN-WAIT-1|FIN-WAIT-2|TIME-WAIT|CLOSE-WAIT|LAST-ACK|CLOSING|CLOSED)$/ {print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5}' |
        jq -Rn '[inputs | select(length > 0) | split("\t") |
            {state:.[0],recv_q:(.[1]|tonumber),send_q:(.[2]|tonumber),local:.[3],peer:.[4]}]'
}

# One curl fetches both endpoints, and no ?subs=1: save_nats_queue_metrics reads only the
# pending and traffic counters, and on the SUB host the subscription list would be one
# entry per subscriber per server per interval. The readiness gate still asks for subs=1.
collect_nats_sample() {
    local name="$1" url="$2" out="$3" payload
    payload="$(curl -fsS -m 1 "$url/varz" "$url/connz" 2>/dev/null || true)"
    jq -s --arg timestamp "$(date -Iseconds)" --arg server "$name" \
        '{timestamp:$timestamp,server:$server,varz:(.[0] // {}),connz:(.[1] // {})}' \
        <<<"$payload" > "$out"
}

# Each host samples only the servers it runs, so neither host has to reach across the wire
# once per interval just to collect diagnostics. The SUB host now runs L+S servers, so the
# fetches go out concurrently - done serially they took longer than the sample interval
# itself and starved the rest of the loop.
collect_nats_samples() {
    local i job jobs=()
    if [[ "$ROLE" == pub ]]; then
        collect_nats_sample core "http://127.0.0.1:$CORE_MONITOR_PORT" "$SAMPLE_TMP/core"
    else
        [[ "$MODE" == leaf ]] || return 0
        for ((i=0; i<LEAF_COUNT; i++)); do
            collect_nats_sample "leaf-$i" "http://127.0.0.1:$((LEAF_MONITOR_BASE + i))" "$SAMPLE_TMP/leaf-$i" &
            jobs+=("$!")
        done
        for ((i=0; i<SUB_SERVER_COUNT; i++)); do
            collect_nats_sample "subserver-$i" "http://127.0.0.1:$((SUB_SERVER_MONITOR_BASE + i))" "$SAMPLE_TMP/subserver-$i" &
            jobs+=("$!")
        done
        for job in "${jobs[@]}"; do wait "$job" || true; done
    fi
    cat "$SAMPLE_TMP"/* >> "$NATS_SAMPLES" 2>/dev/null || true
}

save_io_metrics() {
    if [[ -s "$SYSTEM_SAMPLES" ]]; then
        jq -s 'map(.io_wait_percent) as $v | {sample_count:($v|length),io_wait_percent:{min:($v|min),p50:($v|sort|.[((length-1)*0.50|floor)]),p95:($v|sort|.[((length-1)*0.95|floor)]),max:($v|max),average:($v|add/length)}}' \
            "$SYSTEM_SAMPLES" > "$RUN/io.json"
    else
        jq -n '{sample_count:0}' > "$RUN/io.json"
    fi
    if [[ -s "$NETDEV_SAMPLES" ]]; then
        jq -s 'map(.interfaces[]) | group_by(.interface) | map({interface:.[0].interface,
            rx_bytes_total_delta:(map(.rx_bytes_delta)|add),tx_bytes_total_delta:(map(.tx_bytes_delta)|add),
            rx_packets_total_delta:(map(.rx_packets_delta)|add),tx_packets_total_delta:(map(.tx_packets_delta)|add),
            rx_drops_total_delta:(map(.rx_drops_delta)|add),tx_drops_total_delta:(map(.tx_drops_delta)|add),
            rx_errors_total_delta:(map(.rx_errors_delta)|add),tx_errors_total_delta:(map(.tx_errors_delta)|add),
            rx_bytes_per_sec_max:(map(.rx_bytes_per_sec)|max),tx_bytes_per_sec_max:(map(.tx_bytes_per_sec)|max),
            rx_packets_per_sec_max:(map(.rx_packets_per_sec)|max),tx_packets_per_sec_max:(map(.tx_packets_per_sec)|max),
            rx_drops_delta_max:(map(.rx_drops_delta)|max),tx_drops_delta_max:(map(.tx_drops_delta)|max),
            rx_errors_delta_max:(map(.rx_errors_delta)|max),tx_errors_delta_max:(map(.tx_errors_delta)|max)})' \
            "$NETDEV_SAMPLES" > "$RUN/network.json"
    else
        printf '[]\n' > "$RUN/network.json"
    fi
}

save_nats_queue_metrics() {
    if [[ ! -s "$NATS_SAMPLES" ]]; then
        jq -n '{sample_count:0,servers:[]}' > "$NATS_QUEUE_METRICS"
        return
    fi
    jq -s '
      map(. as $sample | ($sample.connz.connections // [])[] |
        {server:$sample.server,cid:(.cid // 0),pending_bytes:(.pending_bytes // 0),
         pending_messages:(.pending_messages // 0),in_msgs:(.in_msgs // 0),out_msgs:(.out_msgs // 0),
         in_bytes:(.in_bytes // 0),out_bytes:(.out_bytes // 0)}) |
      group_by(.server) | map({server:.[0].server,sample_count:length,
        connection_count_max:(map(.cid)|unique|length),
        pending_bytes_max:(map(.pending_bytes)|max),pending_messages_max:(map(.pending_messages)|max),
        in_msgs_max:(map(.in_msgs)|max),out_msgs_max:(map(.out_msgs)|max),
        in_bytes_max:(map(.in_bytes)|max),out_bytes_max:(map(.out_bytes)|max)}) |
      {sample_count:([.[].sample_count]|add // 0),servers:.}' \
      "$NATS_SAMPLES" > "$NATS_QUEUE_METRICS"
}

save_tcp_queue_metrics() {
    if [[ ! -s "$TCP_QUEUE_SAMPLES" ]]; then
        jq -n '{sample_count:0,socket_count_max:0,recv_q_max:0,send_q_max:0}' > "$TCP_QUEUE_METRICS"
        return
    fi
    jq -s 'map(.sockets[]) as $s |
      {sample_count:length,socket_count_max:($s|length),recv_q_max:($s|map(.recv_q)|max // 0),
       send_q_max:($s|map(.send_q)|max // 0),states:($s|group_by(.state)|map({state:.[0].state,count:length}))}' \
      "$TCP_QUEUE_SAMPLES" > "$TCP_QUEUE_METRICS"
}

register_process() {
    local pid="$1" label="$2" category="$3"
    PIDS+=("$pid")
    PID_LABEL["$pid"]="$label"
    PID_CATEGORY["$pid"]="$category"
}

# Benchmark clients exit on their own; NATS servers do not. Only the former may be
# waited on, so they are tracked separately from the full kill list.
register_app_process() {
    register_process "$@"
    APP_PIDS+=("$1")
}

monitor_cpu() {
    local prev_total prev_idle prev_iowait now_total now_idle now_iowait usage io_wait consecutive=0 pid
    local net_json previous_net_json tcp_json sample_ts proc_rows row_kind row_pid row_rest delta_total
    local -A prev_process_ticks=()
    read -r prev_total prev_idle prev_iowait <<<"$(cpu_total)"
    : > "$SYSTEM_SAMPLES"; : > "$TCP_QUEUE_SAMPLES"; : > "$NETDEV_SAMPLES"; : > "$NATS_SAMPLES"
    previous_net_json="$(netdev_json)"
    # No priming pass here: the awk below emits a tick line for every PID, so the first
    # interval seeds the table and only later intervals produce samples.
    while ((${#PIDS[@]} > 0)); do
        sleep "$CPU_INTERVAL"
        read -r now_total now_idle now_iowait <<<"$(cpu_total)"
        usage="$(awk -v t="$now_total" -v p="$prev_total" -v i="$now_idle" -v pi="$prev_idle" \
            'BEGIN {d=t-p; if (d <= 0) print 0; else printf "%.3f", 100*((d-(i-pi))/d)}')"
        io_wait="$(awk -v t="$now_total" -v p="$prev_total" -v i="$now_iowait" -v pi="$prev_iowait" \
            'BEGIN {d=t-p; if (d <= 0) print 0; else printf "%.3f", 100*(i-pi)/d}')"
        jq -n --arg timestamp "$(date -Iseconds)" --argjson usage "$usage" \
            --argjson io_wait "$io_wait" '{timestamp:$timestamp,cpu_percent:$usage,io_wait_percent:$io_wait}' >> "$CPU_SAMPLES"
        jq -n --arg timestamp "$(date -Iseconds)" --argjson io_wait "$io_wait" \
            '{timestamp:$timestamp,io_wait_percent:$io_wait}' >> "$SYSTEM_SAMPLES"
        tcp_json="$(tcp_queue_snapshot)"
        jq -n --arg timestamp "$(date -Iseconds)" --argjson sockets "$tcp_json" \
            '{timestamp:$timestamp,sockets:$sockets}' >> "$TCP_QUEUE_SAMPLES"
        net_json="$(netdev_json)"
        net_sample="$(jq -n --argjson current "$net_json" --argjson previous "$previous_net_json" --arg interval "$CPU_INTERVAL" '
          ($previous | map({key:.interface,value:.}) | from_entries) as $p |
          {interfaces:[$current[] | . as $c | ($p[$c.interface] // $c) as $old |
            ($c | . + {rx_bytes_delta:([(.rx_bytes - $old.rx_bytes),0]|max),tx_bytes_delta:([(.tx_bytes - $old.tx_bytes),0]|max),
              rx_packets_delta:([(.rx_packets - $old.rx_packets),0]|max),tx_packets_delta:([(.tx_packets - $old.tx_packets),0]|max),
              rx_drops_delta:([(.rx_drops - $old.rx_drops),0]|max),tx_drops_delta:([(.tx_drops - $old.tx_drops),0]|max),
              rx_errors_delta:([(.rx_errors - $old.rx_errors),0]|max),tx_errors_delta:([(.tx_errors - $old.tx_errors),0]|max)}) |
              . + {rx_bytes_per_sec:(.rx_bytes_delta / ($interval|tonumber)),tx_bytes_per_sec:(.tx_bytes_delta / ($interval|tonumber)),
                   rx_packets_per_sec:(.rx_packets_delta / ($interval|tonumber)),tx_packets_per_sec:(.tx_packets_delta / ($interval|tonumber))}]}' )"
        jq -n --arg timestamp "$(date -Iseconds)" --argjson interfaces "$(jq '.interfaces' <<<"$net_sample")" \
            '{timestamp:$timestamp,interfaces:$interfaces}' >> "$NETDEV_SAMPLES"
        previous_net_json="$net_json"
        # One awk pass over /proc for every tracked PID. Reading each PID with its own
        # awk/jq/date/nproc forked several hundred processes per interval once the SUB
        # host runs 100 subscribers plus the Leaf and sub-side servers, which made the
        # loop slower than its own sample interval and starved these samples entirely.
        sample_ts="$(date -Iseconds)"
        delta_total="$(awk -v t="$now_total" -v p="$prev_total" 'BEGIN {printf "%.6f", t-p}')"
        proc_rows="$( {
                for pid in "${!prev_process_ticks[@]}"; do
                    printf 'P\t%s\t%s\n' "$pid" "${prev_process_ticks[$pid]}"
                done
                for pid in "${PIDS[@]}"; do
                    printf 'R\t%s\t%s\t%s\n' "$pid" "${PID_LABEL[$pid]}" "${PID_CATEGORY[$pid]}"
                done
            } | awk -F'\t' -v dtotal="$delta_total" -v ncpu="$NPROC" '
                $1 == "P" { prev[$2] = $3; next }
                $1 == "R" {
                    pid = $2
                    statfile = "/proc/" pid "/stat"
                    if ((getline stat_line < statfile) <= 0) { close(statfile); next }
                    close(statfile)
                    sub(/^.*\) /, "", stat_line)
                    if (split(stat_line, field, " ") < 15) next
                    ticks = field[12] + field[13]
                    printf "T\t%s\t%s\n", pid, ticks
                    if (!(pid in prev)) next
                    delta = ticks - prev[pid]
                    if (delta < 0) next
                    host_percent = (dtotal <= 0) ? 0 : 100 * delta / dtotal
                    core_percent = (dtotal <= 0) ? 0 : 100 * delta * ncpu / dtotal
                    printf "S\t%s\t%s\t%s\t%.3f\t%.3f\n", pid, $3, $4, host_percent, core_percent
                }' )"
        while IFS=$'\t' read -r row_kind row_pid row_rest; do
            [[ "$row_kind" == T ]] && prev_process_ticks["$row_pid"]="$row_rest"
        done <<< "$proc_rows"
        printf '%s\n' "$proc_rows" | sed -n 's/^S\t//p' | jq -Rn --arg timestamp "$sample_ts" \
            'inputs | split("\t") | {timestamp:$timestamp,pid:(.[0]|tonumber),label:.[1],category:.[2],
             cpu_percent_host:(.[3]|tonumber),cpu_percent_single_core:(.[4]|tonumber)}' \
            >> "$PROCESS_CPU_SAMPLES"
        collect_nats_samples
        prev_total="$now_total"; prev_idle="$now_idle"; prev_iowait="$now_iowait"
        if awk -v u="$usage" -v l="$CPU_LIMIT" 'BEGIN {exit !(u >= l)}'; then
            consecutive=$((consecutive + 1))
        else
            consecutive=0
        fi
        if ((consecutive >= CPU_CONSECUTIVE)); then
            jq -n --arg host "$(hostname)" --arg ts "$(date -Iseconds)" \
                --argjson usage "$usage" --argjson limit "$CPU_LIMIT" \
                '{aborted_by_cpu_limit:true,host:$host,timestamp:$ts,cpu_percent:$usage,cpu_limit_percent:$limit}' \
                > "$RUN/cpu-abort.json"
            for pid in "${PIDS[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
            return
        fi
    done
}

save_process_cpu_metrics() {
    if [[ ! -s "$PROCESS_CPU_SAMPLES" ]]; then
        jq -n '{sample_count:0,processes:[]}' > "$RUN/process-cpu.json"
        return
    fi
    jq -s '
        group_by(.pid) |
        map({pid:.[0].pid,label:.[0].label,category:.[0].category,sample_count:length,
             cpu_percent_host:{min:(map(.cpu_percent_host)|min),p50:(map(.cpu_percent_host)|sort|.[((length-1)*0.50|floor)]),p95:(map(.cpu_percent_host)|sort|.[((length-1)*0.95|floor)]),max:(map(.cpu_percent_host)|max),average:(map(.cpu_percent_host)|add/length)},
             cpu_percent_single_core:{min:(map(.cpu_percent_single_core)|min),p50:(map(.cpu_percent_single_core)|sort|.[((length-1)*0.50|floor)]),p95:(map(.cpu_percent_single_core)|sort|.[((length-1)*0.95|floor)]),max:(map(.cpu_percent_single_core)|max),average:(map(.cpu_percent_single_core)|add/length)}}) |
        {sample_count:(map(.sample_count)|add),processes:.}' \
        "$PROCESS_CPU_SAMPLES" > "$RUN/process-cpu.json"
}

# There is deliberately no cpu.json: summarize-leaf-run.sh reads cpu-samples.jsonl directly
# because it needs p90/p99, and everything the old summary held is either in summary.json or
# recomputable from the samples. The sampling interval it used to carry now lives in
# meta.json, where the rest of the run parameters are.

# The Core accepts the Leaf connections coming in from the SUB host.
write_core_config() {
    local path="$RUN/core.conf"
    cat > "$path" <<EOF
server_name: core
port: $CORE_CLIENT_PORT
http: 0.0.0.0:$CORE_MONITOR_PORT
leafnodes {
  port: $CORE_LEAF_PORT
}
EOF
    echo "$path"
}

# A Leaf runs on the SUB host, dials the Core across the wire, and accepts the
# sub-side servers below it.
write_leaf_config() {
    local index="$1"
    local path client monitor leafport
    path="$RUN/leaf-${index}.conf"
    client=$((LEAF_CLIENT_BASE + index))
    monitor=$((LEAF_MONITOR_BASE + index))
    leafport=$((LEAF_LEAF_BASE + index))
    cat > "$path" <<EOF
server_name: leaf-$index
port: $client
http: 0.0.0.0:$monitor
leafnodes {
  port: $leafport
  remotes = [ { urls: [ "nats://$PUB_HOST:$CORE_LEAF_PORT" ] } ]
}
EOF
    echo "$path"
}

# A sub-side server is the bottom tier: it dials one Leaf over loopback and serves the
# subscribers. It accepts no leaf connections of its own.
write_sub_server_config() {
    local index="$1"
    local path client monitor upstream
    path="$RUN/subserver-${index}.conf"
    client=$((SUB_SERVER_CLIENT_BASE + index))
    monitor=$((SUB_SERVER_MONITOR_BASE + index))
    upstream=$((LEAF_LEAF_BASE + index % LEAF_COUNT))
    cat > "$path" <<EOF
server_name: subserver-$index
port: $client
http: 0.0.0.0:$monitor
leafnodes {
  remotes = [ { urls: [ "nats://127.0.0.1:$upstream" ] } ]
}
EOF
    echo "$path"
}

wait_http() {
    local url="$1" timeout="${2:-60}"
    for _ in $(seq 1 $((timeout * 10))); do
        curl -fsS -m 1 "$url/varz" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 1
}

port_is_in_use() {
    (echo >/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1
}

# Only the ports this host actually binds are checked; the other host owns the rest.
check_local_ports() {
    local port name entry i
    local -a ports=()
    if [[ "$ROLE" == pub ]]; then
        ports+=("$CORE_CLIENT_PORT:Core client" "$CORE_MONITOR_PORT:Core monitor" "$CORE_LEAF_PORT:Core leaf")
    elif [[ "$MODE" == leaf ]]; then
        for ((i=0; i<LEAF_COUNT; i++)); do
            ports+=("$((LEAF_CLIENT_BASE + i)):Leaf $i client")
            ports+=("$((LEAF_MONITOR_BASE + i)):Leaf $i monitor")
            ports+=("$((LEAF_LEAF_BASE + i)):Leaf $i leaf")
        done
        for ((i=0; i<SUB_SERVER_COUNT; i++)); do
            ports+=("$((SUB_SERVER_CLIENT_BASE + i)):Sub server $i client")
            ports+=("$((SUB_SERVER_MONITOR_BASE + i)):Sub server $i monitor")
        done
    fi
    for entry in "${ports[@]:-}"; do
        [[ -n "$entry" ]] || continue
        port="${entry%%:*}"
        name="${entry#*:}"
        if port_is_in_use "$port"; then
            echo "ERROR: $name port $port is already in use." >&2
            echo "       Stop the previous benchmark/NATS process or rerun both hosts with --port-offset N." >&2
            return 1
        fi
    done
}

wait_process_http() {
    local pid="$1" url="$2" log="$3" timeout="${4:-60}"
    for _ in $(seq 1 $((timeout * 10))); do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "NATS process exited before its monitoring endpoint became ready: $url" >&2
            sed -n '1,120p' "$log" >&2
            return 1
        fi
        if curl -fsS -m 1 "$url/varz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    echo "Timed out waiting for NATS monitoring endpoint: $url" >&2
    sed -n '1,120p' "$log" >&2
    return 1
}

# A server that dials upstream is only usable once that leaf connection is established;
# starting the tier below it any earlier just races the interest propagation.
wait_leaf_connected() {
    local url="$1" log="$2" timeout="${3:-60}" count
    for _ in $(seq 1 $((timeout * 10))); do
        count="$(curl -fsS -m 1 "$url/leafz" 2>/dev/null | jq '.leafnodes // 0' 2>/dev/null || echo 0)"
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        ((count >= 1)) && return 0
        sleep 0.1
    done
    echo "Timed out waiting for a leaf connection at $url" >&2
    sed -n '1,120p' "$log" >&2
    return 1
}

core_leaf_connection_count() {
    local count
    count="$(curl -fsS -m 2 "http://127.0.0.1:$CORE_MONITOR_PORT/leafz" 2>/dev/null | jq '.leafnodes // 0' 2>/dev/null || echo 0)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    echo "$count"
}

# Count the subscriptions on SUBJECT across the tier the subscribers attach to.
count_tier_subscriptions() {
    local host="$1" url total=0 add
    while read -r url; do
        [[ -n "$url" ]] || continue
        add="$(curl -fsS -m 2 "$url/connz?subs=1" 2>/dev/null | jq --arg s "$SUBJECT" '[.connections[]?.subscriptions_list[]? | select(. == $s)] | length' 2>/dev/null || echo 0)"
        [[ "$add" =~ ^[0-9]+$ ]] || add=0
        total=$((total + add))
    done < <(subscriber_tier_monitor_urls "$host")
    echo "$total"
}

topology_description() {
    if [[ "$MODE" == direct ]]; then
        echo "publisher -> core(pub host) -> $SUBSCRIBER_COUNT subscribers(sub host)"
    elif ((SUB_SERVER_COUNT > 0)); then
        echo "publisher -> core(pub host) -> $LEAF_COUNT leaf(sub host) -> $SUB_SERVER_COUNT subserver(sub host) -> $SUBSCRIBER_COUNT subscribers(sub host)"
    else
        echo "publisher -> core(pub host) -> $LEAF_COUNT leaf(sub host) -> $SUBSCRIBER_COUNT subscribers(sub host)"
    fi
}

# network.json reports peak bytes/s but nothing says how much the link can carry, which is
# exactly the question a fan-out run has to answer. Record the link speed so the summary
# can turn those peaks into a utilization percentage. Virtual and down interfaces report
# either an error or -1; both come through as -1.
nic_speeds_json() {
    local path iface speed
    {
        for path in /sys/class/net/*; do
            [[ -e "$path/speed" ]] || continue
            iface="$(basename "$path")"
            speed="$(cat "$path/speed" 2>/dev/null || true)"
            [[ "$speed" =~ ^-?[0-9]+$ ]] || speed=-1
            printf '%s\t%s\n' "$iface" "$speed"
        done
    } | jq -Rn '[inputs | split("\t") | {interface:.[0], speed_mbps:(.[1]|tonumber)}]'
}

save_meta_native() {
    local assignment
    if [[ "$MODE" == direct ]]; then
        assignment="core"
    elif ((SUB_SERVER_COUNT > 0)); then
        assignment="subserver_index = subscriber_index modulo sub_server_count; leaf_index = subserver_index modulo leaf_count"
    else
        assignment="leaf_index = subscriber_index modulo leaf_count"
    fi
    jq -n --arg ts "$(date -Iseconds)" --arg role "$ROLE" --arg mode "$MODE" \
        --arg host "$(hostname)" --arg pub "$PUB_HOST" --arg sub "$SUB_HOST" --arg subject "$SUBJECT" \
        --arg clock "$CLOCK" --arg pacing "$PACING" --arg run_label "$LABEL" \
        --arg assignment "$assignment" --arg topology "$(topology_description)" \
        --argjson leaf "$LEAF_COUNT" --argjson subServers "$SUB_SERVER_COUNT" \
        --argjson subs "$SUBSCRIBER_COUNT" --argjson rate "$RATE" \
        --argjson duration "$DURATION" --argjson size "$SIZE" --argjson cpuLimit "$CPU_LIMIT" \
        --argjson cpuInterval "$CPU_INTERVAL" --argjson cpuConsecutive "$CPU_CONSECUTIVE" \
        --argjson portOffset "$PORT_OFFSET" --argjson nic "$(nic_speeds_json)" \
        '{"timestamp":$ts,"role":$role,"mode":$mode,"host":$host,"pub_host":$pub,"sub_host":$sub,"subject":$subject,"clock":$clock,"pacing":$pacing,"label":$run_label,"leaf_count":$leaf,"leaf_placement":(if $mode == "direct" then "none" else "sub_host" end),"sub_server_count":$subServers,"subscriber_count":$subs,"target_msgs_per_sec":$rate,"duration_sec":$duration,"size":$size,"cpu_limit_percent":$cpuLimit,"cpu_interval_sec":$cpuInterval,"cpu_consecutive":$cpuConsecutive,"port_offset":$portOffset,"topology":$topology,"subscriber_assignment":$assignment,"nic_speed_mbps":$nic,"image":"none"}' \
        > "$RUN/meta.json"
}

if [[ "$ROLE" == pub ]]; then
    [[ -x "$NATS_SERVER_BIN" ]] || { echo "ERROR: nats-server was not found at $NATS_SERVER_BIN" >&2; exit 1; }
    check_local_ports || exit 1
    core_config="$(write_core_config)"
    "$NATS_SERVER_BIN" -c "$core_config" >"$RUN/core.log" 2>&1 & register_process "$!" core-nats nats
    wait_http "http://127.0.0.1:$CORE_MONITOR_PORT" || { cat "$RUN/core.log" >&2; exit 1; }
    save_meta_native
    echo "Core is up. Topology: $(topology_description)"
    monitor_cpu & monitor_pid=$!
    ready=0
    count=0
    for _ in $(seq 1 1200); do
        if [[ "$MODE" == direct ]]; then
            count="$(curl -fsS "http://127.0.0.1:$CORE_MONITOR_PORT/connz?subs=1" 2>/dev/null | jq --arg s "$SUBJECT" '[.connections[]?.subscriptions_list[]? | select(. == $s)] | length' 2>/dev/null || echo 0)"
        else
            # The Leaf tier lives on the SUB host, so readiness is confirmed there and
            # cross-checked against the leaf connections the Core has accepted.
            leaf_conns="$(core_leaf_connection_count)"
            if ((leaf_conns < LEAF_COUNT)); then
                count=0
            else
                count="$(count_tier_subscriptions "$SUB_HOST")"
            fi
        fi
        if ((count >= SUBSCRIBER_COUNT)); then ready=1; break; fi
        sleep 0.1
    done
    kill "$monitor_pid" 2>/dev/null || true
    save_io_metrics
    save_tcp_queue_metrics
    save_nats_queue_metrics
    if [[ "$ready" != 1 ]]; then
        echo "ERROR: only $count/$SUBSCRIBER_COUNT subscriptions became ready" >&2
        if [[ "$MODE" == leaf ]]; then
            echo "       Core leaf connections: $(core_leaf_connection_count)/$LEAF_COUNT" >&2
            echo "       Check that the SUB host can reach $PUB_HOST:$CORE_LEAF_PORT and that this" >&2
            echo "       host can reach the SUB host monitoring ports." >&2
        fi
        exit 1
    fi
    echo "All $SUBSCRIBER_COUNT subscriptions are ready; starting publisher."
    : > "$CPU_SAMPLES"
    : > "$PROCESS_CPU_SAMPLES"
    : > "$SYSTEM_SAMPLES"
    : > "$TCP_QUEUE_SAMPLES"
    : > "$NETDEV_SAMPLES"
    : > "$NATS_SAMPLES"
    "$TOOL" --mode pub --subject "$SUBJECT" --rate "$RATE" --duration-sec "$DURATION" --size "$SIZE" \
        --server "nats://127.0.0.1:$CORE_CLIENT_PORT" --clock "$CLOCK" --pacing "$PACING" --out "$RUN" & publisher_pid=$!
    register_app_process "$publisher_pid" publisher application
    monitor_cpu & monitor_pid=$!
    wait "$publisher_pid" || true
    kill "$monitor_pid" 2>/dev/null || true
    save_process_cpu_metrics
    save_io_metrics
    save_tcp_queue_metrics
    save_nats_queue_metrics
    aborted=false; [[ -f "$RUN/cpu-abort.json" ]] && aborted=true
    jq --argjson aborted "$aborted" '. + {aborted_by_cpu_limit:$aborted}' "$RUN/result.json" 2>/dev/null > "$RUN/result.tmp" && mv "$RUN/result.tmp" "$RUN/result.json" || true
else
    if [[ "$MODE" == leaf ]]; then
        [[ -x "$NATS_SERVER_BIN" ]] || { echo "ERROR: nats-server was not found at $NATS_SERVER_BIN" >&2; exit 1; }
    fi
    check_local_ports || exit 1
    save_meta_native
    echo "Waiting for the Core NATS server at $PUB_HOST ..."
    wait_http "http://$PUB_HOST:$CORE_MONITOR_PORT" 120 || {
        echo "ERROR: Core NATS monitoring endpoint did not become reachable" >&2
        exit 1
    }
    if [[ "$MODE" == leaf ]]; then
        echo "Starting $LEAF_COUNT Leaf server(s) on this host, dialing $PUB_HOST:$CORE_LEAF_PORT ..."
        for ((i=0; i<LEAF_COUNT; i++)); do
            config="$(write_leaf_config "$i")"
            "$NATS_SERVER_BIN" -c "$config" >"$RUN/leaf-$i.log" 2>&1 & leaf_pid=$!
            register_process "$leaf_pid" "leaf-$i-nats" nats
            wait_process_http "$leaf_pid" "http://127.0.0.1:$((LEAF_MONITOR_BASE + i))" "$RUN/leaf-$i.log" || {
                echo "ERROR: Leaf $i did not start (config: $config)" >&2
                exit 1
            }
            wait_leaf_connected "http://127.0.0.1:$((LEAF_MONITOR_BASE + i))" "$RUN/leaf-$i.log" || {
                echo "ERROR: Leaf $i never connected to the Core at $PUB_HOST:$CORE_LEAF_PORT" >&2
                exit 1
            }
        done
        if ((SUB_SERVER_COUNT > 0)); then
            echo "Starting $SUB_SERVER_COUNT sub-side server(s) below the Leaf tier ..."
            for ((j=0; j<SUB_SERVER_COUNT; j++)); do
                config="$(write_sub_server_config "$j")"
                "$NATS_SERVER_BIN" -c "$config" >"$RUN/subserver-$j.log" 2>&1 & sub_server_pid=$!
                register_process "$sub_server_pid" "subserver-$j-nats" nats
                wait_process_http "$sub_server_pid" "http://127.0.0.1:$((SUB_SERVER_MONITOR_BASE + j))" "$RUN/subserver-$j.log" || {
                    echo "ERROR: Sub server $j did not start (config: $config)" >&2
                    exit 1
                }
                wait_leaf_connected "http://127.0.0.1:$((SUB_SERVER_MONITOR_BASE + j))" "$RUN/subserver-$j.log" || {
                    echo "ERROR: Sub server $j never connected to leaf-$((j % LEAF_COUNT))" >&2
                    exit 1
                }
            done
        fi
    fi
    # Resolve every subscriber's target first and record the whole assignment map in one
    # subscribers.json, rather than one small meta.json per subscriber directory. It is
    # written before anything launches, so the map survives a failed start.
    declare -a SUBSCRIBER_URL=()
    subscriber_rows=()
    for ((i=0; i<SUBSCRIBER_COUNT; i++)); do
        if [[ "$MODE" == direct ]]; then
            SUBSCRIBER_URL[i]="nats://$PUB_HOST:$CORE_CLIENT_PORT"
        else
            SUBSCRIBER_URL[i]="nats://127.0.0.1:$(subscriber_server_port "$i")"
        fi
        subscriber_rows+=("$i"$'\t'"${SUBSCRIBER_URL[i]}"$'\t'"$(subscriber_assignment "$i")")
    done
    printf '%s\n' "${subscriber_rows[@]}" | jq -Rn \
        '[inputs | split("\t") | {subscriber_id:(.[0]|tonumber), server:.[1], assignment:.[2]}]' \
        > "$RUN/subscribers.json"

    echo "Starting $SUBSCRIBER_COUNT subscriber(s). Topology: $(topology_description)"
    for ((i=0; i<SUBSCRIBER_COUNT; i++)); do
        out="$RUN/subscriber-$i"
        mkdir -p "$out"
        "$TOOL" --mode sub --subject "$SUBJECT" --rate "$RATE" --duration-sec "$DURATION" --size "$SIZE" \
            --server "${SUBSCRIBER_URL[i]}" --clock "$CLOCK" --pacing "$PACING" --out "$out" >"$out/stdout.log" 2>&1 & register_app_process "$!" "subscriber-$i" application
    done
    monitor_cpu & monitor_pid=$!
    status=0
    # Only the subscribers terminate on their own; the NATS servers are torn down by the
    # EXIT trap, so waiting on them here would hang the run.
    for pid in "${APP_PIDS[@]}"; do wait "$pid" || status=1; done
    kill "$monitor_pid" 2>/dev/null || true
    save_process_cpu_metrics
    save_io_metrics
    save_tcp_queue_metrics
    save_nats_queue_metrics
    total_received=0; total_loss=0
    for ((i=0; i<SUBSCRIBER_COUNT; i++)); do
        file="$RUN/subscriber-$i/result.json"
        if [[ -f "$file" ]]; then
            total_received=$((total_received + $(jq '.metrics.msgs_received // 0' "$file")))
            total_loss=$((total_loss + $(jq '.metrics.msg_loss // 0' "$file")))
        else status=1; fi
    done
    aborted=false; [[ -f "$RUN/cpu-abort.json" ]] && aborted=true
    p50="$(jq -s '[.[] | .metrics.latency_us.p50 // 0] | max' "$RUN"/subscriber-*/result.json 2>/dev/null || echo 0)"
    p99="$(jq -s '[.[] | .metrics.latency_us.p99 // 0] | max' "$RUN"/subscriber-*/result.json 2>/dev/null || echo 0)"
    p999="$(jq -s '[.[] | .metrics.latency_us.p999 // 0] | max' "$RUN"/subscriber-*/result.json 2>/dev/null || echo 0)"
    expected_one="$(awk -v r="$RATE" -v d="$DURATION" 'BEGIN {printf "%.0f", r*d}')"
    expected_total=$((SUBSCRIBER_COUNT * expected_one))
    jq -n --arg mode "$MODE" --arg topology "$(topology_description)" \
        --argjson leaf "$LEAF_COUNT" --argjson subServers "$SUB_SERVER_COUNT" \
        --argjson subscribers "$SUBSCRIBER_COUNT" --argjson received "$total_received" \
        --argjson loss "$total_loss" --argjson aborted "$aborted" --argjson expected "$expected_total" \
        --argjson p50 "$p50" --argjson p99 "$p99" --argjson p999 "$p999" \
        '{mode:$mode,measure:"fanout",topology:$topology,leaf_count:$leaf,sub_server_count:$subServers,subscribers:$subscribers,metrics:{msgs_received:$received,msg_loss:$loss,expected_deliveries:$expected,latency_us:{p50_max:$p50,p99_max:$p99,p999_max:$p999}},aborted_by_cpu_limit:$aborted}' > "$RUN/result.json"
    add_run_index_entry "$RUN" crosshost "$LABEL-$MODE" "$(jq --argjson duration "$DURATION" '{msg_loss:.metrics.msg_loss,sub_msgs_per_sec:(.metrics.msgs_received / $duration),p50_latency_us:.metrics.latency_us.p50_max,p99_latency_us:.metrics.latency_us.p99_max}' "$RUN/result.json")" || true
    exit "$status"
fi

echo "Done. Results in: $RUN"
