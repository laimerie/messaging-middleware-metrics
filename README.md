# messaging_middlewear

各種メッセージングミドルウェアのパフォーマンス検証環境をまとめたリポジトリ。ミドルウェアごとに
独立したサブディレクトリを持ち、それぞれが自己完結した検証環境（Docker構成・スクリプト・
結果格納先・ドキュメント一式）を持つ。

## サブプロジェクト

| ディレクトリ | 対象 | 状態 |
| --- | --- | --- |
| [`nats/`](nats/README.md) | NATS Core（JetStreamなし、シングルノード） | 実装済み・検証済み |
| [`fast-dds/`](fast-dds/README.md) | Fast DDS（eProsima、DDS/RTPS） | 実装済み・実機Linuxでの実測は未実施 |

各サブディレクトリの詳細な使い方・前提条件は、そのディレクトリ内の`README.md`を参照。

## サブプロジェクト間の比較について

両サブプロジェクトの`results/run-index.csv`は**列構成を完全に一致させてある**（疎な共通
スキーマ）。そのまま連結すればミドルウェア横断の比較表になる。計測クライアントも両者とも
C++ / CentOS 7 / gcc 11 / C++17 で統一しており、クライアントランタイム側のオーバーヘッドの
差が数値に混入しないようにしている。

ただし**同じ列でも意味が異なるものがある**ため、比較する際は以下に注意する:

- **`msg_loss`**: NATS Core（TCP）では欠損＝異常。Fast DDSのBEST_EFFORTでは欠損＝仕様通りの
  動作で、飽和テストでは出るのが正常。詳細は[`fast-dds/README.md`](fast-dds/README.md)の
  「msg_lossの読み方」。
- **スケーラビリティの軸**: NATSは「接続数」、Fast DDSは「Participant数」。ブローカーの
  有無というアーキテクチャの違いによるもので、横軸を揃えたグラフにはできない。
- **公平な条件の組み合わせ**: NATS Core ↔ Fast DDS BEST_EFFORT + UDPv4（既定）が最も近い。
  Fast DDSの共有メモリ(SHM)モードには対応するNATS Coreの機能が無い。

比較レポート自体はまだ作成していない（[`fast-dds/TODO.md`](fast-dds/TODO.md) #2）。
