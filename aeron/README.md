# Aeron パフォーマンス検証

Docker を使用して **Aeron**（Real Logic / aeron-io、UDP unicast・multicast・共有メモリ IPC の
高性能メッセージング）のベンチマークを行うための環境とツール。`nats/`・`fast-dds/` と同じ
3 領域（スループット・レイテンシ・スケーラビリティ）を、同じ結果フォーマット
（`results/<category>/<timestamp>_<label>/result.json` と `results/run-index.csv`）で測定する。
スクリプトはネイティブの Bash（`scripts/*.sh`）で記述されており、実機 Linux 上で直接実行する
ことを想定している。

## NATS / Fast DDS との構造的な違い（最初に読むこと）

Aeron は「ブローカー型（NATS）」でも「デーモンレス（Fast DDS）」でもない **第 3 のかたち** で、
ここを理解しないと数値の意味を読み違える。

| | NATS Core | Fast DDS | **Aeron** |
| --- | --- | --- | --- |
| サーバープロセス | ブローカー必須（中央に 1 つ） | **無し**（デーモンレス） | **メディアドライバが「ホストごとに」1 つ** |
| データ経路 | pub → ブローカー → sub | pub → sub のピアツーピア | **ドライバ → ドライバ**（`ipc` では アプリ ↔ アプリ） |
| 相手の発見 | ブローカーのアドレスを指定 | Discovery（マルチキャスト等） | **無し。チャネル URI がそのままアドレス** |
| 宛先の指定 | サブジェクト | トピック | **チャネル URI + ストリーム ID** |
| Subscriber が遅いとき | ブローカーが溜め、やがて切断 | BEST_EFFORT なら欠落 | **publisher にバックプレッシャ。欠落させない** |
| アプリへの配送 | コールバック | コールバック | **アプリ側が poll する** |
| 計測クライアント | 公式 `nats bench` CLI ＋ 自作 C++ | 自作 C++ ツールのみ | **自作 C++ ツールのみ** |

この差がスクリプト構成にそのまま出ている:

- **`start-server.sh`／`start-discovery-server.sh` に相当するものが無い。** メディアドライバは
  共有サービスではなく、各ベンチコンテナの中で `docker/aeron-bench/entrypoint.sh` が起動する
  （理由は後述）。事前に立ち上げておくものは何も無い。
- **`--discovery` フラグが無い。** 発見の仕組み自体が存在しないので、代わりに
  コンテナをまたぐ測定では **IP アドレスを固定**する（`docker-compose.yml` の
  `aeron-bench-a`／`aeron-bench-b`）。
- **`--poll-idle` という他の 2 つに無いフラグがある。** Aeron はコールバックしてこないので、
  受信ループの待ち方が測定値そのものに含まれる。
- **`bench-scalability.sh` が掃引する軸がまた違う。** NATS は「接続数」、Fast DDS は
  「Participant 数」、Aeron は「**Subscriber クライアント数**」。

## メディアドライバとは（ブローカーではない）

Aeron のアプリケーションは、必ず同じホスト上の **メディアドライバ（`aeronmd`）** と組で動く。
ドライバが UDP ソケット・term バッファ・フロー制御の状態を持ち、アプリはそれと
**共有メモリ（メモリマップトファイル）** で会話する。

**これはブローカーではない。** ホスト間の中継はせず、各ホストがそれぞれ自分のドライバを持ち、
データは **ドライバ同士** が直接やり取りする。同時に、**デーモンレスでもない** — ドライバ無しに
Aeron は 1 バイトも動かない。

本プロジェクトでは **ドライバをベンチコンテナの中で起動する**。「コンテナ 1 つ ＝ ホスト 1 つ」と
見なすのが実態に最も近く、`bench-crosshost.sh` が「ドライバ 2 つ」の本物の構成になるため。

> 別コンテナのドライバを共有する案は**意図的に採用していない**。Aeron のファイルは mmap される
> ため、`AERON_DIR` を Docker ボリュームで共有した場合、それが単一の tmpfs として共有されて
> いなければ（ボリュームドライバ次第で、呼び出し側からは見えない）**両者は別のメモリを見て、
> 何も接続せず、エラーも出さずに 0 件を報告する**。

## 既定値 — なぜ UDP ＋ `--driver-idle noop` なのか

### `--transport udp`（`ipc` ではない）

`aeron:ipc` は Aeron の最速経路だが、**ネットワークの測定ではない**。本環境での実測:

| 経路 | p50（本環境・複数回の実測レンジ） |
| --- | --- |
| `aeron:ipc`（共有メモリ） | **2.4〜7.5 µs** |
| `aeron:udp`（ループバック、`--driver-idle noop`） | 21〜41 µs |
| `aeron:udp`（ループバック、Aeron 既定の `backoff`） | 245〜331 µs |

（Windows/Docker Desktop 上の値。絶対値としては使えない。実行ごとのばらつきも大きい
— `TODO.md` #1 参照）

`ipc` は publisher が term バッファに直接書き、subscriber が同じメモリを読む。ドライバの
sender／receiver スレッドもカーネルの UDP スタックも通らない。NATS Core に対応する機能が無い
ため、`fast-dds/` の `--transport shm` と同じくオプトインにしてある。

### `--driver-idle noop`（Aeron 既定の `backoff` ではない）

**本プロジェクトで最も影響の大きい設定。** Aeron 既定の `BackoffIdleStrategy` は、暇なドライバ
スレッドを**最大 1 ミリ秒 park させる**。park 中の sender にメッセージが届くと、その park が
明けるまで待たされる。上表の通り **p50 245〜331 µs → 21〜41 µs** となり、
複数回の実測で一貫して **8〜14 倍** の差が出た。

`noop`（ビジースピン）を既定にしたのは、Aeron 公式の公表値がこの設定であり、レイテンシを
気にする実配置が実際にこう設定するため。`fast-dds/` が Fast DDS 既定の 3 秒ハートビート周期を
100 ms に上書きしたのと同じ判断で、素の既定のままだと**測定値がトランスポートではなく
アイドル方針を語ってしまう**。

**ただしタダではない**: DEDICATED モードではドライバの 3 スレッドが常時 1 コアずつ占有する。
素の既定動作を測りたい場合・コアが少ない場合は `--driver-idle backoff` を渡す。
`scripts/scenarios.json` には両方が入っている（`steady-1000` と `stock-driver-defaults`）。

## msg_loss の読み方 — 3 プロジェクトで意味が違う

| プロジェクト | 欠落の扱い | 理由 |
| --- | --- | --- |
| `nats/` | **常に失敗** | TCP 上なので欠落＝何かが壊れている |
| `fast-dds/` | `--reliability reliable` のときだけ失敗 | BEST_EFFORT は「追いつけない分を落とす」のが仕様 |
| **`aeron/`** | **`--reliable no` 以外は失敗** | フロー制御が常時有効で受信側主導。**遅い subscriber は欠落を生まず、publisher へのバックプレッシャになる** |

つまり Aeron では「subscriber が遅かったから欠けた」という説明が**成立しない**。既定
（信頼配送・NAK による再送）で欠落が出たら、それは実際の異常（publisher 側の linger 不足、
term バッファの巻き戻り、再送されなかった実ドロップ）である。

## バックプレッシャの読み方 — スループット値の意味が変わる

Aeron の `offer()` は、subscriber が消費しきれていないと `BACK_PRESSURED` を返す。
本ツールはこれをリトライし、**回数と待ち時間を記録する**（`metrics.pub.back_pressure_events` /
`back_pressure_sec`、実行後に `report_back_pressure` が表示）。

これは飾りではなく、**スループット値の解釈そのもの**に関わる:

```
Fast DDS BEST_EFFORT の無制限テスト = publisher が出せた速度（残りは欠落）
Aeron の無制限テスト                = 最も遅い subscriber が処理できた速度（欠落は 0）
```

同じ「msgs/sec」という列に並ぶが、答えている問いが違う。バックプレッシャの回数を見ないと、
その数字が「Aeron の送信性能の上限」なのか「その subscriber の消費性能の上限」なのか
区別できない。

なお `--sub-work-us`（subscriber 側の疑似アプリ処理）を上げると、Fast DDS では `msg_loss` が
増えるところ、Aeron では **欠落 0 のままバックプレッシャと実効レート低下として現れる**。
既定シナリオの `slow-subscriber` はこれを見るためのもの。

## レイテンシを支配する 2 つのノブ

| フラグ | 対象 | 既定 | 選択肢 |
| --- | --- | --- | --- |
| `--driver-idle` | **メディアドライバ**のスレッドの待ち方 | `noop` | `noop` / `backoff` / `yielding` / `sleeping` |
| `--poll-idle` | **本ツールの受信ループ**の待ち方 | `busy` | `busy` / `yield` / `sleep` |

`--poll-idle` に他の 2 プロジェクトの対応物は無い。**Aeron はコールバックしてこない**ため、
受信ループをどう回すかが測定対象に含まれる。`--poll-idle sleep` で測った値と `busy` で測った
値は比較してはいけない（`result.json` に必ず記録される）。

**CPU に関する注意**: ビジースピンするスレッドは自分のものだけではない。
`--poll-idle busy` は subscriber 1 つにつき 1 コア、`--pacing auto`／`busy` は publisher 1 つに
つき 1 コア、`--driver-idle noop` はドライバの 3 スレッド分。コア数を超えると
**ドライバの送受信スレッドを飢えさせ**、ひどい場合はクライアントが「ドライバが応答しない」と
判断して**実行そのものが異常終了する**。`aeron_bench` はこれを検知して警告する。
Subscriber 数を掃引するときは `--poll-idle yield` を使うこと。

## 実行環境について

このプロジェクトは実機 Linux 上でのネイティブ実行を前提としている。仮想化された開発環境で
計測した場合、ホストリソースの共有や余分なネットワーク経路の影響で、絶対値（秒間 X 件、
p99 Y ms 等）が本番環境とは異なりうる。相対比較や開発中のリグレッション検知には使えるが、
容量計画・SLA 判断など絶対値が必要な用途では、本番相当の実機 Linux 上で再計測すること。

Aeron 特有の注意として、**Docker の既定の `/dev/shm` は 64MB しかなく、Aeron には全く足りない**。
Aeron は publication ごとに term バッファを 3 面マップする（既定で数十 MB 単位）ため、
1 つの publication すら作れない。しかも失敗はドライバ内部の不透明な mmap エラーとして出て、
`/dev/shm` の名前はどこにも出てこない。`docker-compose.yml` が全サービスに `shm_size: 1gb` を
設定して回避してあり、`smoke-test.sh` はこれを最初に検査する。

## Prerequisites

- Docker + Docker Compose v2 (`docker compose ...`)、デーモンが起動していること
- `bash`, `jq`, `awk`（一般的な Linux 環境なら標準。なければ `apt`/`yum` 等でインストール）

Windows の Git Bash から開発時検証を行う場合は `jq` を別途導入する必要がある。また Git Bash の
MSYS レイヤーが `--out /out` や `--aeron-dir /dev/shm/aeron`（どちらもコンテナ*内部*のパス）を
Windows パスに勝手に書き換えてしまう問題があるが、`scripts/common.sh` が
`MSYS2_ARG_CONV_EXCL="/out;/dev/shm"` を設定して回避済み（実機 Linux では無害・無効）。

## Setup

```bash
# パイプライン全体をエンドツーエンドで検証（初回はイメージのビルドから始まる）
./scripts/smoke-test.sh
```

初回ビルドは CentOS 7 上で Aeron（C クライアント・C++ ラッパー・C メディアドライバ）を
ソースからコンパイルするため数分かかる。2 回目以降は Docker のレイヤキャッシュが効く。

`smoke-test.sh` が検査するもの:

1. メディアドライバが起動し、`/dev/shm` が十分な大きさであること
2. 同一コンテナ内の UDP ループバックで pub/sub が通ること
3. 同一コンテナ内の `aeron:ipc`（共有メモリ）で pub/sub が通ること
4. **コンテナをまたいで**（メディアドライバ 2 つ）pub/sub が通ること

4 が失敗した場合は**ハードエラー**にしている。`fast-dds/` のマルチキャスト検査と違い、
Aeron には代替の発見手段が存在しないため、「別の方式を使ってください」と案内できない。
ほぼ確実にアドレスの問題（`172.29.0.0/24` の衝突等）なので、その旨を出力する。

## ベンチマークの実行

```bash
# スループット
./scripts/bench-throughput.sh
./scripts/bench-throughput.sh --size 16384 --label large-msg
./scripts/bench-throughput.sh --pub-count 4 --sub-count 4 --poll-idle yield --label 4x4-clients
./scripts/bench-throughput.sh --target-msgs-per-sec 5000 --label sustained-5k   # レート制限あり
./scripts/bench-throughput.sh --stream-count 50 --label multi-stream
./scripts/bench-throughput.sh --sub-work-us 20 --label slow-subscriber

# レイテンシ（片道、publisher -> subscriber）— 本プロジェクトの主指標
./scripts/bench-latency-oneway.sh
./scripts/bench-latency-oneway.sh --target-msgs-per-sec 5000 --duration-sec 30 --label rate5000
./scripts/bench-latency-oneway.sh --transport ipc --label ipc-1000
./scripts/bench-latency-oneway.sh --driver-idle backoff --poll-idle sleep --label stock-defaults

# レイテンシ（往復 RTT、エコー相手経由）— 外部のベンチマーク値と比較するための補助指標
./scripts/bench-latency.sh
./scripts/bench-latency.sh --target-msgs-per-sec 2000 --duration-sec 20 --label rtt-2000

# Subscriber 数／ストリーム数のスケーラビリティ測定
./scripts/bench-scalability.sh
./scripts/bench-scalability.sh --sub-counts 1,10,50 --poll-idle yield
./scripts/bench-scalability.sh --stream-count 100
```

### 共通フラグ（全 `bench-*.sh` 共通）

| フラグ | 既定 | 選択肢 |
| --- | --- | --- |
| `--transport` | `udp` | `udp` / `ipc` / `multicast` |
| `--reliable` | `yes` | `yes` / `no`（`no` は subscription 側で NAK を止める） |
| `--stream-id` | `1001` | 任意の整数 |
| `--term-length` | Aeron 既定 | `16m` など |
| `--mtu` | Aeron 既定(1408) | 任意（これを超えるメッセージは自動で分割・再構成される） |
| `--publication` | `exclusive` | `exclusive` / `concurrent` |
| `--poll-idle` | `busy` | `busy` / `yield` / `sleep` |
| `--poll-idle-sleep-us` | `50` | `--poll-idle sleep` のときのみ有効 |
| `--fragment-limit` | `10` | 1 回の `poll()` で取り出す最大フラグメント数 |
| `--pacing` | `auto` | `auto` / `sleep` / `busy` |
| `--sub-work-us` | `0` | subscriber 側の疑似アプリ処理時間 |
| `--driver-threading` | `DEDICATED` | `DEDICATED` / `SHARED_NETWORK` / `SHARED` |
| `--driver-idle` | `noop` | `noop` / `backoff` / `yielding` / `sleeping` |

### `--pacing` — 送信レートの刻み方

publisher が 1 件ごとの送信間隔をどう待つかを選ぶ。**指定したレートが実際に出るかどうかを
左右する**ため、高レート測定では結果の意味そのものに影響する。

| 値 | 動作 | CPU | 精度 |
| --- | --- | --- | --- |
| `sleep` | OS に「N µs 後に起こして」と頼んで眠る | ほぼ 0 | **低い** |
| `busy` | CPU を握ったまま時計を監視し続ける | **1 コア/publisherスレッド** | 非常に高い |
| `auto`（既定） | 残り 200µs までは眠り、そこから監視に切り替える | 間隔が広ければ小 | 高い |

既定を `sleep` にしていない理由は `fast-dds/` で実測済み: この種の環境では
`sleep_for(100µs)` が中央値 183µs かかり、**要求 10,000/s に対し実効 5,552/s** しか出ず、
「10,000/s の測定結果」と称して別の条件を測っていた。`aeron_bench` は要求レートの 90% を
下回った場合に警告を出す（`metrics.pub.msgs_per_sec` が実効レート）。

**Aeron 固有の追加要因**: 実効レートが出ない原因がペーシングではなく
**subscriber 由来のバックプレッシャ**であることがある。その場合の警告文はそう明示する
（ペーシングを変えても解決しない、という意味なので重要）。

## コンテナをまたぐ測定

```bash
./scripts/bench-crosshost.sh
./scripts/bench-crosshost.sh --measure throughput --label throughput-crosshost
./scripts/bench-crosshost.sh --netem-delay-ms 20 --label with-20ms-delay
```

publisher と subscriber を別々のコンテナで実行する。**`fast-dds/` の同名スクリプトより意味が
大きい**: Fast DDS ではデーモンレスなライブラリのクライアントを 2 つ動かしていたが、
ここでは **各コンテナが実サーバーと同じフルスタック**（conductor / sender / receiver /
term バッファ / フロー制御）を持ち、**ドライバ同士が UDP で通信する**。

ただし **NIC・ケーブル・スイッチは再現されない**。同一 Docker ホスト上のコンテナ同士は
veth ＋ Linux ブリッジ（カーネル内メモリコピー）で通信する。`fast-dds/` での実測では
コンテナ境界を越えてもレイテンシは増えなかった（同一プロセス 70µs / 別コンテナ 68µs）。

`--netem-delay-ms` は人工的なネットワーク遅延（`tc netem`）を注入するオプション。値の目安：
同一データセンターで約 1ms、同一リージョン内の別 AZ で 10〜30ms、大陸間で 80〜150ms。
ホストカーネルに `sch_netem` が無い環境（Docker Desktop for Windows 等）では失敗するが、
スクリプトは警告を出して遅延なしで継続する。

**`--transport ipc` はコンテナをまたぐ構成では使えない**（各コンテナが別のドライバ・別の
`/dev/shm` を持つため）。スクリプトは明示的にエラーにする。

**アドレスについて**: Aeron には発見の仕組みが無いので、`docker-compose.yml` の
`aeron-bench-a`（subscriber、172.29.0.20）と `aeron-bench-b`（publisher、172.29.0.21）に
静的 IP を割り当ててある。サブネットを変更する場合は `scripts/common.sh` の
`CROSS_A_ADDRESS`／`CROSS_B_ADDRESS` も合わせて変更すること。

## 実サーバー2台での測定

### まず、どちらの問いに答えたいのかを分ける

同一ホストで測るか 2 台で測るかは、**目的によって答えが変わる**。

| 問い | 適した測定 | 理由 |
| --- | --- | --- |
| **① どのミドルウェアが速いか** | **同一ホスト**（`bench-latency-oneway.sh`） | 同条件で測れ、ネットワークという交絡要因が消える。同一カーネルの時計を共有するので**片道を直接測れる**。時計同期も不要 |
| **② 実配置で p99 要件を満たすか** | 実サーバー2台 | 同一ホスト測定には NIC・スイッチ・ケーブルのコストが**一切含まれない** |

**①には 2 台構成も PTP も不要。** ②も、丸ごとミドルウェアで測る必要はなく
「同一ホストのミドルウェアコスト ＋ ネットワーク単独のコスト」に分解できる。後者は
`sockperf` や `netperf -t UDP_RR`、簡易には `ping` で単独に測れ、これが**下限**を与える。
**この測定を先に行うこと** — 数分で終わり、しかも決定的。

### 片道レイテンシは時計同期なしでは測れない

`bench-latency-oneway.sh` は送信時刻をメッセージに埋め込んで受信時刻との差を取る。これが
成立するのは**同一ホスト上のコンテナが同じカーネルの単調時計を共有している**から。

**実サーバー 2 台では、それぞれの `steady_clock` は無関係な起点を持つ別の時計。** 差分に意味は
無く、しかもエラーにならず**それらしい値や負の値が出る**（`fast-dds/` で実際に負の値が観測
されている）。

真の片道測定には PTP（IEEE 1588）が必要で、しかも **PTP が規律するのは `CLOCK_REALTIME` で
あって `CLOCK_MONOTONIC` ではない**。そのため `aeron_bench` には `--clock` があり、
`bench-oneway-2host.sh`（後述）がこれを使う。

### `bench-rtt-2host.sh` — 時計同期なしで測れる往復レイテンシ

RTT なら ping 側が**自分の時計だけ**で送信・受信を計測するため、同期不要。

```bash
# サーバーB（エコー役）を先に起動
./scripts/bench-rtt-2host.sh --role echo \
  --self-address 10.0.0.2 --peer-address 10.0.0.1 \
  --target-msgs-per-sec 10000 --duration-sec 30

# サーバーA（計測役）
./scripts/bench-rtt-2host.sh --role ping \
  --self-address 10.0.0.1 --peer-address 10.0.0.2 \
  --target-msgs-per-sec 10000 --duration-sec 30 --label prod-profile
```

- **`--self-address` と `--peer-address` は両側で必須。** Aeron は相手を探さないので、
  自分が bind するアドレスと相手に送るアドレスを両方明示する必要がある。
- **リクエスト用とレスポンス用でポートを分ける必要がある**（既定 40456 / 40457）。
  Aeron の subscription はエンドポイントを bind するため、同じポートを使うと ping 側が
  自分の送信を受信してしまう。スクリプトは同一ポートを明示的にエラーにする。
- **両側に同じ `--target-msgs-per-sec` と `--duration-sec` を渡すこと。** 各側が独立に
  総件数（`round(rate × duration)`）を算出し、エコー側はそれで終了判定を行う。
- **`network_mode: host` が必須**（`docker-compose.yml` の `aeron-bench-host`）。ブリッジ接続の
  コンテナは、相手に知らせるべきホストのアドレスを bind できない。

**RTT の解釈に関する注意**: RTT にはエコー側の「受信して打ち返す」処理コストが含まれる。
したがって **RTT ÷ 2 は片道レイテンシを過大に見積もる。** 上限の把握や相対比較には使えるが、
片道の実数値として報告しないこと。

### `bench-oneway-2host.sh` — PTP 同期環境での真の片道レイテンシ

**Docker を使わずネイティブに実行する。** 対象の 2 台が Docker を使えないケースを想定した
唯一の経路で、`scripts/package-native.sh` が作る tarball のバイナリを使う（後述）。

```bash
# サーバーB（受信側 = 計測結果が出る側）を先に起動
./scripts/bench-oneway-2host.sh --role sub \
  --self-address 10.0.0.2 --peer-address 10.0.0.1 \
  --target-msgs-per-sec 10000 --duration-sec 30 --label prod-profile

# サーバーA（送信側）
./scripts/bench-oneway-2host.sh --role pub \
  --self-address 10.0.0.1 --peer-address 10.0.0.2 \
  --target-msgs-per-sec 10000 --duration-sec 30
```

- **計測結果は `--role sub` 側に出る。** `bench-rtt-2host.sh` が ping 側（＝pub）で計測するのと
  逆で、これは片道レイテンシの定義そのものから来る — publisher が時刻を刻み、**subscriber が
  受信時に引き算する**ので、両方の値を持っているのは subscriber だけ。pub 側にも
  `result.json` は出るが送信側カウンタしか入っていない。
- **既定で `--clock realtime`。** PTP が規律するのは `CLOCK_REALTIME` なので、この経路だけは
  既定を変えてある。`--clock monotonic` も渡せるが、2 台構成では**壊れた測定を意図的に
  再現する**ためのものでしかない。
- 両側に同じ `--target-msgs-per-sec` と `--duration-sec` を渡すこと。ポートは 1 つでよい
  （応答チャネルが無いため。RTT 版は 2 つ必要だった）。
- **`--force-clean`**: `AERON_DIR` に前回の残骸がある場合のみ使う。既定では**削除せずエラーに
  する** — 実機では他のドライバが生きている可能性があり、mmap 中のファイルを消すと無言で壊れる。

#### PTP の精度がそのまま誤差棒になる

**片道が数十 µs のオーダーなので、同期精度が測定の意味を決める。**

- スクリプトは実行前に `ethtool -T` で**ハードウェアタイムスタンプ**の有無を確認し、無ければ
  警告する。ソフトウェアタイムスタンプだけの PTP は誤差が数十 µs あり、**測ろうとしている量と
  同じ桁**になる。その場合は `bench-rtt-2host.sh`（同期不要）に戻る判断が正しい。
- `pmc` があれば `master_offset` を**実行前後**に取得して `meta.json` の `ptp` に記録する。
  実行中に動いた場合、それ自体が分布がおかしい説明になる。
- **両側のオフセットを合わせて見ること。** 誤差棒は片方ではなく**2 台の和**で押さえられる。
  pub 側スクリプトは自分のオフセットを表示して、その旨を注意する。
- **負のレイテンシが 1 件でも出たら同期が壊れている。** ツールが件数と最悪値を出して、
  どちらの時計が原因かまで明示する。これが無いと、**それらしい p50 が出て気づけない**
  （`fast-dds/` で実際に負値が観測された失敗）。

#### 検算

片道を A→B と B→A の両方向で測り、`bench-rtt-2host.sh` の RTT と突き合わせる。同期が効いて
いれば両方向はほぼ対称になり、**非対称分がそのまま時計オフセット誤差の読み取り値**になる。
数分で終わる決定的なチェックなので必ず行うこと。

## Docker が使えないサーバーへの配布

`package-native.sh` が、コンテナでビルドしたバイナリを自己完結した tarball にまとめる。

```bash
./scripts/package-native.sh            # -> dist/aeron-bench-native-<version>.tar.gz （約 1MB）

# 両サーバーで
tar -xzf aeron-bench-native-1.52.2.tar.gz
cd aeron-bench-native-1.52.2
./preflight.sh                          # arch / glibc / ライブラリ解決 / PTP を検査
```

**ターゲット上でビルドしない**のは意図的で、理由は 2 つある。gcc 11 と CMake 3.31 を入れられ
ない可能性が高いことに加えて、より重要なのは、**別のツールチェーンでビルドした時点で
`nats/`・`fast-dds/` との比較可能性が壊れる**こと（3 プロジェクトの数値は全て
CentOS 7 / gcc 11 / C++17 のクライアントランタイムで測られている）。

移植性は推測ではなく実測で確認してある:

| 項目 | 状況 |
| --- | --- |
| glibc | CentOS 7 の 2.17 でビルド。**glibc は後方互換**なので、より新しいホストで動く。有名な `GLIBC_2.34 not found` は逆方向（新しい環境でビルド→古い環境で実行）の失敗 |
| libstdc++ | `-static-libstdc++ -static-libgcc` で畳み込み済み。**GLIBCXX の要求が 0 個**になり、この問題自体が消える。`libaeron`/`libaeron_driver` は純 C で C++ ABI が `.so` 境界をまたがないため、静的リンクの副作用も無い |
| Aeron のライブラリ | `lib/` に同梱し、RPATH `$ORIGIN/../lib` で解決。`LD_LIBRARY_PATH` は不要 |
| 検証 | **Ubuntu 22.04（glibc 2.35）のクリーンな環境**に展開して、2 コンテナ間で `bench-oneway-2host.sh` の pub/sub を実際に通し、欠落 0 で完走することを確認済み |

前提は **x86_64 / glibc 2.17 以上 / `jq` / `awk`** のみ。`preflight.sh` がこれを全部その場で
検査する。tarball は単一ファイル約 1MB なので、`scp` が使えない環境でも運べる
（`.sha256` を添えてある）。

### ネイティブ実行で自分でやる必要があること

コンテナが黙ってやってくれていたことが 3 つある。`scripts/common-native.sh` が引き受けるが、
**何が起きているかは知っておくこと**:

1. **ドライバの停止。** `docker compose run` の終了が後始末をしていた。ネイティブでは
   Ctrl-C やスクリプト異常終了で `aeronmd` が残り、既定の `--driver-idle noop` なので
   **3 コアを 100% で回し続ける**。スクリプトは `trap` で確実に止める。万一残ったら
   `pkill -x aeronmd`。
2. **`AERON_DIR` の初期化。** コンテナは毎回まっさらなので `AERON_DIR_DELETE_ON_START` を
   無条件に設定できた。実機ではその前提が成り立たないため、**残骸があればエラーで止める**
   （`--force-clean` で明示的に上書き）。
3. **結果の取り出し。** `docker cp` が無いので、ツールが実行ディレクトリに直接書く。

なお **Docker が使えないのは測定の質としてはむしろ好都合**である。cgroup の CPU quota による
スロットリング、既定 capability に `CAP_SYS_NICE` が無いこと、seccomp のフィルタ、
`network_mode: host` では compose から `net.*` sysctl を設定できないこと — これらの
コンテナ由来の懸念が全て消える。

## 一括実行

```bash
./scripts/run-all-benchmarks.sh
./scripts/run-all-benchmarks.sh --skip-smoke
./scripts/run-all-benchmarks.sh --stop-on-failure
```

シナリオの追加・変更・削除は `scripts/scenarios.json` を編集するだけでよく、コード変更は不要。
各エントリは `script`（`bench-*.sh` のいずれか）、`category`、`label`、およびそのスクリプトの
フラグ名をケバブケース（先頭の `--` を除いたもの）にした `params` オブジェクトを持つ。

既定シナリオは前半 6 件が `nats/` および `fast-dds/` の `scenarios.json` と 1 対 1 に対応する。
後半は Aeron 固有の項目で、**意図的に両方向に振ってある**:

- `ipc-1000` — NATS Core にできないこと（共有メモリ、約 2µs）
- `stock-driver-defaults` — 本プロジェクトが既定で入れている低レイテンシ設定を**外した**状態。
  他の全行はビジースピンするドライバで測っているので、これが無いと Aeron に有利な数字だけが
  並ぶことになる
- `slow-subscriber` — Fast DDS なら `msg_loss` として出るものが、Aeron ではバックプレッシャと
  して出ることを見るためのもの

## 実機 Linux で実行する（推奨・本来の使い方）

```bash
ssh user@<linux-host>
cd messaging_middlewear/aeron
./scripts/smoke-test.sh
./scripts/run-all-benchmarks.sh
```

### リモート Docker デーモン(SSH)を使う

スクリプトを別のマシンから実行しつつ、`docker` CLI の接続先だけをリモートの Linux ホストに
向けたい場合も動作する — 結果は常にバインドマウントではなく `docker cp` 経由で取得されるため、
スクリプト側の変更は不要:

```bash
docker context create linux-bench --docker "host=ssh://user@<linux-host>"
docker context use linux-bench
```

## 結果の格納構造

各実行はそれぞれ独自のタイムスタンプ付きフォルダに書き込まれる — 既存の結果を上書きしない:

```
results/<category>/<yyyyMMdd-HHmmss>_<label>/
  oneway.csv / rtt.csv / throughput.csv   # 生のマシン可読データ
                                          #   oneway.csv     : Seq,LatencyMicros
                                          #   rtt.csv        : Seq,RttMicros
                                          #   throughput.csv : Second,MsgsReceived,BytesReceived
  meta.json                               # 実行パラメータ + ツール／Aeron／ドライバ設定
  result.json                             # パース済みメトリクス
results/run-index.csv                     # 全カテゴリ横断で1行/実行のサマリ
```

`run-index.csv` の列は `nats/` および `fast-dds/` と**完全に同一**にしてある（疎な共通スキーマ）。
3 つの `run-index.csv` をそのまま連結すれば、ミドルウェア間の直接比較表になる。

`result.json` の `metrics.pub` には Aeron 固有の項目が入る:

| キー | 意味 |
| --- | --- |
| `back_pressure_events` | `offer()` が `BACK_PRESSURED` を返した回数 |
| `back_pressure_sec` | そのリトライに費やした合計時間 |
| `not_connected_events` | subscriber がまだ居らず送れなかった回数 |
| `linger_sec` | publisher 単独モードで送信後に待った時間 |

`environment` には `driver_threading_mode`・`driver_idle_strategy`・`clock` が記録される。
**`driver_idle_strategy` を見ずに result.json のレイテンシを読んではいけない**（8〜14 倍変わる）。
`clock` が `realtime` の行は 2 台構成の片道測定であり、**`meta.json` の `ptp` と必ずセットで
読むこと** — PTP の残留オフセットがその数値の誤差棒そのもの。

ネイティブ実行（`bench-oneway-2host.sh`）の `meta.json` はコンテナ実行と別の内容を持つ:
`image` は `"none (native binaries)"`、`server` は `"aeronmd native (no container)"`、
加えて `host`（カーネルとホスト名）と `ptp`（実行前後の `master_offset`）が入る。

## `aeron_bench` の直接実行

```bash
docker compose run --rm aeron-bench aeron_bench \
  --measure latency --mode both --rate 1000 --duration-sec 10 --out /out
```

主なフラグ:

| フラグ | 意味 |
| --- | --- |
| `--measure throughput\|latency\|rtt` | 測定種別 |
| `--mode both\|pub\|sub` | 同一プロセス内 / publisher のみ / subscriber のみ（`rtt` では `pub`=計測側、`sub`=エコー側） |
| `--channel` | チャネル URI を丸ごと指定（`--transport`/`--endpoint` 等を上書き。MDC 等の高度な指定用） |
| `--endpoint` / `--response-endpoint` | `host:port`。後者は `--measure rtt` 専用 |
| `--stream-id` / `--stream-count` | ストリーム ID / ストリーム数 |
| `--msgs` | 総送信数（`--measure throughput` 専用） |
| `--rate` / `--duration-sec` | 秒間件数 / 継続時間（`latency`・`rtt` では両方必須） |
| `--pub-count` / `--sub-count` | publisher / subscriber の Aeron クライアント数 |
| `--size` | 1 メッセージのペイロードバイト数（先頭 16 バイトが seq + タイムスタンプ） |
| `--linger-sec` | publisher 単独モードで送信後に待つ時間（既定 2 秒、後述） |
| `--clock monotonic\|realtime` | メッセージに埋め込む時刻の時計（既定 `monotonic`、下記） |
| `--aeron-dir` | メディアドライバのディレクトリ（既定は `$AERON_DIR`） |
| `--out` | 出力ディレクトリ |

### `--clock` — 2 つの時計は交換可能ではない

**ペーシング・タイムアウト・`--linger-sec`・実行時間の計測は常に `CLOCK_MONOTONIC` で、
`--clock` はこれを一切変えない。** 変えるのは**メッセージの中に入って相手プロセスに引き算
される時刻**だけ。単調時計を丸ごと差し替えるのは誤った直し方で、区間計測に「NTP/PTP が
巻き戻し得る時計」を渡すことになる。

| 値 | 正しく使える条件 |
| --- | --- |
| `monotonic`（既定） | 送受信が**同じカーネルを共有**しているとき。`--mode both`、および同一 Docker ホスト上の 2 コンテナ |
| `realtime` | 実サーバー 2 台で、**PTP/NTP により `CLOCK_REALTIME` が同期している**とき |

`--clock realtime` は **`--measure latency` 以外では明示的にエラーになる。**

- `--measure throughput` — 片道レイテンシを計算しないので効果が無い
- `--measure rtt` — **これは制限ではなく正しさの規則。** ping 側は自分の時計だけで刻んで
  引き算するので RTT はそもそも同期不要であり、規律された時計を使うと「実行中に PTP が
  step すると跨いだサンプルが壊れる」という失敗要因が増えるだけになる

`result.json` の `environment.clock` に必ず記録される。

### `--measure latency` に `--msgs` が無い理由

`--rate`（秒間件数）と `--duration-sec`（継続時間）が必須で、総件数は
`round(rate × duration)` として内部算出される。`--msgs` は明示的にエラーになる。

「一気に N 件投げる」無制限バーストモードは意図的に存在しない。無制限に送ると、計測される
のは転送遅延ではなく**キューイング遅延**になる（NATS 側で実測確認済み: 1000 件のバーストで
レイテンシが先頭 2.3ms → 末尾 5.3ms と単調増加。詳細は `nats/TODO.md` #4）。

### `--linger-sec` が必要な理由

`offer()` の成功は「term バッファに書けた」であって「ワイヤに出た」ではない。publisher のみの
プロセス（`bench-crosshost.sh` の pub 側）がすぐ終了すると、`entrypoint.sh` がメディアドライバを
停止し、**まだ送信されていない分が消える**。それは subscriber 側で「Aeron とは無関係な
メッセージ欠落」として現れる。既定 2 秒。

## 未実装・既知の制限

- **マルチキャスト（`--transport multicast`）は実装済みだが未検証。** `--multicast-interface`
  の指定が必須（Aeron はどの NIC で join するかを推測しない）。Docker ブリッジ越しの
  マルチキャストは環境依存で届かないことがある（`fast-dds/` と同じ制約）。
- **MDC（multi-destination-cast）・セッション ID 固定などの高度なチャネル指定**は
  `--channel` で URI を直接渡す形でのみ対応。
- **`tryClaim` によるゼロコピー送信は未使用。** 現状は `offer()`（送信元バッファからのコピー）。
  Aeron 公式ベンチマークは小サイズで `tryClaim` を使うため、レイテンシの最後の一段は
  まだ取れていない（`TODO.md` #3）。
- **ドライバのカウンタ（実際のロス数・NAK 数）は読んでいない。** Aeron は CnC ファイル経由で
  これらを公開しており、`--reliable no` のときの「どこで落ちたか」の切り分けに使える
  （`TODO.md` #4）。
- **Aeron Archive（録画・再生）は対象外。** Java コンポーネントであり、本プロジェクトが
  測定対象にしているトランスポートとは別の関心事。`BUILD_AERON_ARCHIVE_API=OFF` でビルド
  時にも除外している（JDK / Gradle 依存を持ち込まないため）。
- **`--sub-count` を上げた測定は同一プロセス内で N 個の Aeron クライアントを作る**。
  実運用の「N 台の別ホスト」とは異なるが、**Aeron の場合これは欠点ばかりではない** —
  同一ホストの N 個の subscriber が 1 つのドライバとデータのコピーを共有するのは実配置でも
  同じ構造だからである（`CLAUDE.md` の該当項参照）。
