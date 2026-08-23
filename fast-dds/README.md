# Fast DDS パフォーマンス検証

Docker を使用して **Fast DDS**（eProsima、DDS/RTPS 実装）のベンチマークを行うための環境と
ツール。`nats/` と同じ 3 領域（スループット・レイテンシ・スケーラビリティ）を、同じ
結果フォーマット（`results/<category>/<timestamp>_<label>/result.json` と
`results/run-index.csv`）で測定する。スクリプトはネイティブの Bash（`scripts/*.sh`）で
記述されており、実機 Linux 上で直接実行することを想定している。

## NATS との構造的な違い（最初に読むこと）

同じ「メッセージングミドルウェアの性能測定」でも、Fast DDS は NATS Core とアーキテクチャが
根本的に異なる。この差を理解しないと数値の意味を読み違えるので、先に整理する。

| | NATS Core | Fast DDS |
| --- | --- | --- |
| サーバー | ブローカー必須（コンテナ内の `nats` サービス） | **デーモンレス** — サーバープロセスは存在しない |
| データ経路 | pub → ブローカー → sub | **pub → sub のピアツーピア**（中継なし） |
| 宛先の指定 | サブジェクト（`A.B.*` のワイルドカード購読が可能） | **トピック**（ワイルドカード購読は無い） |
| 相手の発見 | ブローカーのアドレスを指定して接続 | **Discovery**（既定は UDP マルチキャストによる自動探索） |
| 配信保証 | at-most-once（TCP 上、実質ロスなし） | **QoS で選択**（BEST_EFFORT / RELIABLE） |
| トランスポート | TCP | UDPv4 / 共有メモリ(SHM) / TCP |
| 計測クライアント | 公式 `nats bench` CLI ＋ 自作 C++ ツール | **自作 C++ ツールのみ**（公式ベンチ CLI が無い） |

この差がスクリプト構成にそのまま出ている:

- **`start-server.sh` / `stop-server.sh` が無い。** 代わりに任意の
  `start-discovery-server.sh` / `stop-discovery-server.sh` がある（後述）。
- **`install-*-cli.sh` が無い。** ホスト側にインストールするものは何もなく、すべて
  `dds-bench` コンテナ内で完結する。
- **`bench-scalability.sh` が掃引する軸が違う。** NATS は「接続数」、Fast DDS は
  「**Participant 数**」— ブローカーが無いので接続という概念自体が無く、代わりに各
  Participant が独立した RTPS ピアとして相互に Discovery し合う。詳細はスクリプト冒頭の
  コメント参照。
- **`--multisubject` に相当するものが `--topic-count`。** DDS にはサブジェクトの
  ワイルドカードが無いため、「多数のトピックにそれぞれ Reader を張る」形になる。

## Scope

- **Fast DDS 2.14 系**に固定。Fast DDS 3.x は CMake パッケージ名（`fastrtps` → `fastdds`）と
  `TopicDataType` の仮想インターフェースが変わり、`tools/dds_bench/main.cpp` の手書き型実装が
  そのままではビルドできない（詳細は `CLAUDE.md`）。
- Security（DDS-Security）は無効。CentOS 7 の OpenSSL 1.0.2 と Fast DDS の要求（1.1.1+）が
  合わないため、`nats/` で TLS を切っているのと同じ判断。
- 重点領域は 3 つ：スループット、レイテンシ（パーセンタイル）、Participant 数／トピック数の
  スケーラビリティ。

## 既定の QoS — なぜ BEST_EFFORT + UDPv4 なのか

既定値は「Fast DDS を最も速く見せる設定」ではなく「**NATS Core と条件を揃えられる設定**」に
してある:

- `--reliability best_effort` — NATS Core の at-most-once 配信に対応する。
- `--durability volatile` — 購読開始前のデータは受け取らない。NATS Core と同じ。
- `--transport udp` — 共有メモリではなく実際のネットワークトランスポートを通す。

Fast DDS 本来の実力（RELIABLE 配信、共有メモリ）を測りたい場合は
`--reliability reliable` / `--transport shm` を渡す。既定シナリオ
（`scripts/scenarios.json`）にはその両方が最初から含まれている。

## msg_loss の読み方 — NATS とは意味が違う

**`msg_loss > 0` は BEST_EFFORT では異常ではない。** これは検査を緩めているのではなく、
セマンティクスがそもそも異なる:

- NATS Core は TCP 上で動くため、メッセージが欠けたら何かが壊れている（`nats/` では
  `msg_loss > 0` は常に失敗扱い）。
- Fast DDS の BEST_EFFORT は「Subscriber が追いつけない分は落とす」ことが仕様どおりの動作。
  無制限のスループット飽和テストでは、欠損が出るのが**期待される結果**である。

そのため本プロジェクトのスクリプトと `dds_bench` は、
**`--reliability reliable` のときだけ `msg_loss > 0` を失敗扱いにする**。
BEST_EFFORT では欠損数を記録して正常終了する（欠損数そのものが測定値なので、
`result.json` と `run-index.csv` には常に記録される）。

### RELIABLE + KEEP_LAST は「無損失」ではない

`--reliability reliable` を指定しても、既定の `--history keep_last --history-depth 100` の
ままでは欠損しうる。**RELIABLE が保証するのは「Writer がまだ保持しているサンプルの配送」で
あって、KEEP_LAST(N) は保持数を N 件に制限する**ため、Reader が N 件以上遅れると古いサンプルは
上書きされ、正当に破棄される。

実測（本環境、100000 件を無制限速度で送信）:

| 設定 | 結果 |
| --- | --- |
| `--reliability reliable`（既定の `keep_last` / depth 100） | **679 件欠損**（ただし後述の通り再現性なし） |
| `--reliability reliable --history keep_all` | 欠損 0 |
| `--reliability reliable`＋レート制限（1000/s、20000 件） | 欠損 0 |

**この欠損は毎回は起きない。** 同じコマンドを再実行すると欠損 0 になることもある
（実際に確認済み）。Reader の消費速度と Writer の保持数のレースなので、負荷やタイミングで
結果が変わる。**再現しないからといって安全ではない** — むしろ、たまにしか出ない欠損の方が
運用上は厄介なので、無損失を要求するなら設定で保証すること:
`--history keep_all` を付けるか、`--history-depth` を十分上げるか、
`--target-msgs-per-sec` で送信をペース制御する。

`dds_bench` はこの組み合わせで欠損したとき、原因と対処を明示するメッセージを出す。
既定シナリオの `reliable-baseline` は `keep_all` 指定済み。

## 実行環境について

このプロジェクトは実機 Linux 上でのネイティブ実行を前提としている。仮想化された開発環境で
計測した場合、ホストリソースの共有や余分なネットワーク経路の影響で、絶対値（秒間 X 件、
p99 Y ms 等）が本番環境とは異なりうる。相対比較（パラメータ変更による傾向確認）や開発中の
リグレッション検知には使えるが、容量計画・SLA 判断など絶対値が必要な用途では、本番相当の
実機 Linux 上で再計測してから確定させること。

Fast DDS 特有の注意として、**Docker のブリッジネットワーク越しの UDP マルチキャストは
環境によって届かない**（IGMP snooping、`br_netfilter`、ホストカーネル設定に依存）。
これは Fast DDS の問題ではなく Docker のネットワークの問題で、`smoke-test.sh` が実際に
検査して結果を報告する。届かない場合はコンテナをまたぐ測定に `--discovery server` を使う
（`bench-crosshost.sh` は最初からそれを既定にしている）。

## Prerequisites

- Docker + Docker Compose v2 (`docker compose ...`)、デーモンが起動していること
- `bash`, `jq`, `awk`（一般的な Linux 環境なら標準。なければ `apt`/`yum` 等でインストール）

Windows の Git Bash から開発時検証を行う場合は `jq` を別途導入する必要がある。また Git Bash の
MSYS レイヤーが `--out /out`（コンテナ*内部*のパス）を Windows パスに勝手に書き換えてしまう
問題があるが、`scripts/common.sh` が `MSYS2_ARG_CONV_EXCL="/out"` を設定して回避済み
（実機 Linux では MSYS レイヤー自体が存在しないので無害・無効）。

## Setup

```bash
# パイプライン全体をエンドツーエンドで検証（初回はイメージのビルドから始まる）
./scripts/smoke-test.sh
```

初回ビルドは CentOS 7 上で foonathan_memory → Fast CDR → Fast DDS → `dds_bench` を
ソースからコンパイルするため数分〜十数分かかる。2 回目以降は Docker のレイヤキャッシュが
効くので即座に始まる。

## ベンチマークの実行

```bash
# スループット — --size / --pub-count / --sub-count / --topic-count を変えて個別に実行
./scripts/bench-throughput.sh
./scripts/bench-throughput.sh --size 16384 --label large-msg
./scripts/bench-throughput.sh --pub-count 4 --sub-count 4 --label 4x4-participants
./scripts/bench-throughput.sh --target-msgs-per-sec 5000 --label sustained-5k   # レート制限あり、最大速度ではない
./scripts/bench-throughput.sh --topic-count 100 --label multi-topic

# レイテンシ（片道、publisher -> subscriber）— 本プロジェクトの主指標。
# --target-msgs-per-sec と --duration-sec はどちらも必須（既定 1000/s、10秒）
./scripts/bench-latency-oneway.sh
./scripts/bench-latency-oneway.sh --target-msgs-per-sec 5000 --duration-sec 30 --label rate5000

# レイテンシ（往復 RTT、エコー相手経由）— 外部のベンチマーク値と比較するための補助指標
./scripts/bench-latency.sh
./scripts/bench-latency.sh --target-msgs-per-sec 2000 --duration-sec 20 --label rtt-2000

# Participant 数／トピック数のスケーラビリティ測定
./scripts/bench-scalability.sh
./scripts/bench-scalability.sh --participant-counts 1,10,50
./scripts/bench-scalability.sh --topic-count 100
./scripts/bench-scalability.sh --discovery server --participant-counts 1,10,50,100
```

### QoS・トランスポートの切り替え（全 `bench-*.sh` 共通）

```bash
./scripts/bench-latency-oneway.sh --reliability reliable --label reliable-1000
./scripts/bench-latency-oneway.sh --transport shm --label shm-1000
./scripts/bench-throughput.sh --durability transient_local --history keep_all
./scripts/bench-throughput.sh --discovery server
./scripts/bench-throughput.sh --domain 7
```

| フラグ | 既定 | 選択肢 |
| --- | --- | --- |
| `--reliability` | `best_effort` | `best_effort` / `reliable` |
| `--durability` | `volatile` | `volatile` / `transient_local` |
| `--history` | `keep_last` | `keep_last` / `keep_all` |
| `--history-depth` | `100` | 任意の整数（`keep_last` のときのみ有効） |
| `--transport` | `udp` | `udp` / `shm` |
| `--discovery` | `simple` | `simple` / `server` |
| `--domain` | `0` | DDS ドメイン ID |
| `--intraprocess` | `off` | `off` / `on`（後述） |

`dds_bench` を直接叩く場合はさらに `--heartbeat-period-ms`（既定 100）がある。これは
**Fast DDS の既定値（3 秒）ではない**。RELIABLE の再送は Heartbeat 周期に律速されるため、
3 秒のままだと短時間のベンチマークでは再送待ちが測定値を支配する（実測: 1000 件を
2000 msgs/s で送った際、送信自体は 0.5 秒で終わっているのに ACK 待ちに 2.5 秒かかり、
publisher のスループットが 332 msgs/s と表示された）。eProsima 公式の性能テストも同様に
短縮している。素の既定動作を測りたい場合は `--heartbeat-period-ms 3000` を渡す。

なお `dds_bench` は ACK 待ち時間を送信ループとは**別に計測**しており、
`metrics.pub.msgs_per_sec` には含めず `metrics.pub.ack_wait_sec` として個別に記録する。

### コンテナをまたぐ測定

```bash
# publisherとsubscriberを別々のDockerコンテナ（別ネットワークネームスペース）で実行し、
# 「Linuxホスト A / ホスト B」を模擬する。
./scripts/bench-crosshost.sh
./scripts/bench-crosshost.sh --measure throughput --label throughput-crosshost
./scripts/bench-crosshost.sh --netem-delay-ms 20 --label with-20ms-delay
./scripts/bench-crosshost.sh --discovery simple --label multicast-check
```

Fast DDS はピアツーピアなので、この分割は NATS のときより意味が大きい。ブローカー型では
publisher と sub をどこで動かしてもトラフィックは client → broker → client のままだったが、
Fast DDS ではデータ経路そのものが変わる。

`--netem-delay-ms` は、実際のホスト間レイテンシを模擬するために人工的なネットワーク遅延
（`tc netem`）を注入しようとするオプション。同一 Docker ホスト上のコンテナ同士は通常ほぼゼロ
レイテンシの仮想ブリッジ経由で通信するため、これを使わないと本番のホスト間通信特性を
再現できない。値の目安：同一データセンターで約 1ms、同一リージョン内の別 AZ で 10〜30ms、
大陸間で 80〜150ms。ホストカーネルに `sch_netem` モジュールが無い環境（Docker Desktop for
Windows 等）では失敗するが、スクリプトはこれを検知して警告を出し、遅延なしで実行を継続する。

なお `--transport shm` はコンテナをまたぐ構成では使えない（コンテナごとに `/dev/shm` が
別なので、同じホスト上でも共有メモリは共有されない）。`bench-crosshost.sh` はこれを
明示的にエラーにする。

## Discovery Server（任意）

Fast DDS は既定ではデーモンレスに動く。`--discovery server` を指定したときだけ、
`fast-discovery-server` がユニキャストのランデブーポイントとして起動する:

```bash
./scripts/start-discovery-server.sh    # 明示的に起動（通常は不要 — 各スクリプトが自動起動する）
./scripts/bench-throughput.sh --discovery server
./scripts/stop-discovery-server.sh
```

**これはブローカーではない。** Discovery Server が仲介するのは「どのピアがどこにいるか」の
情報だけで、一度お互いを発見した後のサンプルデータは直接ピア間を流れ、このプロセスを
一切通らない。したがってレイテンシ・スループットの測定値には（実行開始時の Discovery 時間を
除いて）現れない。

用途は 2 つ:
1. マルチキャストが届かない環境（多くの Docker ブリッジ構成、多くの企業ネットワーク）での
   確実な相互発見。
2. NATS のブローカー型トポロジとの構造比較。

## 実機 Linux で実行する（推奨・本来の使い方）

```bash
ssh user@<linux-host>
cd messaging_middlewear/fast-dds
./scripts/smoke-test.sh
./scripts/run-all-benchmarks.sh
```

これにより `docker compose build`/`run` はすべてそのマシン上で実行される。結果の取得はすべて
`docker cp`（`scripts/common.sh` の `docker_run_and_copy_out`）経由で行われ、`-v` バインド
マウントは使わない — これにより、後で `docker` をリモートデーモンに向ける必要が生じても
スクリプトの変更なしに動作し続ける。

### リモート Docker デーモン(SSH)を使う

スクリプトを別のマシンから実行し続けつつ、`docker` CLI の接続先だけをリモートの Linux ホストに
向けたい場合も同様に動作する — 結果は常にバインドマウントではなく `docker cp` 経由で取得される
ため、スクリプト側の変更は不要（バインドマウントのパスは `docker` コマンドを実行した側ではなく
*Docker デーモン側*で解決されるため、デーモンがリモートになった瞬間に何も取得できず黙って
失敗する）:

```bash
docker context create linux-bench --docker "host=ssh://user@<linux-host>"
docker context use linux-bench
# これ以降は上記と全く同じ手順でスクリプトを実行すればよい — 他の変更は不要
```

### 一括実行

```bash
./scripts/run-all-benchmarks.sh
./scripts/run-all-benchmarks.sh --skip-smoke
./scripts/run-all-benchmarks.sh --stop-on-failure
```

`run-all-benchmarks.sh` が実行するシナリオの追加・変更・削除は `scripts/scenarios.json` を
編集するだけでよく、コード変更は不要。各エントリは `script`（上記 `bench-*.sh` のいずれか）、
`category`、`label`、およびそのスクリプトのフラグ名をケバブケース（先頭の `--` を除いたもの）に
した `params` オブジェクトを持つ（例: `"target-msgs-per-sec": 1000`）。

既定シナリオは前半 6 件が `nats/scripts/scenarios.json` と 1 対 1 に対応しており、
後半は NATS 側に対応物が無い項目（RELIABLE、共有メモリ、多トピック）をカバーしている。

## 結果の格納構造

各実行はそれぞれ独自のタイムスタンプ付きフォルダに書き込まれる — 既存の結果を上書きすることはない:

```
results/<category>/<yyyyMMdd-HHmmss>_<label>/
  oneway.csv / rtt.csv / throughput.csv   # 生のマシン可読データ
                                          #   oneway.csv     : Seq,LatencyMicros（メッセージ単位）
                                          #   rtt.csv        : Seq,RttMicros（メッセージ単位）
                                          #   throughput.csv : Second,MsgsReceived,BytesReceived
                                          #                    （秒ごとの受信バケット）
  meta.json                               # 実行パラメータ + ツール／Fast DDSのバージョン
  result.json                             # パース済みメトリクス（msgs/sec, MB/sec,
                                          #   p50/p90/p95/p99/p99.9, msg_loss）
results/run-index.csv                     # 全カテゴリ横断で1行/実行のサマリ
```

`run-index.csv` の列は `nats/results/run-index.csv` と**完全に同一**にしてある（疎な共通
スキーマ： throughput/scalability はレイテンシ列が空、逆も同様）。両プロジェクトの
`run-index.csv` をそのまま連結すれば、ミドルウェア間の直接比較表になる。

`throughput.csv` の秒ごとバケットは NATS 側には無い出力。スループットの数値が「安定した
レートだったのか、最初に一気に受けて後は落ちたのか」を区別するために必要で、BEST_EFFORT の
飽和テストではこの区別が本質的になる。

`result.json` は `dds_bench` 自身が書く（bash 側では再計算しない）。NATS 側は公式 CLI が CSV を
吐いて bash がパースする構成だったが、こちらは計測ツールが自前なのでメトリクスの算出箇所を
1 箇所に集約できる。bash スクリプトは `run-index.csv` 用のサマリ列を読み出すだけ。

なお、このプロジェクトにはまだ可視化・グラフ描画のレイヤーがない — 実際のベンチマーク結果が
プロットする価値のある量まで蓄積されてから、フォローアップフェーズとして対応する予定
（`TODO.md` #5）。

## `dds_bench` の直接実行

スクリプトを介さずツールを直接叩くこともできる:

```bash
docker compose run --rm dds-bench dds_bench \
  --measure latency --mode both --rate 1000 --duration-sec 10 --out /out
```

主なフラグ:

| フラグ | 意味 |
| --- | --- |
| `--measure throughput\|latency\|rtt` | 測定種別 |
| `--mode both\|pub\|sub` | 同一プロセス内 / publisher のみ / subscriber のみ（`rtt` では `pub`=計測側、`sub`=エコー側） |
| `--topic` / `--topic-count` | トピック名 / トピック数 |
| `--msgs` | 総送信数（`--measure throughput` 専用） |
| `--rate` / `--duration-sec` | 秒間件数 / 継続時間（`latency`・`rtt` では両方必須） |
| `--pub-count` / `--sub-count` | publisher / subscriber の Participant 数 |
| `--size` | 1 メッセージのペイロードバイト数（先頭 16 バイトが seq + タイムスタンプ） |
| `--out` | 出力ディレクトリ |

### `--intraprocess` について

Fast DDS は**同一プロセス内**の Endpoint 間ではトランスポートを完全にバイパスする
「intra-process delivery」が既定で有効になっている。`--mode both` でこれを有効にしたまま
測定すると、DDS の転送コストではなく単なる memcpy を計測してしまい、マイクロ秒未満の
「レイテンシ」が出てしまう。

そのため `dds_bench` は**既定でこれを無効化している**（`--intraprocess off`）。
intra-process 経路自体の性能を意図的に測りたい場合のみ `--intraprocess on` を指定する。

### `--measure latency` に `--msgs` が無い理由

`--rate`（秒間件数）と `--duration-sec`（継続時間）が必須で、総件数は
`round(rate × duration)` として内部算出される。`--msgs` は明示的にエラーになる。

「一気に N 件投げる」無制限バーストモードは意図的に存在しない。無制限に送ると、Subscriber が
処理しきれない分が受信キューに滞留し、**計測されるのは NATS/DDS の転送遅延ではなく
キューイング遅延**になる（NATS 側で実測確認済み: 1000 件のバーストでレイテンシが先頭 2.3ms →
末尾 5.3ms と単調増加した。詳細は `nats/TODO.md` #4）。この理屈はミドルウェアに依存しないので、
こちらのツールは最初からこの設計にしてある。

## 未実装・既知の制限

- **TCP トランスポート**は未実装（`--transport tcp` はエラーになる）。DDS over TCP は
  リスナーポートと initial peers の明示設定が必要で、UDP/SHM とは構成の質が異なる。
  `TODO.md` #3 参照。
- **`--sub-count` を上げた測定は同一プロセス内で N 個の Participant を作る**。実運用の
  「N 台の別ホスト」とは異なり、Discovery のコストは再現できてもホスト間のネットワーク
  コストは含まれない。後者は `bench-crosshost.sh` の役割。
