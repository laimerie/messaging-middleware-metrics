# nats

NATS Core performance verification environment. This is one of several messaging
middleware benchmark environments in this repo (see the repo-root `CLAUDE.md` for the
overall structure); everything in this file is scoped to `nats/` only. See `README.md`
(this directory) for setup/usage.

## Conventions

- **NATS Core only.** `docker-compose.yml` must not gain `-js` (JetStream) — that's a
  separate concern from what this project benchmarks. If JetStream testing is ever added,
  do it as an additional service/profile, not a flag change to the existing `nats` service.
- **Single node only.** No cluster port (6222) is published; no multi-node scenarios.
- **Native Bash (`.sh`) is the scripting language** for this project, targeting a real
  Linux host directly (see README.md's "実機Linuxで実行する"). This replaced an earlier
  PowerShell (`.ps1`) implementation — see "Why Bash, not PowerShell" below for what
  motivated the rewrite and which PowerShell-specific pitfalls it structurally eliminates.
- **Every benchmark run writes to a fresh timestamped folder** under `results/<category>/`
  via `new_run_dir` in `scripts/common.sh` — never overwrite a prior run's output.
  Timestamps use `date +%Y%m%d-%H%M%S` (no colons — kept from the original Windows
  filename constraint, harmless on Linux too).
- **`nats bench --csv` output has a `#`-prefixed header line** (e.g. `#RunID,ClientID,MsgCount,...`).
  Any parsing of this CSV must skip that line (`tail -n +2`) before processing — see
  `parse_nats_bench_csv_aggregate` in `scripts/common.sh` for the pattern.
- **`nats bench` is subcommand-based** (`nats bench pub|sub|service serve|service request`),
  not a flat `--pub/--sub` command. Flags drift between CLI releases — check
  `nats bench <subcommand> --help` before assuming a flag exists.
- **`jq` is a hard prerequisite** for all JSON handling (`meta.json`/`result.json`
  construction, `scenarios.json` parsing) — chosen over hand-built JSON strings for
  correctness/escaping safety. Any real Linux target installs it via `apt`/`yum`.
- **Leaf ノードは SUB ホストに置く。PUB ホストに置いても fan-out の負荷は減らない。**
  `bench-leaf-2host-native.sh --mode leaf` は当初 Leaf を全て PUB ホスト上に立てていたが、
  この配置では Subscriber 100 個分の TCP 接続がそのまま PUB ホストの NIC を通るため、
  ホスト間を渡るコピー数は Direct 構成と変わらない（Leaf を挟んでも N のまま）。実測は
  NIC 飽和側に律速され、Core/Leaf の比較になっていなかった。Leaf を SUB ホストへ移すと
  ホスト間の接続数が N（Subscriber数）から L（Leaf数）に落ちる。**これが Leaf 階層化の
  唯一の目的なので、Leaf を PUB ホスト側へ戻す変更をしてはいけない。**
  Leaf の下にもう一段 `--sub-server-count S` を積める:
  `core(PUB) → leaf×L(SUB) → subserver×S(SUB) → subscriber×N(SUB)`。`S=0` で Leaf 直結
  （2段）。段の割り当ては全て round-robin（`subserver j → leaf j mod L`、
  `subscriber i → subserver i mod S`）。
- **Leaf を SUB 側に置いた結果、`--role pub --mode leaf` では `--sub-host` が必須。**
  NATS の購読 interest は leaf hop を越えるとき重複排除されるので、Core の `/connz` や
  `/leafz` から Subscriber 数を数えることは**できない**（Leaf 1本につき 1 件に集約される）。
  PUB 側は SUB ホストの監視ポートを直接引いて購読数を数え、併せて Core が受理した leaf
  接続数が L に達したことを確認してから publish を開始する。`/leafz` の接続本数は
  `.leafnodes` フィールド。
- **監視サンプラーを PID ごとのプロセス起動で書かない。** サンプラーは測定対象ホスト自身の
  上で動くので、その fork コストがそのまま被測定レイテンシのノイズになる。Subscriber 100 個
  ＋ Leaf/sub側サーバーの構成では、PID ごとに `awk`/`jq`/`date`/`nproc` を起動する実装が
  1 インターバルあたり数百プロセスに達し、ループ 1 周が `--cpu-interval-sec` を超えて
  `process-cpu.json` が空になった（＝CPU 証跡が丸ごと取れない）。`/proc/<pid>/stat` は
  awk 1 回で全 PID を舐め、JSON 化は `jq -R` に TSV を流し込む 1 回にまとめる。
  同様に NATS の `/varz`・`/connz` はサーバー台数分を並列取得し、1 サーバー 1 ファイルに
  書いてから連結する（同一ファイルへの並列追記は行を壊す）。定期サンプルに `?subs=1` を
  付けない — 下流は pending/traffic カウンタしか読んでおらず、SUB ホストでは購読 1 件ずつの
  巨大な配列を毎秒引くことになる。
- **両ホストの結果ディレクトリ名にはロール接尾辞（`-pub` / `-sub`）を必ず残す。**
  実測環境では両ホストが共有NAS上の同じ `results/` ツリーへ書く。`new_run_dir` は
  `<timestamp>_<label>` を作るだけなので、両ロールに同じ `--label` を渡していて起動秒が
  一致すると**同一ディレクトリに相乗りして `meta.json` と `result.json` を互いに上書きする**。
  接尾辞は衝突回避と、`summarize-leaf-run.sh` のペアリングキーを兼ねている。
- **層ごとのCPUは「1台あたり」と「層合計」の2通りを出す。** 台数方向だけで分位点を取ると、
  Leaf 5台なら p90/p99 が max と同値になり情報がない。`per_server_single_core_percent` は
  層内の全プロセス×全インターバルをプールした分位点（1台がどれだけ働いたか）、
  `tier_total_host_percent` は各インターバルで層内を合計してからの分位点（層全体がホストの
  何%を使ったか）。台数を変える比較では後者が効く。**`subserver j → leaf j mod L` のため
  下流数は均等とは限らない**（L=3, S=5 なら 2/2/1）ので max を捨てないこと。
- **`network.json` の bytes/s だけでは飽和判定ができない。** 回線容量が分からないため、
  `meta.json` に `nic_speed_mbps`（`/sys/class/net/<if>/speed`、仮想・down は -1）を記録し、
  サマリ側で利用率%に換算している。物理NICとloopbackは分けて見る — SUBホストでは段内fan-outが
  全てloopbackを通るので、`lo` を混ぜるとホスト間トラフィックの評価を誤る。
- **`cpu.json` は意図的に書いていない。** `summarize-leaf-run.sh` は p90/p99 を出すため
  `cpu-samples.jsonl` を直接読む。派生ファイル側は p95 しか持っておらず噛み合わなかったため、
  誰も読まない中間ファイルになっていた。復活させるなら summarizer 側も揃えること。
  サンプリング間隔は `meta.json` の `cpu_interval_sec`（`cpu_consecutive` も同様）にある —
  以前は `cpu.json` にしか無く、実行パラメータの記録漏れだった。
- **Subscriber の割り当ては run 直下の `subscribers.json` 1つにまとめる。**
  `subscriber-<i>/meta.json` を N 個作ると、N=100 の実行で小ファイルが 100 個増えるだけで
  内容は 1 つの配列に収まる。起動前に書くので、途中で起動に失敗しても割り当て表は残る。
- **サマリのレイテンシは既定では「分位点の分位点」で近似値。** 各subscriberの p99 を集めて
  中央値と最大を出している。厳密な全体分位点が要る場合は `--pool-latency`
  （`subscriber-*/latency.csv` を全件プール）。実測で両者は数%ずれる。
- See `TODO.md` for the active backlog and priority order of follow-up work.
- All `bench-*.sh` scripts accept `--label` for consistency — `scripts/scenarios.json`-driven
  runs depend on this to name result folders after the scenario instead of each script's
  internal default.
- **`msg_loss` must be computed from the requested parameter value (`$MSGS`/`$total_msgs`),
  never from `nats bench pub`'s own reported total.** If pub fails outright (confirmed:
  unthrottled bursts above ~10-25 concurrent clients hit `flushing: nats: timeout` on the
  Windows/Docker Desktop environment this was first measured on), pub.csv is empty, its
  reported total is 0, and using that as "expected" makes msg_loss silently read 0 even
  though nothing was delivered. Always check `nats bench pub`'s exit code too and
  propagate failure (non-zero script exit) - don't let the script report success just
  because it reached the end of its statements.
- **`nats bench sub` does not accept `--multisubjectmax`** (pub-only flag). When building
  `--multisubject` argument lists, always split them into separate pub-args/sub-args sets
  (sub gets `--multisubject` alone) — passing pub's full multisubject args to sub makes it
  print a usage error and exit, so the subscription never registers and every message is
  silently lost. This bug existed in an earlier version of `bench-scalability.ps1` (the
  predecessor to today's `bench-scalability.sh`); fixed there and avoided from the start
  in `bench-throughput.sh`.
- **Rate limiting**: `convert_to_nats_sleep_duration` in `common.sh` converts a target
  aggregate msgs/sec into the per-client `--sleep=DURATION` `nats bench pub` expects
  (`nats bench` has no direct `--rate` flag). Reuse this helper rather than recomputing
  the conversion in each script.
- **Result reporting**: every `bench-*.sh` script calls `save_result` (in `common.sh`)
  in addition to `save_meta` — `save_meta` is reproducibility info (tool/server versions),
  `save_result` is the parsed metrics (`result.json` per run + one row appended to
  `results/run-index.csv`, the cross-category summary table). Use
  `parse_nats_bench_csv_aggregate` (strips the `#`-prefixed header, sums multi-client CSV
  rows using MAX duration across rows since clients run concurrently) to build the
  metrics from `nats bench --csv` output rather than re-deriving this per script.
  `msg_loss` is computed as `pub total * SubClients - sub total` because each independent
  subscriber client receives a full copy of the published stream (fan-out, not a work
  queue — confirmed empirically), not `pub total - sub total`.
- **One-way latency uses a custom C++ tool, not the `nats` CLI.** `bench-latency.sh`
  (`nats bench service serve/request`) measures round-trip time only. True publisher→
  subscriber one-way latency is `tools/latency_oneway/` (C++), driven by
  `scripts/bench-latency-oneway.sh`, built inside `docker/latency-tool/Dockerfile`.
  **This tool's language/runtime is fixed to CentOS 7 / gcc 11 / C++17 to match
  production** — do not port it to Python or another language, even for convenience;
  a non-native client's own overhead (GC, interpreter, event-loop scheduling) would get
  measured as if it were NATS latency (see `TODO.md` #4 for the full reasoning).
  `nats.c`'s CMake package exports as `cnats` (not `NATS` as its README implies) —
  `find_package(cnats REQUIRED)`, target `cnats::nats_static`, and `find_package(Threads
  REQUIRED)` must run first or CMake fails to resolve `cnats`'s link interface.
- **`latency_oneway` has no unthrottled-burst mode at all — `--rate` (msgs/sec) and
  `--duration-sec` are both required; `--msgs` does not exist as a CLI flag.** Total
  message count is derived (`round(rate * duration)`), never settable directly. This was
  a deliberate redesign, not the original interface: an earlier version took `--msgs`
  directly with an optional `--rate` that defaulted to 0 ("unthrottled"), and unthrottled
  bursts measured queueing delay building up in the subscriber, not NATS's actual
  steady-state one-way latency (confirmed by measurement: ~2.3ms at msg 0 climbing to
  ~5.3ms by msg 999 in one 1000-msg unthrottled run). `bench-latency-oneway.sh` and
  `bench-crosshost.sh` (its `--tool latency-oneway` mode) match this —
  `--target-msgs-per-sec`/`--duration-sec`, not `--msgs`. `bench-crosshost.sh`'s
  `--tool nats-bench` mode is unaffected and keeps `--msgs`/unthrottled-by-default
  semantics, since a burst/saturation throughput test IS a meaningful thing to measure —
  only the one-way *latency* tool's burst mode was meaningless, not throughput testing
  in general.
- **`docker/latency-tool` is a general "host client" image, not just the one-way latency
  tool.** It bundles both `latency_oneway` and the `nats` CLI, and its `ENTRYPOINT` is a
  generic wrapper (`entrypoint.sh`) — callers must name the binary explicitly (e.g.
  `docker compose run --rm latency-tool latency_oneway --mode both ...` or
  `... latency-tool nats bench pub ...`), it no longer defaults to `latency_oneway`.
  `latency_oneway --mode pub`/`--mode sub` (added for TODO.md #3) let publisher and
  subscriber run in separate containers/processes; `--mode both` (same-host, single
  process) is unchanged and still the default.
- **`tc netem` does not work on Docker Desktop for Windows** — the bundled WSL2/Hyper-V
  kernel lacks the `sch_netem` module (confirmed: plain `tc qdisc add ... pfifo`
  succeeds, `... netem` fails with `RTNETLINK answers: No such file or directory`,
  regardless of `cap_add: NET_ADMIN`). This is a host-kernel limitation, not fixable from
  inside a container — expected to work on a real Linux Docker host (see README.md).
  `entrypoint.sh`'s netem injection is therefore non-fatal on failure (warns and
  continues) — do not make it `set -e`-fatal, and don't assume `--netem-delay-ms`
  actually did anything without checking for that warning in the output.
- **Never retrieve `docker/latency-tool` results via a `-v <local>:/out` bind mount —
  always use `docker_run_and_copy_out` (`common.sh`), which uses `docker cp` instead.**
  A bind-mount path is resolved by the *Docker daemon*, not by whoever runs the `docker`
  command, so it silently returns nothing the moment `docker` points at a remote host via
  `docker context` (e.g. SSH to a Linux box from a different driver machine — see
  README.md). `docker cp` works identically for local and remote daemons. Because a bind
  mount used to be what created `/out` automatically, `docker/latency-tool/entrypoint.sh`
  now does `mkdir -p /out` itself — don't remove that, `latency_oneway`'s
  `std::ofstream` writes fail silently (no exception) if the directory doesn't exist, so
  the tool prints a normal-looking summary to stdout while quietly writing no
  `result.json`/`oneway.csv` at all.
- **Every path in this project uses `/`, never `\`** — this is native Linux Bash, so
  there's no Windows-path concern to design around in the first place (unlike the
  PowerShell predecessor, which needed a deliberate pass for this).
- **One-way latency has a real, rate-dependent floor that gets *worse* at lower
  `--target-msgs-per-sec` — this is NATS Core's own behaviour, not a `latency_oneway`
  bug, and confirmed on real Linux hardware (not just Docker Desktop).** Measured on the
  same real-Linux host: 100/s → p50 212us, 1000/s → p50 87-104us, 30000-50000/s → p50
  29-34us, all with `--pacing auto`; forcing `--pacing busy` at 300/s still gave p50
  111.5us (min 41us) — busy-spin only removes the *publisher's* send-timing jitter, so
  this residual is NOT scheduling error in `pacedWaitUntil`. Confirmed independently with
  the stock `nats` CLI (`nats bench service serve`/`request`, a different language/client
  entirely) at the equivalent low rate: min 91us / p50 173.67us round-trip — roughly
  double the `latency_oneway` one-way numbers at the same rate, i.e. the same floor shows
  up in a completely independent Go client, so it is NATS Core's, not this tool's. Root
  cause: nats.c's subscription delivery is a dedicated dispatch thread woken via a
  condition variable (not busy-polled) from the socket-reader, and the Go server's
  per-connection goroutine has the same wake-from-idle shape — at low rates each message
  pays a full idle-thread wake/context-switch cost on both hops; at high rates back-to-back
  messages keep those threads runnable and amortize it away. **Do not "fix" this by
  splitting `--mode pub`/`--mode sub` into separate processes/containers — that changes
  network topology, not this wake-latency path, and does not close the gap** (confirmed:
  the effect reproduces identically in `--mode both`, and separating adds a Docker network
  hop on top if anything). If a cleaner low-rate baseline is ever needed, look at pinning
  the `nats` container and `latency-tool` to isolated cores (`cpuset`/`--cpus` in
  `docker-compose.yml`, not currently set) to cut *scheduler noise* — that's a different
  problem from this rate-dependent floor and won't remove it either.

## Why Bash, not PowerShell

This project was originally written in PowerShell (`.ps1`), matching the primary shell
on the machine it was first developed on. Once the actual verification target became "a
real Linux server reachable via SSH" rather than the Windows/Docker Desktop dev machine,
it became clear the scripts themselves should just be native Bash rather than PowerShell
Core (`pwsh`) running on Linux — simpler toolchain, no cross-platform PowerShell
dependency to install on the target, and idiomatic for the actual runtime.

This rewrite turned out to *simplify* the implementation, not just translate syntax —
several PowerShell-specific problems fought hard in the original version don't exist
structurally in Bash:

- **`Start-Job` ran script blocks in a separate runspace**, inheriting neither the
  caller's working directory (`Push-Location`) nor its function definitions — every
  backgrounded subscriber needed explicit `Set-Location`/re-dot-sourcing workarounds.
  Bash's `&` backgrounding runs in the *same* shell, inheriting both naturally.
- **A child script's `exit` terminated the entire PowerShell host process**, not just
  that script's scope, when invoked in-process (`& script.ps1`) — the orchestrator
  (`run-all-benchmarks.ps1`) needed an `Invoke-ScriptIsolated` helper that spawned a real
  child `powershell.exe` process just to contain this. In Bash, `bash script.sh` is
  already a genuine child process — `exit` inside it only ever ends that child.
- **Native command stdout leaking into a function's `return` value** — an uncaptured
  native process's output inside a PowerShell function that also `return`s a value gets
  bundled into that return value as an array at the call site, corrupting exit-code
  checks. This bit the project twice (`Invoke-ScriptIsolated`, then again in
  `Invoke-DockerRunAndCopyOut`). Bash functions have no equivalent hazard — `return` sets
  only a numeric exit status, output and return value are never conflated.
- **`-ConnectionCounts 1,10,50` array parameters got corrupted crossing a process
  boundary** (`-File` invocation) — .NET's numeric conversion silently read the comma as
  a thousands separator, turning `1,5` into `15`. Bash just passes the comma-separated
  string through as one token (`"1,5,10,25"`), split manually via
  `IFS=',' read -ra COUNTS <<< "$value"` — no implicit type coercion to fight.
- **`$ErrorActionPreference = "Stop"` plus a Windows-only cmdlet not resolving** (e.g.
  `Get-NetTCPConnection` under PowerShell Core on Linux) needed an explicit
  `Get-Command ... -ErrorAction SilentlyContinue` guard, since a *missing* cmdlet's
  resolution failure wasn't suppressed the same way a *failing* cmdlet's would be. `set
  -e` in Bash has no equivalent asymmetry.

None of this means Bash is bug-free in general — just that this specific, recurring
class of friction (separate-runspace semantics, in-process `exit` propagation, stdout/
return-value conflation, cross-process array marshalling) doesn't apply to a plain Bash
script calling another plain Bash script as a real child process. See `TODO.md`'s
addenda under #3 for the full migration writeup, including a Windows-Git-Bash-specific
`docker` argument path-mangling issue found *during* verification of the rewritten
scripts (documented in README.md's "Testing on Windows" section) — unrelated to the
PowerShell-vs-Bash choice itself, since it's a Git-Bash/MSYS artifact that doesn't occur
on the real Linux target either way.
