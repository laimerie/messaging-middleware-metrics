# NATS Leaf NodeによるFan-out / Tail Latency改善の検証

## 1. 背景・目的

現在、以下のようなNATS構成を想定している。

* Publisher（PUB）アプリケーションは1つ
* Publisher側ホストとSubscriber側ホストは分離されている
* 測定用のSubscriber側ホストは1台とする
* Subscriber側ホスト上でSubscriberを100個実行する
* Subscriber総数は100
* 100個のSubscriberを1台のホストへ集約した場合のCore/Leaf構成を比較する
* TIBRVからの置き換えのためにNATSを検証する。TIBRVは各ホストのrvdの通信がマルチキャストのため、そこがtcpに変わる影響をどうやって最小限に抑えるを知りたい


現在の構成：

```text
                    PUBホスト
                 Publisher / Core NATS
                         │
                    TCP接続
                         │
                    SUBホスト
                  Subscriber ×100

Total: 2 hosts、100 SUB（SubscriberはSUBホストに集約）
```

これをNATS Leaf Nodeを使って階層化し、PUBホストのCore NATSから100個のSubscriberへ
直接配信する構成と、Core NATSから例えば5個のLeaf Nodeへ配信し、Leaf NodeがSUBホスト上の
Subscriberへfan-outする構成を比較する。Subscriber-side NATSや100台のSubscriber hostは
今回の測定では使用しない。

想定構成：

```text
                         PUBホスト
                    Publisher / Core NATS
                       │    │    │
                    Leaf-1 ... Leaf-5
                       │    │    │
                 ──────┴────┴────┴────── TCP ──────
                                      │
                                  SUBホスト
                              Subscriber ×100

Total:
5 Leaf（PUBホスト上）
100 Subscriber（SUBホスト上）
```

## 2. 検証したい仮説

今回の最優先事項は、Leaf数とSubscriber数の違いによって、実機2ホスト間の配信レイテンシ
（特にp50、p99、p99.9）がどのように変化するかを明らかにすることである。CPU使用率や
ネットワーク・NATS内部値は、レイテンシの変化の原因と実用上の制約を評価する補助指標として
測定する。

### 仮説1：Leaf数・Subscriber数によってtail latencyが変化する

Leaf数およびSubscriber数を変化させたとき、p50、p95、p99、p99.9、max latencyがどのように
変化するかを比較する。特に、Leaf追加による追加hopの固定コストと、高負荷時のtail latencyの
悪化または改善を分けて評価する。

### 仮説2：PUB側のfan-out負荷を減らせる

現在：

```text
PUBホストのCore NATS → 100 Subscriber（SUBホスト）
```

Leaf構成：

```text
PUBホストのCore NATS → 5 Leaf（同じPUBホスト）
                         ↓
                    100 Subscriber（SUBホスト）
```

Core NATSが100個のSubscriber接続を直接処理する代わりに、5個のLeaf接続へ集約することで、
Core NATSの処理負荷・queueingを減らせるか確認する。LeafはPUBホスト上のNATS Serverとして
起動し、SubscriberはLeafのclient portへSUBホストから接続する。

### 仮説3：CPU使用率はレイテンシ結果を説明する

Leaf数を、

```text
1
2
5
10
```

と増やした場合に、レイテンシの変化と合わせてCore NATS CPU、Leaf合計CPU、全NATS CPUを
測定する。CPU削減そのものを成功条件とせず、レイテンシの改善・悪化・飽和がどの負荷状態や
ボトルネックと対応するかを解釈するために使用する。

高負荷によって一部の接続で送信詰まりが発生した場合、その影響がLeaf単位に局所化されるかを
副次的に観測する。Subscriberを意図的に遅くする試験や、NATS Server設定を変更してslow consumerを
発生させる試験は実施せず、通常負荷で自然発生した場合だけ記録する。

## 3. 検証環境

同一ホスト上のDockerコンテナによる測定は実施しない。Dockerを利用できるホストは
マシンスペックが測定条件に耐えないため、ビルドおよび配布パッケージ作成専用とする。
実測はDockerを利用できない高性能な実機Linuxホストで行う。

### ビルドホスト

以下は測定対象ではなく、再現可能な実行物を作成するためだけに使用する。

* Docker / Docker Compose
* `package-native.sh`によるNATS Server、ベンチマーククライアント、依存ライブラリのビルド
* 生成したtarballとSHA-256 checksumの保管

ビルドホストのCPU、Dockerネットワーク、コンテナ内のレイテンシおよびCPU使用率は、測定結果に
含めない。Docker上での動作確認はスモークテストに限定する。

### 測定ホスト

PUBとSUBを別々の高性能Linuxホストに配置する。

* PUBホスト：Publisher、Publisher-side Core NATSおよびLeaf Node
* SUBホスト：Subscriberアプリケーション100個
* 両ホストへ同一の配布パッケージを転送し、ネイティブプロセスとして実行
* NATS Server：使用する具体的なバージョンを固定
* Cluster：使用しない
* JetStream：使用しない
* Core NATS + Leaf Nodeを使用
* PUB/SUB間のTCPポート、monitoring APIおよび必要なLeaf接続ポートを相互到達可能にする
* CPU affinity、CPU quota、NIC、MTU、OS、電源・性能設定をケース間で固定し、メタデータへ保存

LeafはPUBホスト上で独立したネイティブNATSプロセスとして実行し、各SubscriberはPUBホスト上の
CoreまたはLeafのclient portへ、SUBホストから直接接続する。SUBホストにSubscriber-side NATSは
置かない。100個のSubscriberをLeaf数に応じて均等に割り当て、各Leafの接続数と割り当てを
メタデータへ保存する。

### 配布と起動手順

1. ビルドホストでNATSのバージョンを固定し、`package-native.sh`を一度実行する。
2. tarballとchecksumをPUB/SUBの両ホストへ転送し、各ホストで展開と`preflight.sh`を実行する。
3. PUB側のCore NATSとLeafを起動し、LeafのCore接続を確認する。
4. SUB側でSubscriber 100個を起動し、指定したCoreまたはLeafへの購読登録を確認する。
5. SUB側の購読登録完了後、PUB側でPublisherを起動し、固定したwarm-up後に測定を開始する。
6. 測定終了後、PUB/SUB双方の結果、ログ、CPU、メモリ、ネットワーク、バージョン情報を回収する。

### Phase 1

実機2ホスト（PUB/SUB分離）による健全系の比較

目的：

* PTP同期下での片道latency測定
* DirectとLeafのp50/p99/p99.9および追加hopコストの測定
* Leaf数・Subscriber数によるlatency分布の変化の確認
* レイテンシ結果を解釈するためのCPU・ネットワーク負荷の記録

### Phase 2

実機2ホストでの負荷・tail latency検証

目的：

* Leafを含む実際の配信経路
* 高負荷時のp50/p99/p99.9/max latency
* ネットワーク帯域とRTT
* SUBホスト向け接続で送信詰まりが発生した場合の影響
* tail latencyの悪化・改善・飽和条件

を検証する。単一ホストDockerの数値は、性能比較および最終結論のデータには使用しない。

## 4. テスト構成

### Baseline

Leafを使わない。100個のSubscriberはSUBホストからPUBホストのCore NATSへ直接接続する。

```text
PUBホスト
    Core NATS
      │
      └──────── TCP ──────── SUBホスト
                             Subscriber ×100
```

### Leaf構成

```text
PUBホスト
    Core NATS
    ├── Leaf-1
    ├── Leaf-2
    ├── ...
    └── Leaf-5
          │
          └──────── TCP ──────── SUBホスト
                                 Subscriber ×100
```

本番相当構成として、

* Leaf：5（PUBホスト上）
* Subscriber-side NATS：0
* Subscriber：100（SUBホスト上）

を基本ケースとする。

## 5. テストパラメータ

### トポロジー

| Parameter                | Values             |
| ------------------------ | ------------------ |
| Publisher                | 1                  |
| Publisher-side Core NATS | 1                  |
| Leaf Node                | 0 / 1 / 2 / 5 / 10 |
| Subscriber-side NATS     | 0                  |
| Subscriber               | 10 / 50 / 100      |
| Cluster                  | 無効                 |
| JetStream                | 無効                 |
| Subject                  | 1                  |
| Subscriber / Subject     | 全Subscriber        |

### Publish負荷

| Parameter    | Values                                               |
| ------------ | ---------------------------------------------------- |
| Publish rate | 100 / 1,000 / 3,000 / 10,000 / 20,000 / 30,000 msg/s |
| Message size | 128 B / 500 B / 1 KB / 4 KB                          |
| Publisher    | 1                                                    |
| Subject      | 1                                                    |

最初は500 B固定で実験し、その後message sizeを変える。

### Subscriber

今回の測定構成：

```text
1 Subscriber host
×
100 Subscriber
=
100 Subscriber
```

テストでは、

```text
10
50
100
```

と段階的に増やす。

### Slow consumerの観測

アプリケーションにsleepを入れたり、NATS Server設定でslow consumerを意図的に発生させたりする
試験は、今回の主目的には含めない。通常の負荷試験中に自然発生した場合だけ、pending bytes、slow
consumer検出、接続切断、message lossを記録する。発生しなかった場合も「slow consumer未発生」と
記録し、Leafの優劣をこの結果から推測しない。

`max_pending`と`write_deadline`は送信詰まりに対する保護動作を調べる別目的の障害・境界試験であり、
必要性が明確になった場合に別計画として追加する。

## 6. 最重要テストケース

まず以下の6ケースで、Direct／Leafの経路と測定ツールが正常に動作することを確認する。
これらは初期確認用であり、最終的なレイテンシ評価は、後述する全Leaf数・Subscriber数・publish
rateの組み合わせで行う。

| Test | Leaf | Subscriber |  Rate |  Size |
| ---: | ---: | ---------: | ----: | ----: |
|    1 |    0 |         10 |  1k/s | 500 B |
|    2 |    5 |         10 |  1k/s | 500 B |
|    3 |    0 |        100 |  1k/s | 500 B |
|    4 |    5 |        100 |  1k/s | 500 B |
|    5 |    0 |        100 | 30k/s | 500 B |
|    6 |    5 |        100 | 30k/s | 500 B |

最初に確認する最重要指標は、

```text
各Leaf数・Subscriber数・publish rateにおけるp50/p99/p99.9
```

である。

Test 5とTest 6でまず代表的な高負荷時のlatency分布を比較する。その後、Leaf数を`0 / 1 / 2 / 5 / 10`、
Subscriber数を`10 / 50 / 100`、publish rateを指定値ごとに独立した試行として組み合わせ、p50/p99/p99.9
の改善・悪化・飽和の曲線を確認する。CPU使用率は、これらのlatency差が生じた理由を分析するために
併記する。`max_pending`と`write_deadline`を変更する専用試験は実施せず、通常負荷中に自然発生した
pending増加・slow consumer・切断・message lossだけを補助的な観測値として記録する。

## 7. Publish rateごとに独立して測定する

30,000 msg/sを最初から投入せず、低いrateで経路と受信状態を確認する。ただし、rateを上げた
状態を引き継がないよう、latencyの比較対象となる各rateは独立した試行として実行する。

各構成について、測定対象のrateを、

```text
1,000
 ↓
3,000
 ↓
10,000
 ↓
20,000
 ↓
30,000 msg/s
```

ごとに個別の試行として実行する。前のrateの接続・キュー・サーバー状態を次の試行へ持ち越さず、
各試行のwarm-up前に必要なプロセスを再起動する。

各rateについて十分なwarm-up時間を設け、その後一定時間測定する。

可能なら各ケースを複数回実行し、中央値または代表値を使用する。

## 8. Fan-out量について

100 Subscriberが全員同じsubjectをsubscribeする。

例えば、

```text
1,000 msg/s
×
100 Subscriber
=
100,000 deliveries/s
```

となる。

30,000 msg/sの場合：

```text
30,000 msg/s
×
100 Subscriber
=
3,000,000 deliveries/s
```

となる。

500 B payloadだけで考えると、

```text
3,000,000
×
500 B
=
1.5 GB/s
```

相当のSubscriber delivery量になる。

したがって30,000 msg/s × 100 Subscriberは高負荷試験として扱う。

## 9. 測定値

### Latency

最優先の評価指標。各試行でまずlatencyの有効性と分布を確認し、その後にCPU、ネットワーク、
NATS内部値を対応付けて原因を分析する。

* p50
* p95
* p99
* p99.9
* max

PublisherとSubscriberは別ホストで動作するため、両ホストの`CLOCK_REALTIME`をPTPで同期する。
測定開始前、測定中、測定終了後にPTPの同期状態と時刻offsetを記録し、許容誤差を満たさない
試行はレイテンシ比較から除外して再実行する。`CLOCK_MONOTONIC`のホスト間差分は使用しない。
Publisher timestampをmessageに埋め込み、SubscriberではNATS callbackで受信した直後の時刻を記録する。

```text
latency =
subscriber receive timestamp
-
publisher timestamp
```

で測定する。

これはmiddlewareの受信レイテンシとして扱い、アプリケーション処理時間は含めない。Slow consumerの
影響を調べる場合も、アプリケーションsleepによる処理遅延は作らず、NATS Server設定によるpending増加、
送信期限超過、接続切断およびその結果としての受信レイテンシを記録する。PTP同期精度、測定時刻、
clock sourceを`meta.json`へ保存する。

可能ならSubscriberごとのlatencyを保存する。

これにより、

```text
平均は改善したか
```

だけではなく、

```text
最も遅い接続はどうなったか
```

を確認できる。

### Throughput

* publish msg/s
* delivered msg/s
* message loss
* duplicate message
* sequence gap

を測定する。

### CPU（レイテンシ評価の補助指標）

NATS Serverごとに、

* Core NATS CPU
* Leaf CPU
* Subscriber application CPU

を測定する。

CPUはレイテンシ結果の原因分析と、測定条件が実用可能かの確認に使用する。CPU単独でLeaf採用を
判断せず、同じケースのp50/p99/p99.9、throughput、message lossと併せて評価する。

特に、

```text
Core CPU
vs
Leaf合計CPU
```

を比較する。

### 測定中断条件

他のプロセスも動作しているため、ベンチマークプロセスだけでなく、各測定ホストの全プロセスを含む
ホスト全体のCPU使用率を監視する。CPU使用率は全コアの合計をホストの全コア容量で正規化した値とし、
次の条件で試行を中断する。

* PUBホストまたはSUBホストの全体CPU使用率が80%以上に達した場合
* CPU使用率は一定間隔で監視し、判定した時点のtimestamp、PUB/SUBそれぞれの使用率、コア数を保存する
* 条件に達したらベンチマーク対象のPublisher、Subscriber、NATS Serverだけを強制終了し、他のプロセスは
  終了させない。終了処理後に試行を終了する
* 結果には`aborted_by_cpu_limit: true`、到達したホスト、到達時刻、到達時のpublish rateを記録する
* CPU上限で中断した試行は失敗扱いにせず、到達可能だった負荷の上限として記録する。ただし、中断後の
  latencyやthroughputを試行全体の代表値として扱わない

CPU上限に達せず正常完了した試行だけを通常のケース間比較に使用する。CPU使用率の瞬間的な
スパイクによる誤判定を避けるため、監視周期と判定の継続時間は全試行で固定する。

### Memory

* Core NATS memory
* Leaf memory

### Network

NATS Serverごとに、

* RX bytes/s
* TX bytes/s
* packets/s
* connection count

を測定する。

### NATS metrics

利用可能なNATS monitoring endpointを使用して、

* connection数
* subscription数
* message in/out
* bytes in/out
* pending
* RTT
* Leaf connection状態

などを取得する。

## 10. 期待する結果

以下を確認したい。

### 成功パターン

Leaf構成で、

```text
p50/p99/p99.9
Direct > Leaf
```

となる、または同等のlatencyを保ちながら、より高いpublish rate・Subscriber数を処理できる。
CPU使用率は、上記のlatency結果を説明する補助情報として記録する。必ずしもCore CPUが下がる
ことを成功条件とはしない。

CPU上限に達した場合は、そのrateのlatency結果を通常完了ケースと分離し、到達可能な負荷上限と
して扱う。

Leaf構成のlatencyが、

```text
p50/p99/p99.9
Direct < Leaf
```

となる場合も、追加hopコストとして重要な結果として記録する。CPU削減が確認できてもlatencyが
許容範囲を超えて悪化する場合は、性能改善とは結論しない。

通常負荷中にslow consumerが発生した場合は、pending増加・切断・message lossの有無と、影響を受けた
Leaf配下を記録する。ただし、発生しなかった場合も正常な結果として扱う。

### 失敗パターン

Leaf構成で、

* Core CPUは下がるがp99は改善しない
* Leafの追加hopによってp50/p99が悪化する
* 実機2ホストでは改善しない、または追加hopで悪化する
* Leaf数を増やしても一定数以上で効果が飽和する

可能性もある。

これらも重要な結果として記録する。

## 11. 特に確認してほしいこと

単に「Leafのほうが速かった」という結論にしないこと。

以下を明確に分析する。

1. Leaf数・Subscriber数・publish rateによってp50/p95/p99/p99.9/maxがどう変化したか
2. Direct構成とLeaf構成の追加hopコストはいくらか
3. 高負荷時にtail latencyが悪化・改善・飽和する条件は何か
4. Direct構成のボトルネックは何か
5. Leaf構成ではそのボトルネックがどこへ移動したか
6. latencyの変化とCore・Leaf・全体CPU使用率がどう対応したか
7. 自然発生したpending増加・slow consumer・切断がtail latencyへどう影響したか
8. Leaf数を増やした場合の改善曲線
9. どのLeaf数で性能が飽和するか
10. 30,000 msg/sでCPU/NIC/NATSのどこが最初に飽和するか
11. Message sizeによって結果がどう変わるか
12. ビルドホストのDocker環境と実機2ホストの結果を混同せず、実機で結果が変わるか

## 12. 最終的な成果物

検証終了後、以下をレポートとしてまとめること。

### A. 構成図

DirectとLeaf構成の比較。

### B. Test Matrix

全テスト条件と結果。

### C. Performance Graph

最低限以下のグラフを作成する。

1. Publish rate vs p50
2. Publish rate vs p99
3. Publish rate vs p99.9
4. Publish rate vs Core CPU（補助指標）
5. Publish rate vs total NATS CPU（補助指標）
6. Leaf count vs p50/p99/p99.9
7. Leaf count vs Core CPU（補助指標）
8. Subscriber count vs p50/p99/p99.9

### D. Tail Latency Analysis

通常負荷で完了したケースについて、

```text
Direct
vs
Leaf
```

のp50/p99/p99.9/maxを比較する。CPU上限で中断したケースは、到達時点までの値と明確に分けて
「CPU上限到達」として表示する。

### E. Bottleneck Analysis

CPU、memory、network、NATS内部処理のどこがボトルネックだったかを特定する。

### F. 結論

以下について明確に結論を出す。

* Leaf Nodeを採用した場合、p50/p99/p99.9が許容範囲に収まるか
* Leaf数・Subscriber数によるlatencyの改善・悪化・飽和の傾向
* 最適なLeaf数はいくつか
* 30,000 msg/s × 500 B × 100 SUBを処理できるか
* Tail latencyが実際に改善するか、追加hopのコストがどの程度か
* そのlatency結果を得るために必要なCPU・ネットワーク資源はどの程度か
* 本番環境で採用する場合の推奨構成

## 13. 注意事項

性能測定では、DirectとLeafで以下の条件を可能な限り一致させること。

* CPU
* Memory
* 実行バイナリおよびNATS設定
* NATS設定
* message size
* publish rate
* subscriber数
* subscriber処理
* OS
* NATS version

Dockerホストではビルドとスモークテストだけを行い、性能値として採用しない。最終比較は同じ
配布物を使った実機2ホスト（PUB/SUB分離）の結果だけで行う。実機の測定ではPTP同期状態と
PUB/SUBのホスト性能差を必ず記録する。

最終的な採用判断は、次の優先順位で行う。

1. p50/p99/p99.9/max latencyが許容範囲か
2. message loss、duplicate、sequence gapがないか
3. CPU上限に達せず、要求したpublish rate・Subscriber数を完了できるか
4. 上記の結果を説明する補助指標として、Core・Leaf・全体CPU、memory、networkを確認する

CPU削減の有無だけで採用を判断せず、特に

```text
p99
p99.9
max
message loss
```

を重視すること。
