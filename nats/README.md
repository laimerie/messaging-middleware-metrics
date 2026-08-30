# NATS Core パフォーマンス検証

Docker を使用して **NATS Core** サーバー（JetStream なし、シングルノード、クラスタリングなし）の
ベンチマークを行うための環境とツール。公式の `nats bench` CLI に加え、カスタムの一方向レイテンシ測定
ツールを使用する。スクリプトはネイティブのBash（`scripts/*.sh`）で記述されており、実機Linux上で
直接実行することを想定している。

## Scope

- NATS **Core** のみ — `docker-compose.yml` では、意図的に `-js` を省略しています。後で JetStream
  のベンチマークが必要になった場合は、この設定を変更するのではなく、
  別のサービス／プロファイルとして追加してください。
- シングルノード — クラスタポート 6222 は公開されません。マルチノードの耐障害性テストは行われません。
- 重点領域は3つ：スループット、レイテンシ（パーセンタイル）、接続数／被験者数のスケーラビリティ。

## 構成 — NATSサーバーとクライアントの実行場所

NATSサーバー本体は常にDockerコンテナの中で動く（`docker-compose.yml`の`nats`サービス）。ベンチマークの
パブリッシャー／サブスクライバー（クライアント）がどこで動くかはスクリプトによって異なる:

|                                                                             | NATSサーバー                 | クライアント（pub/sub）                                   |
| --------------------------------------------------------------------------- | ---------------------------- | --------------------------------------------------------- |
| `bench-throughput.sh` / `bench-scalability.sh` / `bench-latency.sh`（往復） | コンテナ内（`nats`サービス） | ホストローカルのプロセス（`nats://localhost:4222`で接続） |
| `bench-latency-oneway.sh` / `bench-crosshost.sh`（一方向・クロスホスト）    | コンテナ内（`nats`サービス） | 別コンテナ内（`latency-tool`、`nats://nats:4222`で接続）  |
| `bench-oneway-2host-native.sh`（実機2ホスト・一方向）                     | pubホスト上のnativeプロセス | pubホスト上のnative pub / subホスト上のnative sub       |

前者はローカルにインストールした公式`nats` CLIをそのまま使うため、常に**NATSコンテナと同じマシン上**で
実行する必要がある（`scripts/common.sh`に`NATS_SERVER_URL=nats://localhost:4222`がハードコードされて
いるため、コンテナと別マシンから叩くと届かない）。後者は一方向レイテンシの精度要件（本番ランタイムに
合わせたC++製の専用ツールが必要 — 下記「レイテンシ計測」参照）や、クロスホストのネットワーク
ネームスペース分離の要件から、クライアント自体もコンテナ化している。

## 実行環境について

このプロジェクトは実機Linux上でのネイティブ実行を前提としている。仮想化された開発環境で計測した
場合、ホストリソースの共有や余分なネットワーク経路の影響で、絶対値（秒間X件、p99 Yms等）が本番
環境とは異なりうる。相対比較（パラメータ変更による傾向確認）や開発中のリグレッション検知には
使えるが、容量計画・SLA判断など絶対値が必要な用途では、本番相当の実機Linux上で再計測してから
確定させること。

## Prerequisites

- Docker + Docker Compose v2 (`docker compose ...`)、デーモンが起動していること
- `bash`, `jq`, `awk`, `curl`（一般的なLinux環境なら標準。なければ `apt`/`yum` 等でインストール）

## Setup

```bash
# 1. nats CLIをインストール（初回のみ）
./scripts/install-nats-cli.sh

# 2. NATS Coreサーバーを起動
./scripts/start-server.sh

# 3. パイプライン全体をエンドツーエンドで検証
./scripts/smoke-test.sh
```

## ベンチマークの実行

```bash
# スループット — --size / --pub-clients / --sub-clients / --subject を変えて個別に実行
./scripts/bench-throughput.sh
./scripts/bench-throughput.sh --size 16384 --label large-msg
./scripts/bench-throughput.sh --pub-clients 4 --sub-clients 4 --label 4x4-clients
./scripts/bench-throughput.sh --target-msgs-per-sec 5000 --label sustained-5k   # レート制限あり、最大速度ではない
./scripts/bench-throughput.sh --use-multi-subject --multi-subject-max 100 --label multisubject

# レイテンシ（往復、nats CLIのrequest/replyを使用）— 公式CLIのみでの簡易チェック
./scripts/bench-latency.sh
./scripts/bench-latency.sh --request-clients 10 --label 10-clients

# レイテンシ（一方向、publisher -> subscriber）— 正確な計測。
# 本番に合わせてC++（CentOS 7 / gcc 11）で実装し、クライアントランタイムのオーバーヘッドを排除している。
# --target-msgs-per-sec と --duration-sec はどちらも必須（デフォルト1000/s、10秒）
./scripts/bench-latency-oneway.sh
./scripts/bench-latency-oneway.sh --target-msgs-per-sec 5000 --duration-sec 30 --label rate5000

# 接続数／サブジェクト数のスケーラビリティ測定
./scripts/bench-scalability.sh
./scripts/bench-scalability.sh --connection-counts 1,10,50,100
./scripts/bench-scalability.sh --use-multi-subject --multi-subject-max 100
./scripts/bench-scalability.sh --target-msgs-per-sec 5000
```

```bash
# クロスホスト: publisherとsubscriberを別々のDockerコンテナ（別ネットワークネームスペース）で実行し、
# 同一プロセス／同一コンテナでの計測ではなく「Linuxホスト A / ホスト B」を模擬する。
# NATSサーバー自体はシングルノードのまま（クラスタリングではない）
./scripts/bench-crosshost.sh
./scripts/bench-crosshost.sh --tool nats-bench --label throughput-crosshost
./scripts/bench-crosshost.sh --netem-delay-ms 20 --label with-20ms-delay
```

### Dockerを使えない2台で実行する

`package-native.sh`は、`latency-tool`イメージ内でビルドした`latency_oneway`と、同じ版の
静的リンクされた`nats-server`をtarballにまとめます。パッケージを両ホストへコピーするため、
計測対象のホストではDockerやC++コンパイラは不要です。

```bash
# Dockerが使えるビルドマシンで一度だけ
./scripts/package-native.sh

# 2台へ転送して両方で展開・確認
tar -xzf dist/nats-bench-native.tar.gz
cd nats-bench-native
./preflight.sh

# subホストで必ず先に実行（pubホストのIPを指定して待機）
./scripts/bench-oneway-2host-native.sh --role sub \
  --server-url nats://<pub-host-ip>:4222 --target-msgs-per-sec 1000 --duration-sec 30

# pubホストで実行。ここでnats-serverを起動し、subの購読確認後にpublisherを起動する
./scripts/bench-oneway-2host-native.sh --role pub \
  --server-url nats://<pub-host-ip>:4222 --target-msgs-per-sec 1000 --duration-sec 30
```

For the two-host Core/Leaf fan-out matrix, use `bench-leaf-2host-native.sh`. Run the `sub`
role on the subscriber host first and the `pub` role on the publisher host second.

In `leaf` mode the Leaf tier and the sub-side server tier both run on the **subscriber**
host, so the only traffic crossing the wire is the Core→Leaf links:

```text
PUB host                     SUB host
publisher                    leaf-0 .. leaf-(L-1)             remote → PUB core leaf port
    │                            │
core-nats  === L TCP links ==----┘
                                 │
                             subserver-0 .. subserver-(S-1)   remote → leaf-(j mod L)
                                 │
                             subscriber-0 .. subscriber-(N-1) → subserver-(i mod S)
```

`--leaf-count L` and `--sub-server-count S` size the two tiers independently; with `S = 0`
the subscribers attach straight to the Leaf tier. Both tiers are assigned round-robin:
subserver `j` dials leaf `j mod L`, and subscriber `i` attaches to subserver `i mod S`.
Because only `L` links cross between the hosts instead of one per subscriber, the
publisher NIC no longer carries `N` copies of the stream — that saturation is what made
the earlier pub-side Leaf placement unusable at 100 subscribers, since a Leaf sitting on
the publisher host does not reduce the number of cross-host connections at all.

Since the Leaf tier now lives on the subscriber host, the `pub` role requires `--sub-host`
in `leaf` mode: it confirms readiness by counting subscriptions on the tier the
subscribers actually attached to, and cross-checks that the Core has accepted all `L` leaf
connections before it starts publishing. `direct` mode connects every subscriber straight
to the Core on the PUB host and needs no `--sub-host`.

The script stores one result per subscriber plus an aggregate, and records which server each
subscriber attached to in a single `subscribers.json` at the run root. The host-wide CPU monitor
records one sample per interval in `cpu-samples.jsonl` and writes `cpu-abort.json` if the limit is
exceeded, terminating only the processes started by the current run after the configured number of
consecutive samples over the limit. There is no derived `cpu.json`: `summarize-leaf-run.sh` reads
the samples directly because it reports `p90`/`p99`, and the sampling interval is recorded in
`meta.json` as `cpu_interval_sec`. The same interval
also records CPU usage for each started process in `process-cpu-samples.jsonl` and summarizes it in
`process-cpu.json`: the Core NATS and Publisher on the PUB host, and each Leaf NATS, each
sub-side NATS, and each Subscriber on the SUB host, are identified by `label` and `category`
(`nats` or `application`), so the per-tier CPU cost can be read off directly. `cpu_percent_host` is
normalized to the whole host capacity (the same 0--100 percent scale the summary reports for the
host), while `cpu_percent_single_core` is normalized to one CPU core.
The same measurement interval also records `system-samples.jsonl` and `io.json` for aggregate
`iowait`, `tcp-queue-samples.jsonl` for `ss` socket states and `Recv-Q`/`Send-Q`,
`netdev-samples.jsonl` for `/proc/net/dev` RX/TX counters and per-interval deltas, and `network.json`
for total deltas, peak bytes/s and packets/s, and peak drop/error deltas per interface.
`tcp-queue.json` summarizes the maximum `Recv-Q`/`Send-Q` and socket states from
`tcp-queue-samples.jsonl`. `nats-samples.jsonl` stores `/varz` and `/connz` snapshots —
each host samples only the servers it runs, so the PUB host records the Core and the SUB
host records every Leaf and sub-side server — while `nats-queue.json` summarizes maximum
pending bytes/messages and traffic counters per server. These snapshots deliberately omit
`?subs=1`: nothing downstream reads the subscription list, and on the SUB host it would
mean fetching one entry per subscriber per server per interval. Only the readiness gate
asks for `?subs=1`, and only until publishing starts. These files are diagnostic evidence; the benchmark result remains the
latency and delivery result in `result.json`.

```bash
# SUB host (start first; it runs the Leaf and sub-side tiers, then the subscribers)
./scripts/bench-leaf-2host-native.sh --role sub --mode leaf --pub-host <pub-host-ip> \
  --leaf-count 5 --sub-server-count 10 --subscriber-count 100 \
  --rate 1000 --duration-sec 30 --size 500 --clock realtime --label leaf5-sub10-100sub

# PUB host (start after the SUB command is waiting; --sub-host is required in leaf mode)
./scripts/bench-leaf-2host-native.sh --role pub --mode leaf \
  --pub-host <pub-host-ip> --sub-host <sub-host-ip> \
  --leaf-count 5 --sub-server-count 10 --subscriber-count 100 \
  --rate 1000 --duration-sec 30 --size 500 --clock realtime --label leaf5-sub10-100sub
```

Pass the same `--leaf-count`, `--sub-server-count`, and `--subscriber-count` to both roles —
they derive the port map and the readiness target from those numbers independently.
Use `--sub-server-count 0` to compare against a two-tier Core→Leaf→Subscriber run, and
`--mode direct --leaf-count 0` for the baseline. For convenience, `--mode leaf --leaf-count 0`
is treated identically as Direct mode, and `direct` forces `--sub-server-count 0`.
The default CPU limit is 80 percent,
sampled once per second for three consecutive samples; override it with `--cpu-limit`,
`--cpu-interval-sec`, and `--cpu-consecutive`. Each role checks the ports it will bind on
its own host before starting — the PUB host the Core ports, the SUB host the Leaf and
sub-side ports. If a previous run or another service is using one, stop it or pass the same
`--port-offset N` to both host commands. This adds `N` to every benchmark port and allows
separate runs to use different port ranges. Keep `--subject` unique for concurrent runs.

Port map, before `--port-offset` is added (`i` = leaf index, `j` = sub-side server index):

| Host | Server | Client | Monitor | Leafnodes |
| --- | --- | --- | --- | --- |
| PUB | `core` | 4222 | 8222 | 7422 (accepts the Leaf tier) |
| SUB | `leaf-i` | 5000+i | 8200+i | 7600+i (accepts the sub-side tier) |
| SUB | `subserver-j` | 5200+j | 8400+j | — (dials only) |

The PUB host must be reachable on 7422 from the SUB host, and the SUB host's monitor ports
must be reachable from the PUB host for the readiness gate.

### 1回の実行を1行にまとめる

Each role writes its own result directory, so one run with 100 subscribers spreads its
numbers over roughly 360 files. `summarize-leaf-run.sh` reads both halves and writes one
`summary.json` plus one row in `results/crosshost/leaf-summary.csv`:

```bash
# 両ホストが同じ results ツリー（共有NAS等）に書いている場合、ラベルでペアリングする
./scripts/summarize-leaf-run.sh --label leaf5-sub10-100sub

# ディレクトリを直接指定してもよい
./scripts/summarize-leaf-run.sh --pub-dir results/crosshost/…-pub --sub-dir results/crosshost/…-sub
```

The run directory name ends in `-pub` or `-sub`, so both hosts can share one results tree
without colliding when they start in the same second, and the two halves pair by name. The
summarizer refuses to pair directories whose `meta.json` describe different runs.

指標の取り方で2点、意図的な選択があります。

- **CPUは層ごとに2通りで集計する。** `per_server_single_core_percent` は層内の全プロセス×全
  インターバルのサンプルをプールした p50/p90/p99/max で、「その層のサーバー1台がどれだけ働いたか」。
  Leafが5台しかない状態で台数方向に p99 を取ると max と同じ値にしかならないため、時間方向を
  含めてプールしている。`tier_total_host_percent` は各インターバルで層内を合計してから分位点を
  取った値で、「その層全体がホストの何%を使ったか」。台数を変えて比較するときはこちらが効く。
- **レイテンシは既定では近似。** 各subscriberの分位点を集めて、その中央値（全体が遅いか）と
  最大値（1台だけ遅いか）を出す。厳密な全体分位点が必要なら `--pool-latency` を付けると
  `subscriber-*/latency.csv` を全件プールして計算する（rate × duration × subscriber 行を読む）。

`summary.json` は識別情報・有効性（実効レート、CPU打ち切り、サンプル数、NICのdrop/error有無）・
配信（欠損と欠損率）・レイテンシ・層別CPU・ホストCPU・NIC（回線速度に対する利用率）・
NATSの送信詰まり・TCPキュー・io wait を持つ。`--no-csv` でCSV追記を止められる。

`--clock realtime`がデフォルトです。片道レイテンシを正しく比較するには、両ホストの
`CLOCK_REALTIME`をPTP等で同期してください。時計同期を使わない同一ホスト相当の確認では
`--clock monotonic`を指定できますが、別ホストの片道値には使わないでください。pubホストの
TCP `4222`とmonitoring APIの`8222`（`--port-offset`を使う場合は、それぞれオフセット後のポート）を、
subホストとpub側スクリプトから到達可能にしてください。
pub側は`/varz`でserver起動を確認した後、`/connz?subs=1`に指定subjectの購読が現れるまで
publisherを起動しません。購読確認は既定120秒でタイムアウトし、その場合はpublisherを実行せず
エラー終了します。必要に応じて`--subscription-timeout-sec`と
`--subscription-poll-interval-sec`で待機時間と確認間隔を調整できます。複数の計測を同じserverで
同時実行する場合は、既存購読による誤readyを避けるため、各実行で異なる`--subject`を指定してください。

`--netem-delay-ms` は、実際のホスト間レイテンシを模擬するために人工的なネットワーク遅延
（`tc netem`）を注入しようとするオプション。同一Dockerホスト上のコンテナ同士は通常ほぼゼロ
レイテンシの仮想ブリッジ経由で通信するため、これを使わないと本番のホスト間通信特性を
再現できない。値の目安：同一データセンターで約1ms、同一リージョン内の別AZで10〜30ms、
大陸間で80〜150ms。ホストカーネルに `sch_netem` モジュールが無い環境では失敗することがあるが、
スクリプトはこれを検知して警告を出し、遅延なしで実行を継続する（実行全体を失敗させない）。

## 実機Linuxで実行する（推奨・本来の使い方）

```bash
ssh user@<linux-host>
cd messaging_middlewear/nats
./scripts/install-nats-cli.sh
./scripts/start-server.sh
./scripts/run-all-benchmarks.sh
```

これにより `docker compose build`/`run` はすべてそのマシン上で実行される。`docker/latency-tool/Dockerfile`
内の `yum install`/`gcc`/`cmake` 等のステップも実機のCPU上で走る。結果の取得はすべて `docker cp`
（`scripts/common.sh` の `docker_run_and_copy_out`）経由で行われ、`-v` バインドマウントは使わない —
これにより、後で `docker` をリモートデーモンに向ける必要が生じても（下記「リモートDockerデーモン
(SSH)を使う」参照）スクリプトの変更なしに動作し続ける。

### リモートDockerデーモン(SSH)を使う

スクリプトを別のマシンから実行し続けつつ、`docker` CLIの接続先だけをリモートのLinuxホストに
向けたい場合も同様に動作する — 結果は常にバインドマウントではなく `docker cp` 経由で取得される
ため、スクリプト側の変更は不要（バインドマウントのパスは `docker` コマンドを実行した側ではなく
*Dockerデーモン側*で解決されるため、デーモンがリモートになった瞬間に何も取得できず黙って
失敗する）:

```bash
docker context create linux-bench --docker "host=ssh://user@<linux-host>"
docker context use linux-bench
# これ以降は上記と全く同じ手順でスクリプトを実行すればよい — 他の変更は不要
```

```bash
# 全部まとめて実行（smoke-test + scripts/scenarios.json内の全シナリオ）
./scripts/run-all-benchmarks.sh
./scripts/run-all-benchmarks.sh --skip-smoke
./scripts/run-all-benchmarks.sh --stop-on-failure
```

`run-all-benchmarks.sh` が実行するシナリオの追加・変更・削除は `scripts/scenarios.json` を編集する
だけでよく、コード変更は不要。各エントリは `script`（上記 `bench-*.sh` のいずれか）、`category`、
`label`、およびそのスクリプトのフラグ名をケバブケース（先頭の `--` を除いたもの）にした `params`
オブジェクトを持つ（例: `"target-msgs-per-sec": 1000`）。

作業が終わったらサーバーを停止する:

```bash
./scripts/stop-server.sh
```

## 結果の格納構造

各実行はそれぞれ独自のタイムスタンプ付きフォルダに書き込まれる — 既存の結果を上書きすることはない:

```
results/<category>/<yyyyMMdd-HHmmss>_<label>/
  pub.csv / sub.csv / request.csv / oneway.csv   # 生のマシン可読なメッセージ単位データ
  meta.json                         # 実行パラメータ + クライアントツール／サーバーのバージョン — 再現性確保用
  result.json                       # パース済みメトリクス（msgs/sec, MB/sec, p50/p99レイテンシ, msg_loss）
results/run-index.csv                # 全カテゴリ横断で1行/実行のサマリ — スパースな共通スキーマ
                                      #（throughput/scalabilityはレイテンシ列が空、逆も同様）で
                                      # 実行間の比較を一目で行える
```

`result.json` と `run-index.csv` はすべての `bench-*.sh` スクリプトが `scripts/common.sh` の
`save_result` 経由で書き込む（一方向レイテンシツールはC++側で直接自分の `result.json` を書き込み、
bashラッパーは `run-index.csv` への行追加だけを行う）。

`run-index.csv` は全実行のフラットな横断サマリ表を提供するが、このプロジェクトにはまだ可視化・
グラフ描画のレイヤーがない — 実際のベンチマーク結果がプロットする価値のある量まで蓄積されてから、
フォローアップフェーズとして対応する予定。

## `nats bench` コマンドの構成（インストール済みCLIの時点での形）

`nats bench` はフラットな単一コマンドではなく、サブコマンドベースの構成:

- `nats bench pub <subject> ...` — publisher、独立プロセス
- `nats bench sub <subject> ...` — subscriber、独立プロセス（`pub`と同時実行）
- `nats bench service serve <subject> ...` / `nats bench service request <subject> ...` —
  request/reply、レイテンシ計測に使用
- `nats bench js ...` / `nats bench kv ...` — JetStream/KV（本プロジェクトの対象外）

フラグはCLIのリリース間で変わることがある — インストール／アップグレード後は `nats bench --help`、
`nats bench pub --help` 等を実行し、各スクリプトが渡しているフラグと突き合わせること。
