#!/usr/bin/env bash
# summarize-leaf-run.sh - collapse one two-host Leaf/Direct run into a single summary.
#
# bench-leaf-2host-native.sh writes one result directory per host, and with 100 subscribers
# a single run spreads its numbers over roughly 360 files. This reads both halves and emits
# one summary.json plus one row in results/crosshost/leaf-summary.csv, so runs can be
# compared without opening any of them.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

PUB_DIR=""
SUB_DIR=""
LABEL=""
OUT=""
CSV="$RESULTS_ROOT/crosshost/leaf-summary.csv"
APPEND_CSV=1
POOL_LATENCY=0

usage() {
    cat <<'USAGE'
Usage:
  summarize-leaf-run.sh --label LABEL [options]
  summarize-leaf-run.sh --pub-dir DIR --sub-dir DIR [options]

Both hosts write into the same results tree (a shared NAS/NFS mount), so the two halves of
a run are paired by their directory suffix: <timestamp>_<label>-<mode>-pub and -sub.

Options:
  --label LABEL      Pair the newest -pub and -sub directories carrying this label.
  --pub-dir DIR      PUB host result directory (skips discovery).
  --sub-dir DIR      SUB host result directory (skips discovery).
  --out FILE         Where to write summary.json (default: <sub-dir>/summary.json).
  --csv FILE         Comparison table to append to
                     (default: results/crosshost/leaf-summary.csv).
  --no-csv           Do not append a row.
  --pool-latency     Compute exact pooled percentiles from every subscriber's latency.csv
                     instead of taking percentiles across the per-subscriber percentiles.
                     Accurate but reads rate x duration x subscribers rows.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label) LABEL="$2"; shift 2 ;;
        --pub-dir) PUB_DIR="$2"; shift 2 ;;
        --sub-dir) SUB_DIR="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --csv) CSV="$2"; shift 2 ;;
        --no-csv) APPEND_CSV=0; shift ;;
        --pool-latency) POOL_LATENCY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

command -v jq >/dev/null || { echo "ERROR: jq is required." >&2; exit 1; }

# Newest directory whose meta.json carries the wanted role, restricted to the label when one
# was given. The role is read from meta.json rather than trusted from the directory name.
discover_dir() {
    local role="$1" pattern candidate
    if [[ -n "$LABEL" ]]; then pattern="*_${LABEL}-*-${role}"; else pattern="*-${role}"; fi
    while IFS= read -r candidate; do
        [[ -f "$candidate/meta.json" ]] || continue
        [[ "$(jq -r '.role // ""' "$candidate/meta.json")" == "$role" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done < <(find "$RESULTS_ROOT/crosshost" -maxdepth 1 -type d -name "$pattern" 2>/dev/null | sort -r)
    return 1
}

if [[ -z "$PUB_DIR" ]]; then
    PUB_DIR="$(discover_dir pub)" || { echo "ERROR: no PUB result directory found${LABEL:+ for label '$LABEL'}." >&2; exit 1; }
fi
if [[ -z "$SUB_DIR" ]]; then
    SUB_DIR="$(discover_dir sub)" || { echo "ERROR: no SUB result directory found${LABEL:+ for label '$LABEL'}." >&2; exit 1; }
fi
for d in "$PUB_DIR" "$SUB_DIR"; do
    [[ -f "$d/meta.json" ]] || { echo "ERROR: $d/meta.json is missing - not a benchmark result directory." >&2; exit 1; }
done
[[ "$(jq -r '.role' "$PUB_DIR/meta.json")" == pub ]] || { echo "ERROR: $PUB_DIR is not a pub-role run." >&2; exit 1; }
[[ "$(jq -r '.role' "$SUB_DIR/meta.json")" == sub ]] || { echo "ERROR: $SUB_DIR is not a sub-role run." >&2; exit 1; }
OUT="${OUT:-$SUB_DIR/summary.json}"

# Both halves must describe the same experiment; pairing the wrong two directories would
# produce a summary that looks fine and means nothing.
mismatch="$(jq -n --slurpfile p "$PUB_DIR/meta.json" --slurpfile s "$SUB_DIR/meta.json" '
    ["mode","leaf_count","sub_server_count","subscriber_count","target_msgs_per_sec","duration_sec","size","subject"]
    | map(. as $k | select(($p[0][$k] // null) != ($s[0][$k] // null)) | $k) | join(", ")')"
if [[ -n "${mismatch//\"/}" && "$mismatch" != '""' ]]; then
    echo "ERROR: the PUB and SUB directories describe different runs (differing: ${mismatch//\"/})." >&2
    echo "       pub: $PUB_DIR" >&2
    echo "       sub: $SUB_DIR" >&2
    exit 1
fi

PCT_DEF='def pct(p): if length == 0 then null else sort as $s | $s[((length-1)*p|floor)] end;'

# --- per-tier CPU -------------------------------------------------------------------------
# Two different questions, so two different aggregations. "One server in this tier" pools
# every process-interval sample, which is what makes a p99 meaningful when the tier only has
# a handful of servers. "The tier as a whole" sums the tier at each interval first, which is
# the number that actually changes when the tier is resized.
tier_cpu() {
    local file="$1" pattern="$2"
    if [[ ! -s "$file" ]]; then
        jq -n '{server_count:0,samples:0,per_server_single_core_percent:null,tier_total_host_percent:null}'
        return
    fi
    jq -s --arg pat "$pattern" "$PCT_DEF"'
      (map(select(.label | test($pat)))) as $rows |
      if ($rows | length) == 0 then
        {server_count:0,samples:0,per_server_single_core_percent:null,tier_total_host_percent:null}
      else
        ($rows | map(.cpu_percent_single_core)) as $per |
        ($rows | group_by(.timestamp) | map(map(.cpu_percent_host) | add)) as $totals |
        {server_count: ($rows | map(.pid) | unique | length),
         samples: ($rows | length),
         per_server_single_core_percent:
           {p50:($per|pct(0.50)), p90:($per|pct(0.90)), p99:($per|pct(0.99)), max:($per|max)},
         tier_total_host_percent:
           {p50:($totals|pct(0.50)), p90:($totals|pct(0.90)), p99:($totals|pct(0.99)), max:($totals|max)}}
      end' "$file"
}

host_cpu() {
    local file="$1"
    if [[ ! -s "$file" ]]; then jq -n '{samples:0,p50:null,p90:null,p99:null,max:null}'; return; fi
    jq -s "$PCT_DEF"'
      map(.cpu_percent) |
      {samples:length, p50:pct(0.50), p90:pct(0.90), p99:pct(0.99), max:max}' "$file"
}

# --- latency ------------------------------------------------------------------------------
# Default: median and max across the per-subscriber percentiles. The median says whether the
# whole fan-out is slow; the max says whether one subscriber is an outlier. They are not the
# true pooled percentiles - use --pool-latency when that distinction matters.
latency_across_subscribers() {
    local dir="$1"
    if ! compgen -G "$dir/subscriber-*/result.json" >/dev/null; then
        jq -n '{source:"none",subscriber_count:0}'
        return
    fi
    jq -s "$PCT_DEF"'
      map(.metrics.latency_us) as $L |
      {source:"per_subscriber_percentiles", subscriber_count: ($L|length)} +
      (["p50","p90","p99","p999","max"]
        | map(. as $k | {($k): ($L | map(.[$k]) | {median: pct(0.50), max: max})})
        | add)' "$dir"/subscriber-*/result.json
}

latency_pooled() {
    local dir="$1"
    if ! compgen -G "$dir/subscriber-*/latency.csv" >/dev/null; then
        jq -n '{source:"none",sample_count:0}'
        return
    fi
    # One numeric stream through sort is far cheaper than loading millions of rows into jq.
    awk -F, 'FNR > 1 && NF >= 2 {print $2}' "$dir"/subscriber-*/latency.csv \
        | sort -n \
        | awk '
            function q(p,   i) { i = int((n - 1) * p) + 1; return v[i] }
            { v[NR] = $1; n = NR }
            END {
              if (n == 0) { print "{\"source\":\"pooled_latency_csv\",\"sample_count\":0}"; exit }
              printf "{\"source\":\"pooled_latency_csv\",\"sample_count\":%d,\"p50\":%.3f,\"p90\":%.3f,\"p99\":%.3f,\"p999\":%.3f,\"max\":%.3f}\n", \
                n, q(0.50), q(0.90), q(0.99), q(0.999), v[n]
            }'
}

# --- network ------------------------------------------------------------------------------
# The physical interface carries the cross-host stream; loopback carries the intra-host
# fan-out, which on the SUB host is where the Leaf and sub-side tiers do their work. Both are
# worth keeping, and only the physical one can be compared against the link speed.
host_network() {
    local dir="$1"
    [[ -s "$dir/network.json" ]] || { jq -n 'null'; return; }
    jq --slurpfile meta "$dir/meta.json" '
      ($meta[0].nic_speed_mbps // []) as $speeds |
      (map(select(.interface != "lo")) | sort_by(-(.tx_bytes_total_delta + .rx_bytes_total_delta)) | first) as $p |
      (map(select(.interface == "lo")) | first) as $l |
      def link(name): ($speeds | map(select(.interface == name)) | first | .speed_mbps // -1);
      {primary:
         (if $p == null then null else
            (link($p.interface)) as $mbps |
            {interface:$p.interface,
             link_speed_mbps: (if $mbps > 0 then $mbps else null end),
             tx_bytes_per_sec_max:$p.tx_bytes_per_sec_max,
             rx_bytes_per_sec_max:$p.rx_bytes_per_sec_max,
             tx_link_utilization_percent:
               (if $mbps > 0 then ($p.tx_bytes_per_sec_max * 8 / ($mbps * 1000000) * 100) else null end),
             rx_link_utilization_percent:
               (if $mbps > 0 then ($p.rx_bytes_per_sec_max * 8 / ($mbps * 1000000) * 100) else null end),
             tx_bytes_total:$p.tx_bytes_total_delta, rx_bytes_total:$p.rx_bytes_total_delta,
             tx_drops:$p.tx_drops_total_delta, rx_drops:$p.rx_drops_total_delta,
             tx_errors:$p.tx_errors_total_delta, rx_errors:$p.rx_errors_total_delta}
          end),
       loopback:
         (if $l == null then null else
            {tx_bytes_per_sec_max:$l.tx_bytes_per_sec_max, tx_bytes_total:$l.tx_bytes_total_delta}
          end)}' "$dir/network.json"
}

# --- NATS internals -----------------------------------------------------------------------
nats_tier() {
    local dir="$1" pattern="$2"
    [[ -s "$dir/nats-queue.json" ]] || { jq -n 'null'; return; }
    jq --arg pat "$pattern" '
      (.servers // []) | map(select(.server | test($pat))) |
      if length == 0 then null else
        {server_count:length,
         pending_bytes_max:(map(.pending_bytes_max)|max),
         pending_messages_max:(map(.pending_messages_max)|max),
         client_connections_max:(map(.connection_count_max)|max),
         out_msgs_max:(map(.out_msgs_max)|max)}
      end' "$dir/nats-queue.json"
}

scalar() { jq -r "$2 // \"\"" "$1" 2>/dev/null || printf ''; }
json_or_null() { [[ -s "$1" ]] && jq -c "${2:-.}" "$1" 2>/dev/null || printf 'null'; }

MODE="$(scalar "$SUB_DIR/meta.json" .mode)"
DURATION="$(scalar "$SUB_DIR/meta.json" .duration_sec)"
MSGS_SENT="$(jq -r '.msgs_sent // .metrics.msgs_sent // 0' "$PUB_DIR/result.json" 2>/dev/null || echo 0)"

pub_aborted=false; [[ -f "$PUB_DIR/cpu-abort.json" ]] && pub_aborted=true
sub_aborted=false; [[ -f "$SUB_DIR/cpu-abort.json" ]] && sub_aborted=true

if ((POOL_LATENCY)); then LATENCY="$(latency_pooled "$SUB_DIR")"; else LATENCY="$(latency_across_subscribers "$SUB_DIR")"; fi

jq -n \
  --slurpfile submeta "$SUB_DIR/meta.json" \
  --slurpfile pubmeta "$PUB_DIR/meta.json" \
  --slurpfile subresult "$SUB_DIR/result.json" \
  --arg pubDir "$PUB_DIR" --arg subDir "$SUB_DIR" \
  --argjson pubAborted "$pub_aborted" --argjson subAborted "$sub_aborted" \
  --argjson msgsSent "${MSGS_SENT:-0}" \
  --argjson latency "$LATENCY" \
  --argjson coreCpu "$(tier_cpu "$PUB_DIR/process-cpu-samples.jsonl" '^core-nats$')" \
  --argjson pubCpu "$(tier_cpu "$PUB_DIR/process-cpu-samples.jsonl" '^publisher$')" \
  --argjson leafCpu "$(tier_cpu "$SUB_DIR/process-cpu-samples.jsonl" '^leaf-[0-9]+-nats$')" \
  --argjson subSrvCpu "$(tier_cpu "$SUB_DIR/process-cpu-samples.jsonl" '^subserver-[0-9]+-nats$')" \
  --argjson subscriberCpu "$(tier_cpu "$SUB_DIR/process-cpu-samples.jsonl" '^subscriber-[0-9]+$')" \
  --argjson pubHostCpu "$(host_cpu "$PUB_DIR/cpu-samples.jsonl")" \
  --argjson subHostCpu "$(host_cpu "$SUB_DIR/cpu-samples.jsonl")" \
  --argjson pubNet "$(host_network "$PUB_DIR")" \
  --argjson subNet "$(host_network "$SUB_DIR")" \
  --argjson coreNats "$(nats_tier "$PUB_DIR" '^core$')" \
  --argjson leafNats "$(nats_tier "$SUB_DIR" '^leaf-')" \
  --argjson subSrvNats "$(nats_tier "$SUB_DIR" '^subserver-')" \
  --argjson pubTcp "$(json_or_null "$PUB_DIR/tcp-queue.json")" \
  --argjson subTcp "$(json_or_null "$SUB_DIR/tcp-queue.json")" \
  --argjson pubIo "$(json_or_null "$PUB_DIR/io.json")" \
  --argjson subIo "$(json_or_null "$SUB_DIR/io.json")" \
  '
  $submeta[0] as $m | $subresult[0] as $r |
  ($m.duration_sec) as $dur |
  ($r.metrics.expected_deliveries // 0) as $expected |
  {
    run: {
      label: $m.label, mode: $m.mode, topology: $m.topology,
      leaf_count: $m.leaf_count, sub_server_count: $m.sub_server_count,
      subscriber_count: $m.subscriber_count,
      target_msgs_per_sec: $m.target_msgs_per_sec, duration_sec: $dur, size: $m.size,
      clock: $m.clock, pacing: $m.pacing, subject: $m.subject,
      cross_host_links: (if $m.mode == "leaf" then $m.leaf_count else $m.subscriber_count end),
      pub_host: $pubmeta[0].host, sub_host: $m.host,
      timestamp: $m.timestamp, pub_dir: $pubDir, sub_dir: $subDir
    },

    validity: {
      aborted_by_cpu_limit: ($pubAborted or $subAborted),
      aborted_on: (if $pubAborted then "pub" elif $subAborted then "sub" else null end),
      pub_cpu_samples: $pubHostCpu.samples,
      sub_cpu_samples: $subHostCpu.samples,
      sub_process_cpu_samples: ($leafCpu.samples + $subSrvCpu.samples + $subscriberCpu.samples),
      actual_msgs_per_sec: (if ($dur // 0) > 0 then ($msgsSent / $dur) else null end),
      rate_accuracy_percent:
        (if (($m.target_msgs_per_sec // 0) > 0 and ($dur // 0) > 0)
         then ($msgsSent / $dur / $m.target_msgs_per_sec * 100) else null end),
      nic_errors_or_drops:
        ((($pubNet.primary.tx_drops // 0) + ($pubNet.primary.rx_drops // 0) +
          ($pubNet.primary.tx_errors // 0) + ($pubNet.primary.rx_errors // 0) +
          ($subNet.primary.tx_drops // 0) + ($subNet.primary.rx_drops // 0) +
          ($subNet.primary.tx_errors // 0) + ($subNet.primary.rx_errors // 0)) > 0)
    },

    delivery: {
      msgs_sent: $msgsSent,
      msgs_received: $r.metrics.msgs_received,
      expected_deliveries: $expected,
      msg_loss: $r.metrics.msg_loss,
      msg_loss_ratio: (if $expected > 0 then ($r.metrics.msg_loss / $expected) else null end)
    },

    latency_us: $latency,

    cpu: {
      host_percent: { pub: $pubHostCpu, sub: $subHostCpu },
      tiers: { core: $coreCpu, publisher: $pubCpu,
               leaf: $leafCpu, subserver: $subSrvCpu, subscriber: $subscriberCpu }
    },

    network: { pub: $pubNet, sub: $subNet },

    nats: { core: $coreNats, leaf: $leafNats, subserver: $subSrvNats },

    tcp_queue: { pub: $pubTcp, sub: $subTcp },

    io_wait_percent_max: { pub: ($pubIo.io_wait_percent.max // null),
                           sub: ($subIo.io_wait_percent.max // null) }
  }' > "$OUT"

echo "Summary: $OUT"

if ((APPEND_CSV)); then
    mkdir -p "$(dirname "$CSV")"
    header='label,mode,leaf_count,sub_server_count,subscriber_count,rate,size,cross_host_links,msg_loss,msg_loss_ratio,rate_accuracy_percent,p50_median_us,p99_median_us,p99_max_us,p999_max_us,leaf_cpu_p50,leaf_cpu_p99,leaf_tier_total_p99,subserver_cpu_p50,subserver_cpu_p99,subserver_tier_total_p99,core_cpu_p99,pub_host_cpu_p99,sub_host_cpu_p99,pub_tx_util_pct,sub_rx_util_pct,leaf_pending_bytes_max,subserver_pending_bytes_max,pub_send_q_max,sub_recv_q_max,io_wait_max,aborted,sub_dir'
    [[ -f "$CSV" ]] || printf '%s\n' "$header" > "$CSV"
    # latency_us holds {median,max} per percentile by default and a bare number under
    # --pool-latency; lat/latmax read both shapes without ever emitting the object itself.
    jq -r 'def lat(k): (.latency_us[k]) as $v | if ($v|type) == "object" then $v.median else $v end;
      def latmax(k): (.latency_us[k]) as $v | if ($v|type) == "object" then $v.max else $v end;
      [
        .run.label, .run.mode, .run.leaf_count, .run.sub_server_count, .run.subscriber_count,
        .run.target_msgs_per_sec, .run.size, .run.cross_host_links,
        .delivery.msg_loss, .delivery.msg_loss_ratio, .validity.rate_accuracy_percent,
        lat("p50"), lat("p99"), latmax("p99"), latmax("p999"),
        .cpu.tiers.leaf.per_server_single_core_percent.p50,
        .cpu.tiers.leaf.per_server_single_core_percent.p99,
        .cpu.tiers.leaf.tier_total_host_percent.p99,
        .cpu.tiers.subserver.per_server_single_core_percent.p50,
        .cpu.tiers.subserver.per_server_single_core_percent.p99,
        .cpu.tiers.subserver.tier_total_host_percent.p99,
        .cpu.tiers.core.per_server_single_core_percent.p99,
        .cpu.host_percent.pub.p99, .cpu.host_percent.sub.p99,
        .network.pub.primary.tx_link_utilization_percent,
        .network.sub.primary.rx_link_utilization_percent,
        .nats.leaf.pending_bytes_max, .nats.subserver.pending_bytes_max,
        .tcp_queue.pub.send_q_max, .tcp_queue.sub.recv_q_max,
        ([.io_wait_percent_max.pub, .io_wait_percent_max.sub] | map(select(. != null)) | max),
        .validity.aborted_by_cpu_limit, .run.sub_dir
      ] | map(if . == null then "" else . end) | @csv' "$OUT" >> "$CSV"
    echo "Appended a row to: $CSV"
fi

# Human-readable digest so the common case needs no jq at all.
jq -r '
  def f(x): if x == null then "-" else (x * 100 | round / 100 | tostring) end;
  def lat(k): (.latency_us[k]) as $v | if ($v|type) == "object" then $v.median else $v end;
  def latmax(k): (.latency_us[k]) as $v | if ($v|type) == "object" then $v.max else $v end;
  def tier(name; t):
    if (t == null or t.server_count == 0) then "  \(name): (no samples)"
    else "  \(name)  servers=\(t.server_count)  1台あたり p50/p90/p99/max = \(f(t.per_server_single_core_percent.p50))/\(f(t.per_server_single_core_percent.p90))/\(f(t.per_server_single_core_percent.p99))/\(f(t.per_server_single_core_percent.max)) %core   層合計 p99/max = \(f(t.tier_total_host_percent.p99))/\(f(t.tier_total_host_percent.max)) %host"
    end;
  "\(.run.label)  [\(.run.mode)]  L=\(.run.leaf_count) S=\(.run.sub_server_count) N=\(.run.subscriber_count)  rate=\(.run.target_msgs_per_sec) size=\(.run.size)",
  "  \(.run.topology)",
  "",
  "配信      received=\(.delivery.msgs_received)/\(.delivery.expected_deliveries)  loss=\(.delivery.msg_loss) (\(f((.delivery.msg_loss_ratio // 0) * 100))%)",
  "レイテンシ p50=\(f(lat("p50")))  p90=\(f(lat("p90")))  p99=\(f(lat("p99")))  p999=\(f(lat("p999"))) us  (\(.latency_us.source))",
  (if .latency_us.source == "per_subscriber_percentiles"
   then "           最も遅い1台の p99=\(f(latmax("p99")))  p999=\(f(latmax("p999"))) us"
   else empty end),
  "",
  "CPU 層別",
  tier("core      "; .cpu.tiers.core),
  tier("publisher "; .cpu.tiers.publisher),
  tier("leaf      "; .cpu.tiers.leaf),
  tier("subserver "; .cpu.tiers.subserver),
  tier("subscriber"; .cpu.tiers.subscriber),
  "CPU ホスト  pub p50/p99/max = \(f(.cpu.host_percent.pub.p50))/\(f(.cpu.host_percent.pub.p99))/\(f(.cpu.host_percent.pub.max)) %   sub p50/p99/max = \(f(.cpu.host_percent.sub.p50))/\(f(.cpu.host_percent.sub.p99))/\(f(.cpu.host_percent.sub.max)) %",
  "",
  "NIC       pub tx \(f(.network.pub.primary.tx_bytes_per_sec_max)) B/s (回線 \(f(.network.pub.primary.tx_link_utilization_percent))%)   sub rx \(f(.network.sub.primary.rx_bytes_per_sec_max)) B/s (回線 \(f(.network.sub.primary.rx_link_utilization_percent))%)",
  "          ホスト間リンク数 \(.run.cross_host_links)   drops/errors: \(if .validity.nic_errors_or_drops then "あり ← この実行は無効" else "なし" end)",
  "          loopback tx  pub \(f(.network.pub.loopback.tx_bytes_per_sec_max)) B/s   sub \(f(.network.sub.loopback.tx_bytes_per_sec_max)) B/s  (段内fan-outの量)",
  "NATS詰まり leaf pending_bytes_max=\(.nats.leaf.pending_bytes_max // "-")   subserver=\(.nats.subserver.pending_bytes_max // "-")   core=\(.nats.core.pending_bytes_max // "-")",
  "TCPキュー  pub send_q_max=\(.tcp_queue.pub.send_q_max // "-")   sub recv_q_max=\(.tcp_queue.sub.recv_q_max // "-")",
  "io wait    max pub=\(f(.io_wait_percent_max.pub))%  sub=\(f(.io_wait_percent_max.sub))%",
  "",
  "有効性    実効レート \(f(.validity.actual_msgs_per_sec)) msgs/s (目標比 \(f(.validity.rate_accuracy_percent))%)   CPU打ち切り: \(if .validity.aborted_by_cpu_limit then "あり(\(.validity.aborted_on))" else "なし" end)",
  "          サンプル数 pub=\(.validity.pub_cpu_samples) sub=\(.validity.sub_cpu_samples) (0 なら補助指標は空)"
' "$OUT"
