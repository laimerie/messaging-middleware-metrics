# TODO — Aeron検証環境のバックログ

準備フェーズ（`aeron_bench` C++ツール、Dockerイメージ、全ベンチスクリプト、シナリオ定義）は
実装完了。`nats/`・`fast-dds/`の完成済み構成を出発点に、Aeron固有の差分（メディアドライバ、
発見機構の不在、常時有効なフロー制御、poll型の受信）を織り込んで構築した。

**動作検証の状況（Windows + Docker Desktop 上、Git Bash から実行）**: `smoke-test.sh`
（ドライバ起動／`/dev/shm`検査／UDPループバック／`aeron:ipc`／コンテナ間の4段）、
`bench-throughput.sh`・`bench-latency-oneway.sh`・`bench-latency.sh`(RTT)・
`bench-scalability.sh`・`bench-crosshost.sh`（latency/throughput両方）・
`run-all-benchmarks.sh`（`scenarios.json`の既定10シナリオ）を全て実行し、
**10/10シナリオが正常完了**することを確認済み。UDP/IPC、信頼配送、MTU超のフラグメンテーション、
多ストリーム、バックプレッシャの各経路も個別に確認した。
**ただし数値そのものは仮想化環境のものであり、絶対値としては使えない**（下記#1）。

優先順位: #1 → #2 → #3 → #4 → #5 → #6

---

## 1. 実機Linuxでの実測

**状態**: ⬜ 未実施（ユーザー側で実施）

Windows/Docker Desktop環境で計測した値は、仮想化オーバーヘッドとネットワーク経路の違いにより
絶対値が本番と異なる。`README.md`の「実行環境について」に記載の通り、実機Linux上で
`./scripts/smoke-test.sh` → `./scripts/run-all-benchmarks.sh` を実行して確定値を取ること。

**Aeronでは他の2プロジェクトより実機での再測定が重要**である。理由は、本プロジェクトの既定が
「ビジースピンする低レイテンシ構成」だから:

- `--driver-idle noop` — メディアドライバの3スレッドが常時1コアずつ占有
- `--poll-idle busy` — subscriber 1つにつき1コア
- `--pacing auto` — publisher 1つにつき（高レート時）1コア

つまり既定の1対1測定でも**5コアが常時スピンしている**。仮想化されたWSL2の12コアでは、これ自体が
互いを妨害する。実際、本環境の`steady-1000`（1000/s要求）で**実効884/sしか出ず**、ツールが
「publisherが追いつけない」と警告を出した — 秒間1000件で追いつけないはずがなく、これは
スピンスレッド同士の競合である。**実機のベアメタルLinuxで再測定するまで、レイテンシの
絶対値は使えない。**

### 実機でないと正しく評価できない項目

- **Subscriberスケーラビリティ（本プロジェクト最大の見どころ）**。仮説:
  Aeronは同一ホストのN個のsubscriberが**1つのメディアドライバとデータの1コピーを共有する**
  （ドライバがterm bufferに1回受信し、各subscriberが自分の位置で同じバッファを読む）ため、
  NATS（ブローカーがN部書く）やFast DDS（publisherがN個のRTPSピアに個別送信）と違い、
  **ほぼフラットになるはず**。Fast DDS側では実測で 110k → 1.1k msgs/s（1→25 Participant）の
  急落が確認されている。本環境ではCPU競合が支配的で仮説の検証にならなかった。
  **実機で`--poll-idle yield`＋十分なコア数で再測定すること。**

  本環境での実測（12コアのWSL2 VM、`--poll-idle yield`、無制限、128B）、
  subscriber 数 1 / 5 / 10 / 25 に対する publisher の msgs/s:
  **1.15M → 1.19M → 187k → 24k**。**5 までは完全にフラット**で、そこから
  崖になる。ただしこの崖は**スレッドがコアに収まらなくなる点と正確に一致**している
  （5 subscriber なら 5 poll + ドライバ 3 + publisher 1 = 9 スレッド ≤ 12 コア、
  10 subscriber なら 14 スレッド > 12 コア）。つまりこれは **CPU 枯渇** であって、
  仮説の検証にはなっていない。同じマシンでの Fast DDS は **5 Participant の時点で
  110k → 13.3k** と落ちており（コアには余裕があった）、そちらはピアごとの fan-out コスト。
  **Aeron 側の崖を fan-out の結果として引用しないこと。** コア数 ≥ subscriber 数 + 4 の
  環境で測り直すこと。
- **メディアドライバのアイドル戦略の効き**。本環境の複数回の実測で p50
  **245〜331µs（backoff）→ 21〜41µs（noop）**、一貫して **8〜14倍** の差が出た。ただし
  `noop`側の値はコア競合の影響を受けているので、実機ではさらに下がる見込み。
- **共有メモリ(IPC)の実力値**。本環境で p50 2.4〜7.5µs。仮想化層を挟まなければさらに下がる。
- **`tc netem`によるネットワーク遅延注入**。Docker Desktop（WSL2/Hyper-Vカーネル）には
  `sch_netem`モジュールが無いため`--netem-delay-ms`は効果がない（`nats/`で実測確認済み）。
- **測定値のばらつき**。本環境では同一条件の`steady-1000`が p50 23.2µs と 41.4µs、
  RTTが p50 37.5µs と 95.9µs と、実行ごとに2倍以上ぶれた。**短い実行で優劣を判断しないこと。**
  実機で安定するかどうかも確認事項。

### 参考: 本環境での実測値（実機Linuxで再測定すること）

| 測定 | 値 |
| --- | --- |
| 片道レイテンシ p50（UDPループバック、`--driver-idle noop`） | 21〜41 µs |
| 片道レイテンシ p50（同上、`--driver-idle backoff`＝Aeron既定） | 245〜331 µs |
| 片道レイテンシ p50（`aeron:ipc`） | 2.4〜7.5 µs |
| RTT p50 | 37〜96 µs |
| スループット（128B、1 pub / 1 sub、無制限） | 約 1.3〜1.4M msgs/s |
| スループット（16KB、1 pub / 1 sub、無制限） | 約 34k msgs/s（529 MB/s） |
| コンテナ間（ドライバ2つ）片道 p50 | 44.8 µs |
| 遅い subscriber（`--sub-work-us 20`、`--term-length 64k`） | pub 47.7k ≒ sub 47.3k msgs/s、バックプレッシャ 124万回、欠落 0 |

---

## 2. NATS / Fast DDS との比較レポート

**状態**: ⬜ 未着手（`fast-dds/TODO.md` #2 と同一の課題。3者に拡張された）

3プロジェクトの`results/run-index.csv`は列構成を完全に一致させてあるので、そのまま連結すれば
横断比較表になる。ただし**単純に数値を並べるだけでは誤読を招く**組み合わせがあり、
比較レポートを作る際は以下を明記する必要がある:

- **`msg_loss`の意味が3者で違う**（`README.md`の表を参照）。特にAeronでは
  「遅いsubscriberによる欠落」が原理的に起きないので、Fast DDSのBEST_EFFORTと同じ列に
  0 が並んでいても意味が違う。
- **スループットが答えている問いが違う**。Fast DDS BEST_EFFORTの無制限テストは
  「publisherが出せた速度（残りは欠落）」、Aeronの無制限テストは
  「最も遅いsubscriberが処理できた速度（欠落0）」。
- **Aeronだけドライバを低レイテンシ設定にしてある**。素の既定同士で比べたい場合は
  `--driver-idle backoff`の行（`stock-driver-defaults`シナリオ）を使うこと。
  この点を書かずにAeronの`steady-1000`とFast DDSの数値を並べるのは不公平。
- **公平な組み合わせ**:
  - NATS Core ↔ Fast DDS BEST_EFFORT+UDPv4 ↔ Aeron UDP（既定）— 3者比較として最も近い
  - Fast DDS RELIABLE ↔ Aeron 既定（信頼配送）— ただしNATSはブローカー経由で経路長が違う
  - Fast DDS SHM ↔ Aeron IPC — NATSに対応物なし、2者比較のみ
- **スケーラビリティは軸が3者とも違う**ので、横軸を揃えたグラフにはできない。

---

## 3. `tryClaim` によるゼロコピー送信

**状態**: ⬜ 未実装（現状は `offer()`）

`aeron_bench` は送信元バッファから term buffer へコピーする `offer()` を使っている。Aeron には
term buffer 内の領域を直接確保して書き込む `tryClaim()` があり、**Aeron公式のベンチマークは
小サイズでこちらを使う**。コピー1回分とはいえ、Aeronが議論される桁（µs以下）では効く。

実装上の注意:

- `tryClaim` は `maxPayloadLength`（MTU − ヘッダ）以下のメッセージにしか使えない。
  それを超えるサイズでは `offer()` にフォールバックする分岐が要る。
- `BufferClaim::commit()`／`abort()` の対応漏れが致命的（commitし忘れると受信側が永久に
  待つ）。例外経路も含めて必ずどちらかを呼ぶこと。
- **タイムスタンプを埋めるタイミングが変わる**。現状は`offerWithRetry`が試行のたびに
  ヘッダを書き直しているが、`tryClaim`では領域確保後に書くので「確保できた時刻」になる。
  意味はほぼ同じだが、`CLAUDE.md`の該当項の説明を更新すること。

優先度は中。レイテンシの最後の一段であり、Aeron公式値と突き合わせるなら必要になる。

---

## 4. メディアドライバのカウンタ読み取り

**状態**: ⬜ 未実装

Aeronのメディアドライバは、CnCファイル経由で大量のカウンタを公開している（公式ツールの
`AeronStat` が読むもの）。本プロジェクトが使えるはずのもの:

- **実際のロス数・NAK数・再送数**。`--reliable no` で欠落が出たとき、
  「ネットワークで落ちた」のか「受信側が追いつけずギャップが埋まらなかった」のかを
  切り分けられる。現状は欠落件数しか分からない。
- **`bytes sent` / `bytes received`**、**back-pressure カウンタ**（ドライバ側の視点。
  本ツールが数えているのはアプリ側の `offer()` 戻り値のみ）。
- **subscriber ごとの位置**。`--sub-count 25` のような測定で「一部のsubscriberだけ
  極端に遅れている」ケースを見分けられる（`fast-dds/TODO.md` #4 と同じ課題）。

C API の `aeron_cnc_*` 系（`CncFileReader.h` がラッパー側にもある）で読める。
`result.json` に `metrics.driver` として足すのが自然。

---

## 5. 実サーバー間の片道レイテンシ対応（PTP前提）

**状態**: ⬜ 未実装・**優先度低**（RTTによる代替は実装済み: `scripts/bench-rtt-2host.sh`）

`fast-dds/TODO.md` #6 と同一の課題で、原因も対処も同じ。**着手前に読むこと — おそらく不要**:

- **ミドルウェア比較**は同一ホストで測る方が適切（同条件・時計同期不要・片道を直接測れる）。
- **実配置の要件検証**は「同一ホストのミドルウェアコスト + ネットワーク単独のコスト」に
  分解でき、後者は `sockperf` / `netperf -t UDP_RR` 等でミドルウェア抜きに測れる。
  これが下限を与えるので、要件の可否はこれだけで判断できることが多い。
- それでも実配置での確認が要る場合は `bench-rtt-2host.sh`（RTT、時計同期不要）で足りる。

**背景**: `std::chrono::steady_clock`（`CLOCK_MONOTONIC`）はホストごとに任意の起点を持つため、
2台の値は比較できない。エラーにならず**それらしい値や負の値が出る**
（Fast DDS側で実際に負の値が観測されている）。

**片道対応に必要な改修**: `--clock realtime|monotonic` を追加し `CLOCK_REALTIME` ベースで
計測できるようにする。**PTPが規律するのは `CLOCK_REALTIME` であって `CLOCK_MONOTONIC` ではない**
ため、PTP同期が完璧でも現状のツールでは恩恵を受けられない。あわせて同期状態
（`master_offset`）を `result.json` に記録すること。手順の詳細は
`fast-dds/README.md`「実サーバー間の片道レイテンシ（PTP が必要）」を参照（内容はAeronでも同一）。

**`bench-rtt-2host.sh` は実機2台では未検証**。スクリプトの引数処理とエンドポイントの
対応付けは同一ホスト上のhostネットワークコンテナ2つで確認済みだが、
本当に2台のサーバー間で通すのは実機作業（#1と同時に行うのが効率的）。

---

## 6. 可視化・グラフ描画

**状態**: ⬜ 未着手（3プロジェクト共通の課題）

`run-index.csv`は全実行のフラットな横断サマリを提供するが、3プロジェクトともまだ
可視化レイヤーがない。実際のベンチマーク結果がプロットする価値のある量まで蓄積されてから、
**リポジトリ全体レベルの**フォローアップとして対応する（`aeron/`単独ではなく、
3つの`run-index.csv`を読んで比較グラフを出す形が望ましい）。

---

## 実装時に踏んだ落とし穴（記録）

`CLAUDE.md`の「Aeron-specific traps」に恒久的な注意点としてまとめてあるが、経緯として:

- **クラシックC++ APIは1.50.0で削除済み**。1.48でビルドすると
  "The C++ API will be removed in 1.50.0!" という `#pragma message` が出る。新規プロジェクトで
  削除済みAPIに固定するのは筋が悪いので、**C++ラッパーAPI**（`include/wrapper`、
  ヘッダオンリーでシンボルは C クライアント `libaeron` から）を採用し、1.52.2 に固定した。
  CentOS 7 / gcc 11 でクリーンにビルドできることを確認済み。
- **ラッパーのヘッダが `<aeronc.h>` をincludeする**。`/usr/local/include/aeron` も
  include path に入れる必要があり、忘れると `wrapper/util/Exceptions.h` の中で失敗するので
  「Aeronのインストールが壊れている」ように見える。
- **C++ラッパーの `Context` は `AERON_DIR` 環境変数を読まない**。ドライバは読むので、
  ドライバは `/dev/shm/aeron` に、クライアントは既定の `/dev/shm/aeron-root` に行き、
  「(-1000) driver timeout / CnC file not created」で落ちた。ツール側で明示的に読むよう修正。
- **Dockerの既定 `/dev/shm` は64MBでAeronには全く足りない**。publicationごとにterm bufferを
  3面マップするため。失敗はドライバ内部の不透明なmmapエラーになる。
  `docker-compose.yml`の`shm_size: 1gb`、entrypointの警告、smoke-testの検査の3段で対処。
- **メディアドライバのアイドル戦略が既定(backoff)だとレイテンシが10倍以上悪化する**。
  最大1msのparkが入るため。`noop`を既定にし、`--driver-idle`で両方測れるようにし、
  `scenarios.json`に素の既定での測定(`stock-driver-defaults`)も入れた。
- **送信バイト数がpublication windowに収まるスループット測定は「throughput」ではない**。
  `--msgs 50000 --size 128 --sub-work-us 20` が **pub 1.61M msgs/s / sub 48k msgs/s /
  バックプレッシャ0** という矛盾した結果を出した。6.4MB全部がwindowに収まるので`offer()`が
  一度も待たず、「term bufferを埋める速度」を測っていた。`--term-length 64k` で再測定すると
  **バックプレッシャ773k回、pub 46k/s（sub 46k/sに収束）**— 35倍の補正。
  シナリオに`term-length`を追加し、ツール側に「バックプレッシャ0でpubがsubの2倍以上速い」
  ケースを警告する検査を入れた。
- **Aeronの`SleepingIdleStrategy`のコンストラクタ引数がバージョン依存**。
  `SleepingIdleStrategy(std::chrono::microseconds)` はコンパイルできなかった。
  3種類のアイドル動作を自前で実装（`IdleKind`/`idleFor`）してバージョン結合を切った。
- **`BUILD_AERON_ARCHIVE_API=OFF` が必須**。ONだとCMakeが`gradlew`を呼びJDKを要求する。
  `AERON_TESTS`系もOFFにしないとビルド時にGoogleTestをダウンロードしに行く。
- **AeronはFast DDSより新しいCMakeを要求する**（1.48以降で3.30、fast-ddsのイメージは3.27.9）。
  2つのDockerfileの`CMAKE_VERSION`を安易に揃えないこと。
