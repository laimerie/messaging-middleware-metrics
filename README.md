# messaging_middlewear

各種メッセージングミドルウェアのパフォーマンス検証環境をまとめたリポジトリ。ミドルウェアごとに
独立したサブディレクトリを持ち、それぞれが自己完結した検証環境（Docker構成・スクリプト・
結果格納先・ドキュメント一式）を持つ。

## サブプロジェクト

| ディレクトリ | 対象 | 状態 |
| --- | --- | --- |
| [`nats/`](nats/README.md) | NATS Core（JetStreamなし、シングルノード） | 実装済み・検証済み |
| [`fast-dds/`](fast-dds/README.md) | Fast DDS（eProsima、DDS/RTPS） | 実装済み・実機Linuxでの実測は未実施 |
| [`aeron/`](aeron/README.md) | Aeron（aeron-io、UDP／共有メモリIPC） | 実装済み・実機Linuxでの実測は未実施 |

各サブディレクトリの詳細な使い方・前提条件は、そのディレクトリ内の`README.md`を参照。

## 3つのアーキテクチャ

3者は「メッセージングミドルウェア」でひとくくりにできるが、サーバープロセスの有無という
一番効く軸で見ると、それぞれ別のかたちをしている。数値を比較する前にここを押さえること。

| | NATS Core | Fast DDS | Aeron |
| --- | --- | --- | --- |
| サーバープロセス | **ブローカー**（中央に1つ） | **無し**（デーモンレス） | **メディアドライバ**（ホストごとに1つ） |
| データ経路 | pub → ブローカー → sub | pub → sub のピアツーピア | ドライバ → ドライバ |
| 相手の発見 | ブローカーのアドレス | Discovery（マルチキャスト等） | **無し**（URIがそのままアドレス） |
| Subscriberが遅いとき | ブローカーが溜める | BEST_EFFORTなら欠落 | **publisherにバックプレッシャ** |
| アプリへの配送 | コールバック | コールバック | **アプリ側がpollする** |

Aeronの「メディアドライバ」はブローカーではない（ホスト間の中継をしない）が、同時に
デーモンレスでもない。詳細は[`aeron/README.md`](aeron/README.md)。

## サブプロジェクト間の比較について

3サブプロジェクトの`results/run-index.csv`は**列構成を完全に一致させてある**（疎な共通
スキーマ）。そのまま連結すればミドルウェア横断の比較表になる。計測クライアントも3者とも
C++ / CentOS 7 / gcc 11 / C++17 で統一しており、クライアントランタイム側のオーバーヘッドの
差が数値に混入しないようにしている。

ただし**同じ列でも意味が異なるものがある**ため、比較する際は以下に注意する:

- **`msg_loss`の意味が3者で違う**:
  - NATS Core（TCP）— 欠損＝異常。常に失敗扱い。
  - Fast DDS の BEST_EFFORT — 欠損＝仕様通りの動作。飽和テストでは出るのが正常。
  - Aeron — フロー制御が常時有効なので、**遅いsubscriberは欠損を生まない**（バックプレッシャに
    なる）。したがって`--reliable no`以外での欠損は実際の異常。
  詳細は[`fast-dds/README.md`](fast-dds/README.md)と[`aeron/README.md`](aeron/README.md)の
  「msg_lossの読み方」。
- **スループット値の意味も違う**: Fast DDS BEST_EFFORT の無制限テストは「publisherが出せた
  速度（残りは欠落）」を測るが、Aeron の無制限テストは「**最も遅いsubscriberが処理できた
  速度**（欠落0）」を測る。同じ列に並ぶが答えている問いが違う。
- **スケーラビリティの軸が3者とも違う**: NATSは「接続数」、Fast DDSは「Participant数」、
  Aeronは「Subscriberクライアント数」。横軸を揃えたグラフにはできない。
- **公平な条件の組み合わせ**:
  - NATS Core ↔ Fast DDS BEST_EFFORT + UDPv4 ↔ Aeron UDP — 最も近い3者比較
  - 共有メモリ経路（Fast DDS `--transport shm` / Aeron `aeron:ipc`）にはNATS Coreの対応物が
    無いので、DDS↔Aeronの2者比較にしかならない
  - **Aeronは既定でメディアドライバを低レイテンシ設定（ビジースピン）にしてある。**
    素の既定同士で比べたい場合は`--driver-idle backoff`を使うこと（本環境の実測で
    p50が10倍以上変わる）

比較レポート自体はまだ作成していない（[`fast-dds/TODO.md`](fast-dds/TODO.md) #2、
[`aeron/TODO.md`](aeron/TODO.md) #2）。
