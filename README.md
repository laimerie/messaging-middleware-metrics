# messaging_middlewear — NATS Core performance verification

Docker を使用して **NATS Core** サーバー（JetStream なし、
シングルノード、クラスタリングなし）のベンチマークを行うための環境とツール。公式の `nats bench` CLI に加え、
カスタムの一方向レイテンシ測定ツールを使用します。スクリプトはネイティブのBash（`scripts/*.sh`）で記述されており、
Linux（本番環境に近いターゲット）上で直接実行することを想定しています。Windows/Git Bashマシンから
これらを開発・検証する際の注意点については、以下の「Windowsでのテスト」を参照してください。

## Scope

- NATS **Core** のみ — `docker-compose.yml` では、意図的に `-js` を省略しています。後で JetStream
  のベンチマークが必要になった場合は、この設定を変更するのではなく、
  別のサービス／プロファイルとして追加してください。
- シングルノード — クラスタポート 6222 は公開されません。マルチノードの耐障害性テストは行われません。
- 重点領域は3つ：スループット、レイテンシ（パーセンタイル）、接続数／被験者数のスケーラビリティ。

## ⚠️ 実行環境の限界（結果の解釈にあたって必読）

このプロジェクトの計測を **Windows上のDocker Desktop（WSL2/Hyper-V経由）** で行った場合、
本番相当の環境（CentOS 7の実機/VM）とは以下の点で異なる。**絶対値（秒間X件、p99 Yms等）を
そのまま容量計画・SLA判断に使わない**こと。実機Linux上でネイティブに実行すればこの限界は
解消される（下記「実機Linuxで実行する」参照）。

- **仮想化層が余分に挟まる**: `クライアント(Windows) → WSL2 VMへのNAT/ポートフォワード →
VM内のdocker0ブリッジ → コンテナのveth → NATSサーバー` という経路になり、本番の
  「物理機/VM上で直接動くNATS」より経路が長い。レイテンシは本番より高く、スループットは
  本番より低く出やすい。
- **ノイジーネイバー**: WSL2 VMは開発機のCPU/メモリをブラウザ・IDE・ウイルス対策ソフト等と
  共有しており、本番の専用サーバーのような隔離された実行環境ではない。瞬間的なスケジューリング
  遅延やジッターが計測値に混入する。
- **コンテナ間通信は物理ネットワークを経由しない**（詳細は`TODO.md`の#3参照）: 同一Dockerホスト
  上のコンテナ間通信は仮想NIC＋カーネル内ブリッジで完結し、物理NIC・スイッチ・伝搬遅延を
  経由する本番のネットワーク特性を再現できない。

| 用途                                                 | Windows/Docker Desktopの結果                               |
| ---------------------------------------------------- | ---------------------------------------------------------- |
| 相対比較（パラメータ変更による傾向確認）             | 信頼できる                                                 |
| 開発中の簡易リグレッション検知（同一環境内での比較） | 信頼できる                                                 |
| 絶対値としての容量計画・SLA判断                      | **信頼できない** — 実機Linuxで再計測してから確定させること |

## Prerequisites

- Docker + Docker Compose v2 (`docker compose ...`), daemon running
- `bash`, `jq`, `awk`, `curl` — standard on any Linux box; on Windows, Git Bash provides
  `bash`/`awk`/`curl` but not `jq` (see "Testing on Windows" below)

## Setup

```bash
# 1. Install the nats CLI (one-time)
./scripts/install-nats-cli.sh

# 2. Start the NATS Core server
./scripts/start-server.sh

# 3. Verify the whole pipeline end-to-end
./scripts/smoke-test.sh
```

## Running benchmarks

```bash
# Throughput — vary --size / --pub-clients / --sub-clients / --subject across separate runs
./scripts/bench-throughput.sh
./scripts/bench-throughput.sh --size 16384 --label large-msg
./scripts/bench-throughput.sh --pub-clients 4 --sub-clients 4 --label 4x4-clients
./scripts/bench-throughput.sh --target-msgs-per-sec 5000 --label sustained-5k   # rate-limited, not max speed
./scripts/bench-throughput.sh --use-multi-subject --multi-subject-max 100 --label multisubject

# Latency (round-trip, via nats CLI request/reply) — quick official-CLI-only check
./scripts/bench-latency.sh
./scripts/bench-latency.sh --request-clients 10 --label 10-clients

# Latency (one-way, publisher -> subscriber) — the accurate measurement; see TODO.md #4.
# Built in C++ (CentOS 7 / gcc 11) to match production and avoid client-runtime overhead.
# --target-msgs-per-sec and --duration-sec are both required (default 1000/s, 10s) - there is
# no unthrottled-burst mode: an unthrottled send measures subscriber queueing delay, not
# NATS's actual steady-state one-way latency (confirmed by measurement — see CLAUDE.md).
./scripts/bench-latency-oneway.sh
./scripts/bench-latency-oneway.sh --target-msgs-per-sec 5000 --duration-sec 30 --label rate5000

# Connection / subject scalability sweep
./scripts/bench-scalability.sh
./scripts/bench-scalability.sh --connection-counts 1,10,50,100
./scripts/bench-scalability.sh --use-multi-subject --multi-subject-max 100
./scripts/bench-scalability.sh --target-msgs-per-sec 5000
```

```bash
# Cross-host: publisher and subscriber in SEPARATE Docker containers (separate network
# namespaces), simulating "Linux host A / host B" rather than same-process/same-container
# measurement. NATS server itself stays a single node (not clustering) - see TODO.md #3.
./scripts/bench-crosshost.sh
./scripts/bench-crosshost.sh --tool nats-bench --label throughput-crosshost
./scripts/bench-crosshost.sh --netem-delay-ms 20 --label with-20ms-delay
```

`--netem-delay-ms` tries to inject artificial network delay (`tc netem`) to approximate
real inter-host latency — same-Docker-host containers otherwise talk over a
near-zero-latency virtual bridge, not a physical NIC. Rough guidance for the value: ~1ms
same datacenter, 10-30ms same region/different AZ, 80-150ms cross-continent. **Confirmed
non-functional on Docker Desktop for Windows** (WSL2/Hyper-V): plain `tc` works, but
`tc ... netem` specifically fails because the bundled kernel lacks the `sch_netem`
module — this is a host-kernel limitation, not fixable from inside a container. The
script detects this, warns, and continues without the delay rather than failing the
whole run; it should work on a genuine Linux Docker host (worth re-testing there). See
`TODO.md` #3 for the full writeup.

## 実機Linuxで実行する（推奨・本来の使い方）

```bash
ssh user@<linux-host>
cd messaging_middlewear
./scripts/install-nats-cli.sh
./scripts/start-server.sh
./scripts/run-all-benchmarks.sh
```

This makes `docker compose build`/`run` execute entirely on that machine: all
`yum install`/`gcc`/`cmake` steps in `docker/latency-tool/Dockerfile` run on its CPU,
not Windows'. All results retrieval goes through `docker cp`
(`docker_run_and_copy_out` in `scripts/common.sh`), not a `-v` bind mount — this also
means it keeps working unchanged if you ever _do_ need to point `docker` at a remote
daemon instead (see "Option: remote Docker daemon over SSH" below).

`tc netem` (`--netem-delay-ms` above) is expected to work on a real Linux kernel, since
the missing `sch_netem` module is specific to Docker Desktop's bundled WSL2/Hyper-V
kernel — worth confirming once you're on real Linux.

### Option: remote Docker daemon over SSH (keep driving scripts from elsewhere)

If instead you want to keep invoking the scripts from a different machine and just point
the `docker` CLI's daemon connection at a remote Linux host, that works too — no script
changes needed either way, since results are always retrieved via `docker cp` rather than
a bind mount (a bind-mount path is resolved by the _Docker daemon_, not by whoever runs
the `docker` command, so it silently returns nothing the moment the daemon is remote):

```bash
docker context create linux-bench --docker "host=ssh://user@<linux-host>"
docker context use linux-bench
# From here on, run the scripts exactly as documented above - no other changes needed.
```

```bash
# Run everything at once (smoke-test + every scenario in scripts/scenarios.json)
./scripts/run-all-benchmarks.sh
./scripts/run-all-benchmarks.sh --skip-smoke
./scripts/run-all-benchmarks.sh --stop-on-failure
```

Edit `scripts/scenarios.json` to add/change/remove scenarios for `run-all-benchmarks.sh` -
no code changes needed. Each entry names a `script` (one of the `bench-*.sh` files
above), a `category`, a `label`, and a `params` object whose keys are that script's flag
names in kebab-case (minus the leading `--`), e.g. `"target-msgs-per-sec": 1000`.

Stop the server when done:

```bash
./scripts/stop-server.sh
```

## Results layout

Every run writes into its own timestamped folder — nothing is overwritten:

```
results/<category>/<yyyyMMdd-HHmmss>_<label>/
  pub.csv / sub.csv / request.csv / oneway.csv   # raw machine-readable per-message data
  meta.json                         # run params + client tool / server version — reproducibility
  result.json                       # parsed metrics (msgs/sec, MB/sec, p50/p99 latency, msg_loss)
results/run-index.csv                # one row per run across ALL categories — sparse common
                                      # schema (throughput/scalability leave latency columns
                                      # blank and vice versa) for cross-run comparison at a glance
```

`result.json` and `run-index.csv` are written by every `bench-*.sh` script via
`save_result` in `scripts/common.sh` (the one-way latency tool writes its own
`result.json` directly in C++; the bash wrapper just appends the `run-index.csv` row
for it).

`run-index.csv` gives a flat, cross-category summary table of every run, but this project
still has no charting/visualization layer — that remains a follow-up phase once enough
real benchmark runs exist to be worth plotting.

## `nats bench` command shape (as of the CLI installed here)

`nats bench` is subcommand-based, not a single flat command:

- `nats bench pub <subject> ...` — publisher, its own process
- `nats bench sub <subject> ...` — subscriber, its own process (run concurrently with `pub`)
- `nats bench service serve <subject> ...` / `nats bench service request <subject> ...` — request/reply, used for latency
- `nats bench js ...` / `nats bench kv ...` — JetStream/KV (out of scope here)

Flags do drift between CLI releases — run `nats bench --help`, `nats bench pub --help`, etc.
after installing/upgrading and compare against what these scripts pass.

## Testing on Windows (Git Bash)

The scripts are written for native Linux and expect nothing Windows-specific, but if
you're iterating on them from a Windows machine via Git Bash before deploying to a real
Linux box, two local-only setup steps and one gotcha are worth knowing:

- **`jq` is not bundled with Git Bash.** Download a Windows build (e.g.
  `jq-windows-amd64.exe` from the [jq releases page](https://github.com/jqlang/jq/releases))
  and place it as `jq.exe` somewhere on `PATH` (e.g. `$HOME/.local/bin/`). Any real Linux
  target installs it via `apt`/`yum` instead — nothing in the scripts assumes a
  Windows-specific `jq`.
- **The winget-installed `nats` CLI isn't on Git Bash's `PATH` by default** — it lives
  under `AppData\Local\Microsoft\WinGet\Packages\...`. Copy or symlink it to the same
  `PATH` directory as `jq.exe` above (e.g. `$HOME/.local/bin/nats.exe`).
- **MSYS path-mangling can silently break single-token container-internal paths.** Git
  Bash's MSYS layer auto-converts any argument that _looks like_ a bare absolute POSIX
  path (e.g. `/out`) into a Windows path before handing it to `docker.exe` — even when
  that argument is meant to be interpreted _inside the Linux container_, not on the
  Windows host. This silently breaks `--out /out`-style arguments passed to
  `docker compose run ...`: the containerized tool receives a nonsense path, its
  `ofstream`/file writes fail with no visible error, and the run looks like it succeeded
  (correct stdout summary) while `result.json`/`oneway.csv` never get written. This does
  **not** happen on a real Linux host (no MSYS layer there) and is not a bug in the
  scripts — it's purely a Git-Bash-on-Windows testing artifact. Work around it locally by
  exporting `MSYS2_ARG_CONV_EXCL="/out"` before invoking any script that talks to
  `docker/latency-tool` (`bench-latency-oneway.sh`, `bench-crosshost.sh`) — this excludes
  just that one token from conversion while leaving normal host-path arguments (e.g.
  `docker cp`'s destination) converted correctly. Don't set the blanket
  `MSYS_NO_PATHCONV=1` instead — that disables conversion for _all_ arguments in the
  command, which then breaks those normal host-path arguments the opposite way.
