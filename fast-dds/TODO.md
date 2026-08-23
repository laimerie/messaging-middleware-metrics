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
