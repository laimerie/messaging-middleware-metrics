# TODO — Fast DDS検証環境のバックログ

準備フェーズ（`dds_bench` C++ツール、Dockerイメージ、全ベンチスクリプト、シナリオ定義）は
実装完了。`nats/`の完成済み構成を出発点に、DDS固有の差分（デーモンレス、トピックベース、
QoS、Discovery）を織り込んで構築した。

**動作検証の状況（Windows + Docker Desktop 上、Git Bash から実行）**: `smoke-test.sh`
（同一プロセス／コンテナ間の両方）、`bench-throughput.sh`・`bench-latency-oneway.sh`・
`bench-latency.sh`(RTT)・`bench-scalability.sh`・`bench-crosshost.sh`（latency/throughput
両方）・`run-all-benchmarks.sh`（`scenarios.json`の既定10シナリオ）を全て実行し、
**10/10シナリオが正常完了**することを確認済み。BEST_EFFORT/RELIABLE、UDP/SHM、
SIMPLE/Discovery Server、64KB超のフラグメンテーション、多トピックの各経路も個別に確認した。
**ただし数値そのものは仮想化環境のものであり、絶対値としては使えない**（下記#1）。

優先順位: #1 → #2 → #3 → #4 → #5

---

## 1. 実機Linuxでの実測

**状態**: ⬜ 未実施（ユーザー側で実施）

Windows/Docker Desktop環境で計測した値は、仮想化オーバーヘッドとネットワーク経路の違いにより
絶対値が本番と異なる。`README.md`の「実行環境について」に記載の通り、実機Linux上で
`./scripts/smoke-test.sh` → `./scripts/run-all-benchmarks.sh` を実行して確定値を取ること。

特にFast DDS固有で、実機Linuxでないと正しく評価できない項目:

- **UDPマルチキャストによるSIMPLE discovery**。Dockerブリッジ越しのマルチキャストは環境依存で
  届かないことがある（`CLAUDE.md`参照）。実機Linuxホスト上のDockerであれば通る見込みだが未検証。
  `smoke-test.sh`のステップ3がこれを実際に検査して結果を報告する。
- **`tc netem`によるネットワーク遅延注入**。Docker Desktop（WSL2/Hyper-Vカーネル）には
  `sch_netem`モジュールが無いため`--netem-delay-ms`は効果がない（`nats/`で実測確認済み）。
  実機Linuxカーネルなら動作する見込み。
- **共有メモリ(SHM)トランスポートの実力値**。`--transport shm`はFast DDSの最大の強みだが、
  仮想化層を挟んだ環境では本来の性能が出ない。
- **Participant数のスケーラビリティ上限**。`bench-scalability.sh`の既定掃引は安全側の
  `1,5,10,25`。NATS側では実測でWindows/Docker Desktop環境の上限が10〜50の間にあることが
  判明した（`nats/TODO.md` #5）。DDSのParticipantはTCP接続よりはるかに重い。

  **本環境での実測（要・実機Linuxでの再測定）**: publisher側スループットがParticipant数に
  対して急激に低下した — 1 / 5 / 10 / 25 Participantで
  **110k → 13.3k → 3.6k → 1.1k msgs/s**（無制限速度、128B）。欠損は全て0だったため、
  これはドロップではなく**ピアツーピアのfan-outによるback-pressure**（publisherがN個の
  独立したRTPSピアそれぞれに書き込んでいる）。ブローカー型との定性的な違いが最も端的に
  出る数値であり、**実機Linuxで最優先に再測定すべき項目**。25 Participantの1イテレーションに
  約2分かかった点も、掃引時間の見積もりとして留意すること。

---

## 1.5 送信ペーシングの精度（対応済み）

**状態**: ✅ 実装済み（`--pacing auto|sleep|busy`）

**問題**: 当初はレート制御を `sleep_until` のみで行っていたため、OSのタイマー精度が
送信間隔と同じオーダーになる高レートで、**要求レートを達成できていなかった**。
実測で `sleep_for(100µs)` が中央値183µs（超過83µs、p99では超過300µs）かかり、
**要求10,000/sに対し実効5,552/sしか出ていなかった**。つまり「10,000/sの測定結果」と
称して別の条件を測っていたことになる。加えて起床タイミングのばらつきで送信がバースト化し、
受信側のキュー滞留を招いてテールを悪化させていた。

**対処**: 残り200µs（`kPacingSpinGuard`）まではスリープし、そこからビジーウェイトに
切り替える `auto` を既定に。実効9,437/s（94%）を達成し、副次的にレイテンシも改善
（p50 74→62µs、p99 407→298µs）。要求レートの90%を下回った場合は警告を出すようにした。

**実装中に見つけた副次バグ（修正済み）**: コア数不足の警告に
`std::thread::hardware_concurrency()` を使っていたが、libstdc++ はこれを
`sysconf(_SC_NPROCESSORS_ONLN)` で実装しており、**コンテナ内でもホストのコア数を返す**
（`--cpuset-cpus=0,1` でも12を返すことを確認）。本ツールは常にコンテナ内で動くため、
警告が必要な状況でこそ機能しない死んだコードになっていた。`sched_getaffinity`（cpuset対応）と
cgroupのCPU quota（`--cpus`対応）の小さい方を採る `availableCores()` に置き換え、
両方の制限方式で警告が出ることを実測確認した。

**残課題**: `kPacingSpinGuard` の200µsは本環境のスリープ精度から決めた値。実機Linuxでは
タイマー精度が改善するはずなので、実機で測り直して閾値を下げられる（＝CPU消費を減らせる）
可能性がある。

---

## 2. NATSとの比較レポート

**状態**: ⬜ 未着手

両プロジェクトの`results/run-index.csv`は列構成を完全に一致させてあるので、そのまま連結すれば
横断比較表になる。ただし**単純に数値を並べるだけでは誤読を招く**組み合わせがあり、
比較レポートを作る際は以下を明記する必要がある:

- **`msg_loss`の意味が違う**。NATS Core（TCP）では欠損＝異常、Fast DDSのBEST_EFFORTでは
  欠損＝仕様通りの動作。同じ列に並ぶが解釈が異なる（`README.md`の「msg_lossの読み方」）。
- **公平な比較の組み合わせ**:
  - NATS Core ↔ Fast DDS BEST_EFFORT + UDPv4（既定）— 配信保証のレベルが最も近い
  - NATS Core ↔ Fast DDS RELIABLE — TCPの再送保証に近いのはこちらだが、
    NATSはブローカー経由、DDSは直接なので経路長が違う
  - Fast DDS SHM は比較対象なし（NATS Coreに対応する機能が無い）— DDS単独の参考値
- **スケーラビリティの軸が違う**（接続数 vs Participant数）ため、横軸を揃えた
  グラフにはできない。別グラフにするか、軸のラベルを明示する。

---

## 3. TCPトランスポート対応

**状態**: ⬜ 未実装（`--transport tcp`は明示的にエラーになる）

`dds_bench`は現在UDPv4と共有メモリのみ対応。DDS over TCPは、片側にリスナーポート
（`TCPv4TransportDescriptor::add_listener_port`）を開き、もう片側に`initialPeersList`で
相手のTCPロケータ（physical port + logical port）を明示する必要があり、
UDP/SHMのように「トランスポートを差し替えるだけ」では済まない。
またSIMPLE discoveryはマルチキャスト前提なので、TCPでは実質Discovery Server併用が前提になる。

実装するなら`bench-crosshost.sh`（相手のアドレスが確定している構成）に限定するのが妥当。
優先度は低い — NATSがTCPなので「同じTCPで比較したい」という動機はあるが、
RELIABLE QoS + UDPの方が配信保証の観点では近い比較になる。

---

## 4. 出力フォーマットの拡張

**状態**: ✅ 基本実装済み（`result.json` / `run-index.csv` / 生CSV）

現状の出力:
- `result.json` — `dds_bench`自身が書く。`nats/`のスキーマと同じキー名・同じ単位
  （レイテンシはマイクロ秒、スループットはmsgs/sec・MB/sec、`msg_loss`はトップレベル）。
  加えてDDS固有の`params`（reliability/durability/history/transport/discovery/intraprocess）を
  記録するので、結果ファイル単体でどのQoS下の測定か分かる。
- `run-index.csv` — 列構成は`nats/`と完全一致。
- `oneway.csv` / `rtt.csv` — メッセージ単位の生レイテンシ。
- `throughput.csv` — 秒ごとの受信バケット（NATS側には無い出力）。スループット値が
  「安定したレートだったのか、最初だけ受けて後は落ちたのか」を区別するために追加した。
  BEST_EFFORTの飽和テストではこの区別が本質的になる。

**未対応**: Participantごと・トピックごとの内訳。現状は全Reader分を合算した値しか出さない。
`--sub-count 25`のような測定で「一部のParticipantだけ極端に欠損している」ケースを
見分けられないので、必要になったらReader単位の内訳をCSVに出す。

---

## 6. 実サーバー間の片道レイテンシ対応（PTP前提）

**状態**: ⬜ 未実装・**優先度低**（RTTによる代替は実装済み: `scripts/bench-rtt-2host.sh`）

**着手前に読むこと — おそらく不要です**: 当初これを必須と考えたが、測定目的を分解すると
不要になる可能性が高い（`README.md`「まず、どちらの問いに答えたいのかを分ける」参照）。

- **ミドルウェア比較**は同一ホストで測る方が適切（同条件・時計同期不要・片道を直接測れる）。
  実際、Fast DDS 20µs vs NATS 50µs という結論は同一ホスト測定だけで得られている。
- **実配置の要件検証**は「同一ホストのミドルウェアコスト + ネットワーク単独のコスト」に
  分解でき、後者は `sockperf` / `netperf -t UDP_RR` 等でミドルウェア抜きに測れる。
  これが下限を与えるので、要件の可否はこれだけで判断できることが多い。
- それでも実配置での確認が要る場合は `bench-rtt-2host.sh`（RTT、時計同期不要）で足りる。

**本項目が本当に必要になるのは「実配置での片道レイテンシの実数値」がどうしても要る場合のみ。**

**背景**: 実サーバー2台でのレイテンシ測定で**負の値が観測された**。原因は
`std::chrono::steady_clock` がホストごとに任意の起点を持つ単調時計であり、
2台の値は比較できないため（`tools/dds_bench/main.cpp` 冒頭に制約として記載済み）。
コンテナ分割（`bench-crosshost.sh`）では同一カーネルの時計を共有するので成立していたが、
実サーバー間では原理的に成立しない。

**現状の代替（実装済み）**: `scripts/bench-rtt-2host.sh` による往復（RTT）測定。
ping 側が自分の時計だけで計測するため**時計同期が不要**。実測で16,000/16,000・欠損0を確認済み。
ただし RTT にはエコー側の受信・再送信コストが含まれるため、**RTT÷2 は片道を過大評価する**。

**片道対応に必要な改修**:
- `--clock realtime|monotonic` を追加し、`CLOCK_REALTIME` ベースで計測できるようにする。
  **PTP が規律するのは `CLOCK_REALTIME` であって `CLOCK_MONOTONIC` ではない**ため、
  PTP同期が完璧に動いていても現状のツールでは恩恵を受けられない。
- 同期状態の検証を測定に組み込む（`master_offset` を result.json に記録する等）。
  同期がずれた状態で測ると、やはりエラーなく誤った値が出るため。
- `CLOCK_REALTIME` は NTP 等でステップ調整されうる点に注意（測定中の飛びを検出する必要がある）。

**前提となる環境側の作業**（ユーザー側で未達）:
- NIC のハードウェアタイムスタンプ対応確認（`ethtool -T`）
- `ptp4l`（PHC同期）に加えて **`phc2sys`（システムクロック同期）が必須** — これの漏れが
  最も一般的な失敗原因
- 詳細な手順は `README.md`「実サーバー間の片道レイテンシ（PTP が必要）」を参照

---

## 5. 可視化・グラフ描画

**状態**: ⬜ 未着手（`nats/`と共通の課題）

`run-index.csv`は全実行のフラットな横断サマリを提供するが、両プロジェクトともまだ
可視化レイヤーがない。実際のベンチマーク結果がプロットする価値のある量まで蓄積されてから、
**リポジトリ全体レベルの**フォローアップとして対応する（`fast-dds/`単独ではなく、
両者の`run-index.csv`を読んで比較グラフを出す形が望ましい）。

---

## 実装時に踏んだ落とし穴（記録）

`CLAUDE.md`の「DDS-specific traps」に恒久的な注意点としてまとめてあるが、経緯として:

- **intra-process deliveryが既定で有効**。Fast DDSは同一プロセス内のEndpoint間で
  トランスポートを完全にバイパスする。`--mode both`（同一プロセス内でpub/sub）は
  同一ホスト測定の基本形なので、これに気づかないと「サブマイクロ秒のレイテンシ」という
  無意味な値が出る。`applyLibrarySettings()`で明示的に`INTRAPROCESS_OFF`にしている。
- **builtin transportがSHMとUDPを両方有効にする**。同一Dockerホスト上の別コンテナ同士は
  「同じ物理マシン」なのでSHMロケータがマッチしうるが、`/dev/shm`はコンテナごとに別。
  結果、エラーも出さずに全件ロストする。`use_builtin_transports = false`にして
  トランスポートを明示指定することで構造的に回避した。
- **Discovery ServerのロケータはIPアドレスのみ**。`IPLocator::setIPv4`はDockerのDNS名
  （`discovery-server`）を受け付けない。`docker-compose.yml`でサブネットと静的IPを固定し、
  `common.sh`の`DS_ADDRESS`と対応させる必要がある。
- **64KB以上のメッセージはASYNCHRONOUS publish modeが必須**。SYNCHRONOUSのままだと
  フラグメンテーションが行われず、単に届かない（エラーにもならない）。
  `--size >= 60000`で自動切り替えするようにした。
- **RELIABLEでは`resource_limits`の既定値（max_samples=5000）が詰まる**。未ACKサンプルを
  保持する必要があるため、ベンチマーク規模では`write()`がストールする。無制限（0）に設定。
- **`parse_common_arg`をコマンド置換で呼ぶとQoS設定が失われる**。サブシェルで実行されるため。
  グローバル変数経由で消費数を返す方式にした。
