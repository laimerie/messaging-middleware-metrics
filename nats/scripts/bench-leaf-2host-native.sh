#!/usr/bin/env bash
# Run a Direct or Leaf fan-out experiment on two native Linux hosts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

ROLE=""
MODE="direct"
PUB_HOST=""
LEAF_COUNT=5
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
    sed -n 's/^# //p' "$0" | head -n 3
    echo "Usage: $0 --role pub|sub --pub-host HOST [options]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role) ROLE="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --pub-host) PUB_HOST="$2"; shift 2 ;;
        --leaf-count) LEAF_COUNT="$2"; shift 2 ;;
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
if [[ "$MODE" == leaf && "$LEAF_COUNT" == 0 ]]; then
    MODE="direct"
fi
[[ "$PORT_OFFSET" =~ ^[0-9]+$ ]] || { echo "ERROR: --port-offset must be a non-negative integer" >&2; exit 1; }
[[ "$SUBSCRIBER_COUNT" -gt 0 && "$RATE" -gt 0 && "$DURATION" -gt 0 && "$SIZE" -ge 24 ]] || {
    echo "ERROR: subscriber-count, rate, duration must be positive and size must be at least 24" >&2; exit 1;
}
[[ -x "$TOOL" ]] || { echo "ERROR: latency_oneway was not found at $TOOL" >&2; exit 1; }
export LD_LIBRARY_PATH="$PKG_ROOT/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

CORE_CLIENT_PORT=$((4222 + PORT_OFFSET))
CORE_MONITOR_PORT=$((8222 + PORT_OFFSET))
CORE_LEAF_PORT=$((7422 + PORT_OFFSET))
LEAF_CLIENT_BASE=$((5000 + PORT_OFFSET))
LEAF_MONITOR_BASE=$((8200 + PORT_OFFSET))
LEAF_LEAF_BASE=$((7600 + PORT_OFFSET))
PIDS=()
declare -A PID_LABEL=()
declare -A PID_CATEGORY=()
RUN="$(new_run_dir crosshost "$LABEL-$MODE")"
CPU_SAMPLES="$RUN/cpu-samples.jsonl"
PROCESS_CPU_SAMPLES="$RUN/process-cpu-samples.jsonl"
SYSTEM_SAMPLES="$RUN/system-samples.jsonl"
TCP_QUEUE_SAMPLES="$RUN/tcp-queue-samples.jsonl"
TCP_QUEUE_METRICS="$RUN/tcp-queue.json"
NETDEV_SAMPLES="$RUN/netdev-samples.jsonl"
NATS_SAMPLES="$RUN/nats-samples.jsonl"
NATS_QUEUE_METRICS="$RUN/nats-queue.json"

cleanup() {
    local pid
    for pid in "${PIDS[@]:-}"; do kill -TERM "$pid" 2>/dev/null || true; done
    sleep 0.2
    for pid in "${PIDS[@]:-}"; do kill -KILL "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true
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

collect_nats_sample() {
    local name="$1" url="$2" varz connz
    varz="$(curl -fsS -m 1 "$url/varz" 2>/dev/null || printf '{}')"
    connz="$(curl -fsS -m 1 "$url/connz?subs=1" 2>/dev/null || printf '{}')"
    jq -n --arg timestamp "$(date -Iseconds)" --arg server "$name" \
        --argjson varz "$varz" --argjson connz "$connz" \
        '{timestamp:$timestamp,server:$server,varz:$varz,connz:$connz}' >> "$NATS_SAMPLES"
}

collect_nats_samples() {
    [[ "$ROLE" == pub ]] && collect_nats_sample core "http://127.0.0.1:$CORE_MONITOR_PORT"
    if [[ "$MODE" == leaf ]]; then
        for ((i=0; i<LEAF_COUNT; i++)); do
            if [[ "$ROLE" == pub ]]; then
                collect_nats_sample "leaf-$i" "http://127.0.0.1:$((LEAF_MONITOR_BASE + i))"
            else
                collect_nats_sample "leaf-$i" "http://$PUB_HOST:$((LEAF_MONITOR_BASE + i))"
            fi
        done
    fi
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

process_ticks() {
    local pid="$1"
    [[ -r "/proc/$pid/stat" ]] || return 1
    awk '{line=$0; sub(/^.*\) /, "", line); n=split(line, fields, " "); if (n >= 15) print fields[12]+fields[13]}' "/proc/$pid/stat"
}

register_process() {
    local pid="$1" label="$2" category="$3"
    PIDS+=("$pid")
    PID_LABEL["$pid"]="$label"
    PID_CATEGORY["$pid"]="$category"
}

monitor_cpu() {
    local prev_total prev_idle prev_iowait now_total now_idle now_iowait usage io_wait consecutive=0 pid ticks delta
    local net_json previous_net_json tcp_json
    local -A prev_process_ticks=()
    read -r prev_total prev_idle prev_iowait <<<"$(cpu_total)"
    : > "$SYSTEM_SAMPLES"; : > "$TCP_QUEUE_SAMPLES"; : > "$NETDEV_SAMPLES"; : > "$NATS_SAMPLES"
    previous_net_json="$(netdev_json)"
    for pid in "${PIDS[@]}"; do
        ticks="$(process_ticks "$pid" 2>/dev/null || true)"
        [[ "$ticks" =~ ^[0-9]+$ ]] && prev_process_ticks["$pid"]="$ticks"
    done
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
        collect_nats_samples
        for pid in "${PIDS[@]}"; do
            ticks="$(process_ticks "$pid" 2>/dev/null || true)"
            [[ "$ticks" =~ ^[0-9]+$ && -n "${prev_process_ticks[$pid]:-}" ]] || continue
            delta=$((ticks - prev_process_ticks[$pid]))
            ((delta >= 0)) || continue
            jq -n --arg timestamp "$(date -Iseconds)" --argjson pid "$pid" \
                --arg process_label "${PID_LABEL[$pid]}" --arg category "${PID_CATEGORY[$pid]}" \
                --argjson host_percent "$(awk -v d="$delta" -v t="$now_total" -v p="$prev_total" \
                    'BEGIN {dtotal=t-p; if (dtotal <= 0) print 0; else printf "%.3f", 100*d/dtotal}')" \
                --argjson core_percent "$(awk -v d="$delta" -v n="$(nproc)" -v t="$now_total" -v p="$prev_total" \
                    'BEGIN {dtotal=t-p; if (dtotal <= 0) print 0; else printf "%.3f", 100*d*n/dtotal}')" \
                '{"timestamp":$timestamp,"pid":$pid,"label":$process_label,"category":$category,"cpu_percent_host":$host_percent,"cpu_percent_single_core":$core_percent}' \
                >> "$PROCESS_CPU_SAMPLES"
            prev_process_ticks["$pid"]="$ticks"
        done
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

save_cpu_metrics() {
    if [[ ! -s "$CPU_SAMPLES" ]]; then
        jq -n --arg host "$(hostname)" --arg interval "$CPU_INTERVAL" \
            '{host:$host,sample_interval_sec:($interval|tonumber),sample_count:0}' > "$RUN/cpu.json"
        return
    fi
    jq -s --arg host "$(hostname)" --arg interval "$CPU_INTERVAL" \
        'map(.cpu_percent) as $values |
         ($values | sort) as $sorted |
         ($sorted | length) as $count |
         {host:$host,sample_interval_sec:($interval|tonumber),sample_count:$count,
          cpu_percent:{min:($sorted[0]),p50:($sorted[((($count-1)*0.50)|floor)]),
                       p95:($sorted[((($count-1)*0.95)|floor)]),max:($sorted[-1]),
                       average:($values|add/length)}}' \
        "$CPU_SAMPLES" > "$RUN/cpu.json"
}

write_core_config() {
    local path="$RUN/core.conf"
    cat > "$path" <<EOF
port: $CORE_CLIENT_PORT
http: 0.0.0.0:$CORE_MONITOR_PORT
leafnodes {
  port: $CORE_LEAF_PORT
}
EOF
    echo "$path"
}

write_leaf_config() {
    local index="$1"
    local path client monitor leafport
    path="$RUN/leaf-${index}.conf"
    client=$((LEAF_CLIENT_BASE + index))
    monitor=$((LEAF_MONITOR_BASE + index))
    leafport=$((LEAF_LEAF_BASE + index))
    cat > "$path" <<EOF
port: $client
http: 0.0.0.0:$monitor
leafnodes {
  port: $leafport
  remotes = [ { urls: [ "nats://127.0.0.1:$CORE_LEAF_PORT" ] } ]
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

check_local_ports() {
    local port name
    local -a ports=("$CORE_CLIENT_PORT:Core client" "$CORE_MONITOR_PORT:Core monitor" "$CORE_LEAF_PORT:Core leaf")
    if [[ "$MODE" == leaf ]]; then
        for ((i=0; i<LEAF_COUNT; i++)); do
            ports+=("$((LEAF_CLIENT_BASE + i)):Leaf $i client")
            ports+=("$((LEAF_MONITOR_BASE + i)):Leaf $i monitor")
            ports+=("$((LEAF_LEAF_BASE + i)):Leaf $i leaf")
        done
    fi
    for entry in "${ports[@]}"; do
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

save_meta_native() {
    jq -n --arg ts "$(date -Iseconds)" --arg role "$ROLE" --arg mode "$MODE" \
        --arg host "$(hostname)" --arg pub "$PUB_HOST" --arg subject "$SUBJECT" \
        --arg clock "$CLOCK" --arg pacing "$PACING" --arg run_label "$LABEL" \
        --argjson leaf "$LEAF_COUNT" --argjson subs "$SUBSCRIBER_COUNT" --argjson rate "$RATE" \
        --argjson duration "$DURATION" --argjson size "$SIZE" --argjson cpuLimit "$CPU_LIMIT" \
        --argjson portOffset "$PORT_OFFSET" \
        '{"timestamp":$ts,"role":$role,"mode":$mode,"host":$host,"pub_host":$pub,"subject":$subject,"clock":$clock,"pacing":$pacing,"label":$run_label,"leaf_count":$leaf,"subscriber_count":$subs,"target_msgs_per_sec":$rate,"duration_sec":$duration,"size":$size,"cpu_limit_percent":$cpuLimit,"port_offset":$portOffset,"subscriber_assignment":(if $mode == "direct" then "core" else "leaf_index = subscriber_index modulo leaf_count" end),"image":"none"}' \
        > "$RUN/meta.json"
}

if [[ "$ROLE" == pub ]]; then
    [[ -x "$NATS_SERVER_BIN" ]] || { echo "ERROR: nats-server was not found at $NATS_SERVER_BIN" >&2; exit 1; }
    check_local_ports || exit 1
    core_config="$(write_core_config)"
    "$NATS_SERVER_BIN" -c "$core_config" >"$RUN/core.log" 2>&1 & register_process "$!" core-nats nats
    wait_http "http://127.0.0.1:$CORE_MONITOR_PORT" || { cat "$RUN/core.log" >&2; exit 1; }
    if [[ "$MODE" == leaf ]]; then
        for ((i=0; i<LEAF_COUNT; i++)); do
            config="$(write_leaf_config "$i")"
            "$NATS_SERVER_BIN" -c "$config" >"$RUN/leaf-$i.log" 2>&1 & register_process "$!" "leaf-$i-nats" nats
            leaf_pid="${PIDS[-1]}"
            wait_process_http "$leaf_pid" "http://127.0.0.1:$((LEAF_MONITOR_BASE + i))" "$RUN/leaf-$i.log" || {
                echo "ERROR: Leaf $i did not start (config: $config)" >&2
                exit 1
            }
        done
    fi
    save_meta_native
    monitor_cpu & monitor_pid=$!
    ready=0
    for _ in $(seq 1 1200); do
        if [[ "$MODE" == direct ]]; then
            count="$(curl -fsS "http://127.0.0.1:$CORE_MONITOR_PORT/connz?subs=1" 2>/dev/null | jq --arg s "$SUBJECT" '[.connections[]?.subscriptions_list[]? | select(. == $s)] | length' 2>/dev/null || echo 0)"
        else
            count=0
            for ((i=0; i<LEAF_COUNT; i++)); do
                count=$((count + $(curl -fsS "http://127.0.0.1:$((LEAF_MONITOR_BASE + i))/connz?subs=1" 2>/dev/null | jq --arg s "$SUBJECT" '[.connections[]?.subscriptions_list[]? | select(. == $s)] | length' 2>/dev/null || echo 0)))
            done
        fi
        if ((count >= SUBSCRIBER_COUNT)); then ready=1; break; fi
        sleep 0.1
    done
    kill "$monitor_pid" 2>/dev/null || true
    save_cpu_metrics
    save_io_metrics
    save_tcp_queue_metrics
    save_nats_queue_metrics
    [[ "$ready" == 1 ]] || { echo "ERROR: only $count/$SUBSCRIBER_COUNT subscriptions became ready" >&2; exit 1; }
    echo "All $SUBSCRIBER_COUNT subscriptions are ready; starting publisher."
    : > "$CPU_SAMPLES"
    : > "$PROCESS_CPU_SAMPLES"
    : > "$SYSTEM_SAMPLES"
    : > "$TCP_QUEUE_SAMPLES"
    : > "$NETDEV_SAMPLES"
    : > "$NATS_SAMPLES"
    "$TOOL" --mode pub --subject "$SUBJECT" --rate "$RATE" --duration-sec "$DURATION" --size "$SIZE" \
        --server "nats://127.0.0.1:$CORE_CLIENT_PORT" --clock "$CLOCK" --pacing "$PACING" --out "$RUN" & register_process "$!" publisher application
    monitor_cpu & monitor_pid=$!
    wait "${PIDS[-1]}" || true
    kill "$monitor_pid" 2>/dev/null || true
    save_cpu_metrics
    save_process_cpu_metrics
    save_io_metrics
    save_tcp_queue_metrics
    save_nats_queue_metrics
    aborted=false; [[ -f "$RUN/cpu-abort.json" ]] && aborted=true
    jq --argjson aborted "$aborted" '. + {aborted_by_cpu_limit:$aborted}' "$RUN/result.json" 2>/dev/null > "$RUN/result.tmp" && mv "$RUN/result.tmp" "$RUN/result.json" || true
else
    echo "Waiting for NATS server at $PUB_HOST ..."
    wait_http "http://$PUB_HOST:$CORE_MONITOR_PORT" 120 || {
        echo "ERROR: Core NATS monitoring endpoint did not become reachable" >&2
        exit 1
    }
    if [[ "$MODE" == leaf ]]; then
        for ((i=0; i<LEAF_COUNT; i++)); do
            wait_http "http://$PUB_HOST:$((LEAF_MONITOR_BASE + i))" 120 || {
                echo "ERROR: Leaf $i monitoring endpoint did not become reachable" >&2
                exit 1
            }
        done
    fi
    save_meta_native
    for ((i=0; i<SUBSCRIBER_COUNT; i++)); do
        if [[ "$MODE" == direct ]]; then server="nats://$PUB_HOST:$CORE_CLIENT_PORT"; assignment="core"; else leaf=$((i % LEAF_COUNT)); server="nats://$PUB_HOST:$((LEAF_CLIENT_BASE + leaf))"; assignment="leaf-$leaf"; fi
        out="$RUN/subscriber-$i"
        mkdir -p "$out"
        jq -n --arg role subscriber --argjson id "$i" --arg server "$server" --arg assignment "$assignment" \
            '{role:$role,subscriber_id:$id,server:$server,assignment:$assignment}' > "$out/meta.json"
        "$TOOL" --mode sub --subject "$SUBJECT" --rate "$RATE" --duration-sec "$DURATION" --size "$SIZE" \
            --server "$server" --clock "$CLOCK" --pacing "$PACING" --out "$out" >"$out/stdout.log" 2>&1 & register_process "$!" "subscriber-$i" application
    done
    monitor_cpu & monitor_pid=$!
    status=0
    for pid in "${PIDS[@]}"; do wait "$pid" || status=1; done
    kill "$monitor_pid" 2>/dev/null || true
    save_cpu_metrics
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
    jq -n --arg mode "$MODE" --argjson subscribers "$SUBSCRIBER_COUNT" --argjson received "$total_received" \
        --argjson loss "$total_loss" --argjson aborted "$aborted" --argjson expected "$expected_total" \
        --argjson p50 "$p50" --argjson p99 "$p99" --argjson p999 "$p999" \
        '{mode:$mode,measure:"fanout",subscribers:$subscribers,metrics:{msgs_received:$received,msg_loss:$loss,expected_deliveries:$expected,latency_us:{p50_max:$p50,p99_max:$p99,p999_max:$p999}},aborted_by_cpu_limit:$aborted}' > "$RUN/result.json"
    add_run_index_entry "$RUN" crosshost "$LABEL-$MODE" "$(jq --argjson duration "$DURATION" '{msg_loss:.metrics.msg_loss,sub_msgs_per_sec:(.metrics.msgs_received / $duration),p50_latency_us:.metrics.latency_us.p50_max,p99_latency_us:.metrics.latency_us.p99_max}' "$RUN/result.json")" || true
    exit "$status"
fi

echo "Done. Results in: $RUN"