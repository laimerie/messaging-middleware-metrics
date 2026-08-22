# TODO — 次フェーズのバックログ

準備フェーズ（Docker上のNATS Core、`nats bench` CLIラッパー、スモークテスト）は完了・検証済み。

優先順位: ~~#4~~ → ~~#2~~ → ~~#6~~ → ~~#5~~ → ~~#3~~ → ~~#1~~
（全項目 実装完了・実測検証済み。残作業は実機Linuxサーバー上での最終実測のみ — ユーザー側で実施）

---

## 1. README最終化

**状態**: ✅ 実装済み

テスト実施手順（コマンド例・パラメータの選び方・結果の見方）を`README.md`にまとめた。
Bashへの全面書き直し（#3の「追記3」参照）に伴い、コマンド例は全て`.sh`ベースに更新済み。
実機Linuxでの実行手順を主として記述し、Windows/Git Bashでの開発時検証に関する注意点
（`jq`の別途導入、MSYSパス変換の罠）は「Testing on Windows (Git Bash)」節に切り出した。

---

## 2. テストパラメータの可変化（メッセージサイズ・秒間件数・サブスクライバー数・サブジェクト）

**状態**: ✅ 実装済み

- サイズ（`-Size`）・サブスクライバー数（`-SubClients`）・サブジェクト（`-Subject`）は元々
  `bench-throughput.ps1`等でパラメータ化済み。
- **秒間件数（レート制限）を追加。** `nats bench`には直接の「msgs/sec」指定フラグがないため、
  `--sleep=DURATION`（クライアントごとの発行間隔）に変換する`ConvertTo-NatsSleepDuration`
  ヘルパーを`Common.ps1`に追加し、`-TargetMsgsPerSec`パラメータ経由で`bench-throughput.ps1`・
  `bench-scalability.ps1`両方から使えるようにした（`sleepSeconds = clients / TargetMsgsPerSec`）。
  未指定（0）時は従来通り最大速度（飽和）モード。実測で1クライアント・目標1000msgs/secに対し
  実測788msgs/sec（`--sleep=1ms`換算）と、概ね狙い通りの近似精度を確認済み。
- マルチサブジェクトを`bench-throughput.ps1`にも追加（`-UseMultiSubject -MultiSubjectMax`）。
  **実装中に見つけたバグ**: `nats bench sub`は`--multisubjectmax`フラグを受け付けない
  （pub専用フラグ）。当初`bench-scalability.ps1`ではpub/sub両方に同じ引数セットを渡していたため、
  `-UseMultiSubject`使用時にsubが使い方エラーで即終了し、**メッセージが全件ロストしていた**
  （購読自体が成立していなかった）。pub用・sub用で引数セットを分離（subには`--multisubject`のみ）
  して修正し、実測で欠損ゼロを確認済み（`bench-throughput.ps1`: 2000/2000件、
  `bench-scalability.ps1`: 各サブスクライバーが全件受信）。
- **テスト時に判明した呼び出し方の注意点**: `[int[]]$ConnectionCounts`等の配列パラメータは、
  `powershell -File script.ps1 -ConnectionCounts 1,5`のように**別プロセスの`-File`引数として
  渡すとカンマが桁区切りとして誤解釈され`1,5`が`15`になる**（.NETの数値変換の仕様）。
  README記載の通り`.\scripts\...ps1 -ConnectionCounts 1,10,50,100`と**同一PowerShellセッション内で
  直接呼び出す**分には問題ない（スクリプト自体のバグではないが、CI等で別プロセス経由で呼ぶ場合は
  `@(1,5,10)`のように配列リテラルを明示するか`-Command`経由で呼ぶ必要がある点に注意）。

---

## 3. サーバーをまたいだテストの要否

**状態**: ✅ 実装済み（`scripts/bench-crosshost.ps1`）

**経緯（2回の訂正あり）**:
1. 当初「publisherとsubscriberが別ノードに存在する」という話からNATSクラスタ内ルーティングの
   オーバーヘッド測定を検討 → 「不要」と一度決定。
2. その後、意図は**NATSサーバーをまたぐ話ではなく、Linuxサーバー（ホスト）をまたぐ話**だったと訂正。
   NATSサーバー自体は単一ノードのままで、publisher/subscriberのプロセスが別々のLinuxホスト上で
   動作し、実際のネットワークホップを挟む構成を指す。現行の準備環境（Windows機上のDocker、
   コンテナ間通信は仮想NIC＋カーネル内ブリッジのみで物理ネットワークを経由しない）では
   この要素を再現できていない（詳細は下記「重要な注意点」）。

**実装方針（決定・実装済み）**: 追加のLinux VM等は用意せず、**Dockerで複数コンテナを立てコンテナ間を
またぐ**方式で実施した（ユーザー提案・採用）。既存の`docker/latency-tool`イメージ（TODO#4、
CentOS7/gcc11）を拡張し、nats CLIも同梱した汎用「ホストクライアント」イメージとして
publisher役・subscriber役の両方を兼務できるようにした。

**クロック同期に関する訂正**: 当初「別プロセス・別ホスト構成ではsteady_clockのクロック同期が
別途必要」と記載していたが、これは誤りだった。**同一Dockerホスト上の複数コンテナは、
別ネットワーク名前空間であっても同じLinuxカーネルの単調クロックを共有する**ため、
`std::chrono::steady_clock`はコンテナをまたいでも実際には比較可能（実測でも`msg_loss=0`の
正確な片道レイテンシが計測できることを確認済み）。クロック同期が本当に必要になるのは、
本物の別々の物理/クラウドホストに分散させる場合のみ（今回のDocker実装のスコープ外）。

**`tc netem`によるネットワーク遅延の人工注入 — 試したが、この環境では動作しないことを確認**:
同一Dockerホスト上のコンテナ間通信は仮想NIC(`veth`)＋カーネル内ブリッジで完結し物理ネットワークを
経由しないため、本番相当の遅延を再現するには`tc netem`での注入が必要という課題があった。
`--cap-add=NET_ADMIN`を付与した上で実装・実測したところ、**`tc`自体は正常に動作する
（例: `tc qdisc add ... pfifo`は成功）が、`tc qdisc add ... netem`だけが
`RTNETLINK answers: No such file or directory`で失敗する**ことを確認した。原因は
**Docker Desktop（WSL2/Hyper-Vバックエンド）に同梱されるカーネルに`sch_netem`
（netem用のqdiscカーネルモジュール）がコンパイルされていない**ため。これはコンテナ内から
修正できないホストカーネル側の制約であり、本物のLinux Dockerホスト上であれば動作する見込み
（今回は未検証）。`docker/latency-tool/entrypoint.sh`はこの失敗を**非致命的**に扱うよう実装し
（警告を出して`netem`なしで継続）、`-NetemDelayMs`は「この環境では現状効果なし」という
既知の制約として記録した上で機能自体は残してある（将来的に実Linuxホストで実行する場合に備えて）。

**使い方**:
```bash
./scripts/bench-crosshost.sh
./scripts/bench-crosshost.sh --tool nats-bench --label throughput-crosshost
./scripts/bench-crosshost.sh --netem-delay-ms 20 --label with-20ms-delay   # 現状この環境では効果なし（上記参照）
```
`--tool latency-oneway`（既定）は片道レイテンシ、`--tool nats-bench`は`nats bench`ベースの
スループットをそれぞれpublisher役・subscriber役を別コンテナに分けて計測する。結果は
新カテゴリ`results\crosshost\`に保存。

**実装中に見つけたバグ（修正済み）**: `Start-Job`のスクリプトブロック内で`docker compose`を
実行する際、作業ディレクトリを明示的に`Set-Location`していなかったため、バックグラウンドの
subscriber役ジョブが`docker-compose.yml`を見つけられずサイレントに失敗し、結果として
`msg_loss`が全損扱いになっていた（`Start-Job`は別ランスペースで動き、呼び出し元の
`Push-Location`を引き継がないという、`CLAUDE.md`に既に記載していた教訓を今回見落として
再発させてしまった。ジョブ内で明示的に`Set-Location $ProjectRoot`するよう修正）。

**実測結果**: 同一プロセス内計測（`bench-latency-oneway.ps1`、p50≈2.1ms）と比べ、別コンテナに
分けた`bench-crosshost.ps1`（p50≈3.1〜3.3ms）の方がやや高いレイテンシが出た。これは別プロセス・
別コンテナ・別NATS接続を経由することによる現実的なオーバーヘッド増加であり、想定通りの挙動。

**追記: リモートLinux実機での実行に備えた`-v`バインドマウント廃止**
（ユーザーから「会社のWindows PCからSSHでLinuxサーバーに接続して実機検証したい」との要望を受けて対応）。
`docker context`でDockerデーモンの向き先をリモートのLinux実機に変更すれば、コンテナ自体は
Docker Desktop/WSL2の仮想化層を経由せず本物のLinuxカーネル上で直接動く。ただし、当初
`docker compose run -v "${run}:/out" ...`という**バインドマウント**で結果を取得していたため、
これは**Dockerデーモン側のファイルシステムを見に行く**という重大な問題があった。デーモンが
リモートLinuxホストになった瞬間、Windows側の`$run`パスはリモート側に存在せず、結果ファイルが
一切回収できなくなる。

**対処（実装済み）**: `scripts/Common.ps1`に`Invoke-DockerRunAndCopyOut`を追加し、
`docker compose run --name <生成名>`（`--rm`なし・バインドマウントなし）でコンテナを実行 →
`docker cp <コンテナ名>:/out/. <ローカル出力先>`で結果を明示的にコピー → `docker rm`で
コンテナを削除、という方式に統一した。`docker cp`はデーモンがローカル・リモートいずれでも
同じように動作するため、この方式に統一することでリモートLinux実機でも結果を確実に回収できる。
`bench-latency-oneway.ps1`・`bench-crosshost.ps1`（両ツール分岐）をこの方式に更新済み。

この過程で見つけた副次的なバグ2件（修正済み）:
1. **`/out`ディレクトリが存在しない**: バインドマウント時はDockerが自動的に`/out`
   マウントポイントを作成していたため気づかなかったが、バインドマウントをやめると
   コンテナ内に`/out`が存在せず、C++ツールの`std::ofstream`が**エラーを出さずサイレントに
   書き込み失敗**していた（結果、標準出力の集計値は正しく表示されるのに`result.json`が
   作られない、という分かりにくい壊れ方をした）。`entrypoint.sh`に`mkdir -p /out`を追加して解決。
2. **同じ「子プロセス出力が戻り値に混入」バグの再発**: `Invoke-DockerRunAndCopyOut`内の
   `docker compose run`・`docker cp`の出力を素通りさせたまま`return $exitCode`すると、
   TODO#5で一度直したのと**全く同じクラスのバグ**（標準出力＋戻り値が配列としてまとめられて
   しまう）が再発した。`| Out-Host`で両方の出力をコンソールへ直接流すことで解決。

**リモートLinux実機への接続方法**（会社PC等で実施する想定、メモとして記録）:
```powershell
docker context create linux-bench --docker "host=ssh://user@<Linuxホストのアドレス>"
docker context use linux-bench
# 以降は今まで通り .\scripts\bench-latency-oneway.ps1 等をそのまま実行するだけでよい
```
なお`tc netem`（TODO#3で「Docker Desktop固有のカーネル制約で動作しない」と記録した機能）は、
本物のLinuxカーネルであれば`sch_netem`モジュールが入っていることが多く、動作する可能性が高い
（未検証、リモートLinux実機での実行時に要確認）。

**追記2: `docker context`より単純な代替案 — Linuxサーバー上でスクリプトごとネイティブ実行**

ユーザーから「会社のLinuxサーバーには元々Dockerが入っているので、`docker context`のような
SSH越しの間接構成にせず、Linuxサーバーに直接ログインしてそこで`docker compose`を実行すれば
いいのでは」という、より単純な指摘があった。これは正しく、`docker context`経由よりも構成が
シンプルでビルドコンテキストのネットワーク転送も不要になる。

ただし本プロジェクトは全て`.ps1`（PowerShell）スクリプトなので、Linuxサーバー上でそのまま
活用するには**PowerShell Core（`pwsh`、クロスプラットフォーム対応）**をLinux側に入れる必要がある。
その上で判明した問題: **既存スクリプトはWindows流の`\`（バックスラッシュ）でパスを直接文字列連結
していた箇所が多数あり、Linux上のPowerShell Coreではこれが正しく解釈されずそのままでは動かない**
（`\`はLinuxではパス区切りとして特別扱いされず、ファイル名の一部として扱われてしまう）。

**対応（実装済み・ユーザー承認済み「linuxに統一していいよ」）**: `scripts/`配下の全`.ps1`ファイルで
`\`を`/`に統一した（`/`はWindows・Linux両方で正しく解釈される）。この過程で以下も追加で発見・修正:
- `Common.ps1`の`Add-RunIndexEntry`: `TrimStart('\')`が`/`区切りに対応していなかった箇所を
  `TrimStart('\', '/')`＋`-replace '\\', '/'`で両対応に修正
- `run-all-benchmarks.ps1`の`Invoke-ScriptIsolated`: 子プロセス起動に`powershell.exe`を
  決め打ちしていた（Linuxには存在せず、Linux版は`pwsh`という別名）。
  `(Get-Process -Id $PID).Path`で実行中のシェル自身の実体パスを動的取得する方式に変更し解決
- `start-server.ps1`: `Get-NetTCPConnection`（Windows専用コマンドレット、`NetTCPIP`モジュール）が
  Linux上のPowerShell Coreには存在せず、ガードなしで呼ぶと`$ErrorActionPreference="Stop"`下で
  スクリプトごと停止してしまう問題を発見。`Get-Command ... -ErrorAction SilentlyContinue`で
  事前に存在確認するガードを追加
- なお`install-nats-cli.ps1`（`winget`使用）は意図的に対応対象外とした。Windows専用の
  インストール手段であり、Linux側では別途そのディストリのパッケージマネージャ等でnats CLIを
  導入する必要がある（これは「統一」すべき差異ではなく、プラットフォームごとに異なって当然の部分）

修正後、Windows上で`smoke-test.ps1`・`bench-throughput.ps1`・`bench-latency-oneway.ps1`・
`bench-crosshost.ps1`・`run-all-benchmarks.ps1`を再実行し、全て`msg_loss=0`で従来通り動作することを
回帰確認済み（`/`はWindows上でも正しく解釈されるため、Windows側の動作に影響がないことも確認できた）。

**副産物**: `docker-compose.yml`の`context: .`がプロジェクトルート全体（`results/`含む）を
毎回tarで転送する構成だったため、`.dockerignore`を追加して`results/`・`scripts/`・`*.md`等を除外。
リモートLinux実機や大量の過去結果が溜まった状態でのビルド転送量を削減（実測でビルドコンテキストが
289Bまで縮小することを確認）。

**追記3: PowerShell自体を廃止し、ネイティブBash（`.sh`）へ全面書き直し**

ユーザーから「コマンド自体もLinux専用でいい」「このセッションでもWindowsコマンド（PowerShellツール）
を使うのをやめよう」との明確な指示を受け、上記「追記2」の`pwsh`ポータビリティ対応（`\`→`/`統一等）
を土台としつつ、**PowerShell自体を完全に廃止しネイティブBashスクリプトへ全面書き直した**。
`scripts/*.ps1`（11ファイル）を全て`scripts/*.sh`に置き換え、`Common.ps1`は`common.sh`に、
`scenarios.json`のパラメータキーもkebab-caseのフラグ名（例: `target-msgs-per-sec`）に統一。

この書き直しは単なる構文置換ではなく、CLAUDE.mdの「Why Bash, not PowerShell」に詳述の通り、
PowerShell特有の挙動（`Start-Job`の別ランスペース、子スクリプト`exit`のプロセス巻き込み、
ネイティブコマンド出力の戻り値混入、配列パラメータのプロセス境界カンマ誤解釈など）が
**bashでは構造的に発生しない**ため、実装がむしろ単純化された（例:
`run-all-benchmarks.sh`は`bash "$script" "$@"`で子プロセスとして直接呼ぶだけで
`Invoke-ScriptIsolated`相当の複雑な回避策が丸ごと不要になった）。

書き直した全11スクリプトをWindows上のGit Bashから実機検証し（`smoke-test.sh`・
`bench-throughput.sh`・`bench-scalability.sh`・`bench-latency.sh`（RTT）・
`bench-latency-oneway.sh`・`bench-crosshost.sh`（`--tool latency-oneway`・`--tool nats-bench`
両方）・`run-all-benchmarks.sh`）、全て`msg_loss=0`で正常動作することを確認済み。

**検証中に発見したGit Bash固有の問題（Bash書き直し自体のバグではない）**: `bench-latency-oneway.sh`
実行時、標準出力の集計（`msgs_sent=... msg_loss=0`）は正しく表示されるのに`result.json`/
`oneway.csv`が回収されないという、TODO#3の「追記」で一度解決したはずの症状が再発した。
調査の結果、原因はスクリプト側のバグではなく**Git BashのMSYSレイヤーが`docker compose run ...
latency_oneway --out /out`の`/out`という引数を「Windowsホスト上の絶対パスらしきもの」と誤認識し、
勝手にWindowsパスへ書き換えてコンテナに渡していた**ことだった（`/out`はコンテナ*内部*で解釈される
べき文字列であり、Windowsパスではない）。この結果C++ツールの`ofstream`がエラーなくサイレントに
書き込み失敗する。`MSYS_NO_PATHCONV=1`で全変換を止めると今度は`docker cp`の宛先（Windows実パス）側の
変換が必要な箇所まで壊れるため、`MSYS2_ARG_CONV_EXCL="/out"`で**`/out`から始まる引数だけ**変換除外する
方式で両立させ、解決を確認した（詳細はREADME.md「Testing on Windows (Git Bash)」参照）。
**実機Linux上ではMSYSレイヤー自体が存在しないためこの問題は発生しない** — 純粋にWindows上での
開発時検証の副作用であり、スクリプトのコード自体には一切手を入れていない。

---

## 4. レイテンシ計測はpublisher→subscriberの片道時間か

**状態**: ✅ 実装済み（`tools/latency_oneway/` + `scripts/bench-latency-oneway.ps1`）

**経緯**: 現状の`bench-latency.ps1`は`nats bench service serve`/`service request`を使っており、
これは**往復時間（RTT）**を計測している。ご質問の「片道時間」とは異なる。
`nats bench pub`/`nats bench sub`のCSV出力にはメッセージ単位のタイムスタンプがなく、
公式CLIだけでは片道レイテンシを直接測れないことも`--help`で確認済み（集計値のみ、per-messageデータなし）。

**実装言語について**: 当初Pythonを想定していたが、**本番実装がC++であるため、計測クライアントも
C++で実装する**方針に変更。Pythonを使った場合、GIL・インタプリタオーバーヘッド、asyncioの
イベントループスケジューリングによるジッター、GCの一時停止など、C++本番環境には存在しない
オーバーヘッドが計測値に混入するリスクがある。NATS Core自体のレイテンシはサブミリ秒〜低ミリ秒
オーダーであるため、Pythonのオーバーヘッドが同程度かそれ以上になり得て、「NATSのレイテンシ」ではなく
「NATS＋Pythonランタイムのオーバーヘッド」を測ってしまう懸念があった。C++（公式Cクライアント
`nats.c`をベースに使用）にすることで本番相当の実行特性で計測できる。

**実装方針（案）**:
- 公式NATS Cクライアントライブラリ [`nats.c`](https://github.com/nats-io/nats.c) を、下記の
  CentOS 7 / gcc 11 のDockerコンテナ内でCMakeを使ってビルドし、それをC++からリンクする形で
  `tools/latency_oneway`（新規、C++）を実装する。Windows上には一切ビルド環境を構築しない
  （後述の「ビルド環境（決定）」を参照）。
- publisher役・subscriber役を同一プロセス内の2スレッド、または2プロセス（要検討）として実装し、
  publisherがメッセージペイロードに高精度送信時刻（`std::chrono::steady_clock`等）を埋め込み、
  subscriber側で受信時刻との差分を計算する。
- ローカル実行時（同一Windowsホスト上のDocker）は送受信間のクロック同期問題は発生しない。
  ただし#3のLinuxホストをまたぐ検証で**別プロセス・別ホスト（別コンテナ含む）**構成にする場合は
  クロック同期の前提が崩れる点に注意（`steady_clock`はホスト単位のため、ホストをまたぐと
  そのままでは使えない。NTP同期や、双方の`steady_clock`オフセットを別途キャリブレーションする等の
  対処が必要になる）。
- 生の片道レイテンシ（マイクロ秒/ナノ秒単位、メッセージごと）をCSVに保存し、そこから正確に
  p50/p90/p95/p99を算出する（#6の出力フォーマットと連携）。
- 既存のRTT計測（`bench-latency.ps1`）は「公式CLIのみで完結する簡易チェック用」として残す。

**ビルド環境（決定・実装済み）**: Windows上に直接C++ビルド環境は構築しない。**本番相当のDockerコンテナ内で
ビルド・実行する**（Windows側の環境整備は不要）。本番環境に合わせ以下で統一:
- OS: **CentOS 7**
- コンパイラ: **gcc 11**（`devtoolset-11`経由）
- C++標準: **C++17**

**実装時に踏んだ落とし穴（今後の参考用）**:
- CentOS 7標準リポジトリのgccは4.8系のため`devtoolset-11`（Software Collections）が必要。
  CentOS 7は既にEOLで`mirrorlist.centos.org`が停止済みのため、ベースリポジトリ・SCLリポジトリ
  両方を`vault.centos.org`参照に`sed`で書き換える必要がある。**SCLoリポジトリの`.repo`ファイルは
  `#baseurl=`と`# baseurl=`（スペース有無）が混在**しており、素朴な正規表現だと片方しか
  マッチしないので`[[:space:]]*`で吸収する必要があった。
- CentOS 7標準の`cmake`は2.8系で古すぎるため、CMake公式バイナリリリースを直接展開して使用。
- `nats.c`のCMakeパッケージは**READMEの記載（`find_package(NATS)`）と実際が異なり、
  実際にエクスポートされる名前は`cnats`**（`find_package(cnats REQUIRED)`、
  ターゲット名`cnats::nats_static`）。加えて`cnats::nats_static`の依存解決に
  `find_package(Threads REQUIRED)`を先に呼んでおく必要がある（呼ばないと
  `Threads::Threads`が見つからずCMake Generateが失敗する）。

**使い方**:
```bash
./scripts/bench-latency-oneway.sh
./scripts/bench-latency-oneway.sh --target-msgs-per-sec 5000 --duration-sec 30 --label rate5000
./scripts/bench-latency-oneway.sh --size 512 --label size512
```

**実測で分かった重要な注意点（バースト時のキューイング遅延）→ インターフェース自体を再設計**:
当初`-Msgs`（合計件数、既定100000）＋任意の`-TargetMsgsPerSec`（既定0=無制限最大速度）という
インターフェースだった。無制限最大速度で送ると、レイテンシがメッセージ順に単調増加するパターンが
実測で確認できた（1000件で先頭は約2.3ms、末尾は約5.3msまで増加）。これは「NATSの転送遅延」ではなく、
**送信側が受信側の処理速度を上回るペースでバースト送信した結果、受信キューに滞留する待ち時間
（キューイング遅延）**が支配的になっているためと判明。

この問題は「レイテンシ計測において『一気に何件投げるか』という発想自体がそもそも無意味で、
『秒間何件投げるか』を主軸にすべき」というユーザー指摘を受けて、**ツールのインターフェースを
根本的に再設計**して解決した:
- `--msgs`（合計件数を直接指定）を**廃止**
- `--rate`（秒間件数）と`--duration-sec`（継続時間、既定10秒）を**両方必須**の主軸パラメータとし、
  合計件数は`round(rate × duration)`で内部算出
- `--rate`未指定・0以下は明確なエラーで拒否（「無制限バーストモード」という概念自体をなくした）
- ラッパースクリプト側（`bench-latency-oneway.sh`・`bench-crosshost.sh`）も`--target-msgs-per-sec`・
  `--duration-sec`ベースに追随。`bench-crosshost.sh`は`--tool nats-bench`（スループット計測、
  無制限速度=飽和テストが意味を持つ）との共存が必要なため、`--tool latency-oneway`のときのみ
  `--target-msgs-per-sec`未指定時に1000/sへ自動フォールバックする形にした

再設計後、`-TargetMsgsPerSec 500 -DurationSec 5`で実測したところ、`oneway.csv`のレイテンシが
単調増加するパターンは解消され、実行全体を通して安定した揺らぎ（急上昇→高止まりではなく
ランダムなばらつき）になることを確認済み。
なお絶対値自体（数ms）は`README.md`の「実行環境の限界」で述べたWindows/Docker Desktop環境の
オーバーヘッドを含んでいる点にも注意。

---

## 5. テスト実施をスクリプトに集約

**状態**: ✅ 実装済み（`scripts/run-all-benchmarks.ps1` + `scripts/scenarios.json`）

`scripts/scenarios.json`にシナリオ定義（category/script/label/params）を外出しし、
`scripts/run-all-benchmarks.ps1`がこれを読み込んでsmoke-test→各シナリオの順に一括実行する。
シナリオの追加・変更はJSON編集のみでよく、コード変更は不要。デフォルトのシナリオは
throughput（baseline/大メッセージ/複数クライアント）・latency（RTT簡易チェック＋片道レート制限）・
scalability（接続数スイープ）を一通りカバー。

**使い方**:
```bash
./scripts/run-all-benchmarks.sh
./scripts/run-all-benchmarks.sh --skip-smoke
./scripts/run-all-benchmarks.sh --stop-on-failure
```

**実装中に見つけた重大なバグ2件（修正済み）**:
1. **`exit`によるオーケストレーター巻き込み終了。** `smoke-test.ps1`や`bench-latency-oneway.ps1`は
   失敗時に`exit`を呼ぶが、これを同一プロセス内で`&`呼び出しすると（PowerShellの仕様上）
   `exit`はスクリプトのスコープではなく**プロセス全体**を終了させてしまい、1シナリオの失敗で
   オーケストレーター全体が即死する。各シナリオを`powershell.exe`の**別プロセス**として起動する
   ことで`exit`の影響範囲を子プロセスに閉じ込め、`$LASTEXITCODE`で正常に結果を受け取れるようにした。
2. **子プロセスの標準出力が戻り値に混入し`$exitCode`が壊れる。** 別プロセス化した`nats bench`等の
   標準出力を素通りさせたまま関数内で`return $LASTEXITCODE`すると、PowerShellはその標準出力
   （テキスト全行）と戻り値の整数を**まとめて1つの配列として返してしまう**ため、呼び出し側の
   `$exitCode`が「大量のテキスト+整数」の配列になり、`-ne 0`判定が常に真（失敗扱い）になっていた。
   `| Out-Host`で子プロセス出力をコンソールへ直接流し、パイプラインを汚さないようにして解決。
3. （軽微）scenarios.jsonの`label`はシナリオのトップレベルフィールドであり`params`の外にあるため、
   素朴に`params`だけを引数化すると`-Label`が渡されず全run名が`_default`になっていた。
   `-Label`を明示的に組み込んで解決。この過程で`bench-scalability.ps1`に元々`-Label`パラメータが
   存在しない（内部で固定文字列"sweep"）ことにも気づき、他スクリプトと合わせて`-Label`
   パラメータ（既定値"sweep"）を追加した。

**本番シナリオでの実走行で発覚した追加バグ2件（修正済み）**: 実際に`scenarios.json`をフル実行したところ、
scalabilityスイープの`clients=50`/`100`で`nats bench pub`が全クライアント`flushing: nats: timeout`
エラーで失敗するという、このWindows/Docker Desktop環境の実際のスケーラビリティ限界（10〜50の間）を
実測で発見した（詳細は#3のスコープ外の追加知見として記録: 当初コメントは「数千接続まで」としていたが
実際はそれよりずっと低いことが判明。既定の`-ConnectionCounts`は安全な`1,5,10,25`に変更し、
`scenarios.json`も追随）。この過程でさらに2件のスクリプト側バグを発見・修正:
4. **`msg_loss`の偽陰性。** `nats bench pub`自体が失敗してpub.csvが空だと、`期待値 = pub実測合計 ×
   subクライアント数`の計算式では期待値も0になり、**実際は全滅しているのに`msg_loss=0`と表示されて
   しまう**バグがあった。期待値の算出をpubの実測値ではなく「要求したパラメータ値」（`$Msgs`/
   `$totalMsgs`）基準に変更して解決（`bench-throughput.ps1`・`bench-scalability.ps1`共通）。
5. **サブスクライバーのハング。** publisherが失敗すると、`nats bench sub`は届くはずのないメッセージを
   永遠に待ち続け、`Receive-Job -Wait`（タイムアウトなし）もそれに引きずられて**オーケストレーター
   全体が無期限に停止**してしまうことが、実際に`clients=100`のフル実行で発生し判明した。
   `Common.ps1`に`Receive-JobSafely`（`Wait-Job -Timeout`＋タイムアウト時は`Stop-Job`）を追加し、
   両スクリプトから利用するよう修正。あわせて`nats bench pub`の終了コードも明示チェックし、
   失敗時はスクリプト自体が非ゼロ終了するようにした（以前はpubが失敗してもスクリプトは
   「成功」扱いのまま先へ進んでいた）。

修正後、`scripts/scenarios.json`（既定シナリオ6件、smoke-test込み）をバックグラウンドでフル実行し、
**全シナリオが`msg_loss=0`で正常完了**することを実測確認済み（`results\run-index.csv`に10行、
scalabilityは`clients-1/5/10/25`まで全て成功）。

---

## 6. テスト結果の出力フォーマットの定義

**状態**: ✅ 実装済み

`Common.ps1`に`ConvertFrom-NatsBenchCsv`（`#`ヘッダー除去つきCSVパース）・`Get-NatsBenchAggregate`
（複数クライアント行の集計: 合計msgs/bytes、最大durationでの集計msgs/sec・MB/sec）・`Save-Result`
（`result.json`書き込み＋`run-index.csv`への1行追記）・`Add-RunIndexEntry`を追加し、
`bench-throughput.ps1`・`bench-scalability.ps1`・`bench-latency.ps1`（RTT）・
`bench-latency-oneway.ps1`（片道、C++側が書いた`result.json`を読み戻して追記のみ）全てから
呼び出すように実装済み。`msg_loss`はsub側が「独立した購読者ごとにpublish全件のコピーを受信する」
というfan-out特性（実測で確認済み: 5クライアントなら5人全員が送信全件を受信）を踏まえ、
`期待受信数 = pub合計 × subクライアント数` を基準に算出。実測でthroughput/scalability/latency
（RTT・片道）いずれも`msg_loss=0`で意図通りのJSON/CSVが出力されることを確認済み。

現状はrunごとに `pub.csv`/`sub.csv`/`*.summary.txt`/`meta.json` を保存するのみで、
run間の比較がしやすい正規化されたメトリクスの置き場がない。

**実装方針（案）**:
- 各runフォルダに `result.json` を追加する（`meta.json`の実行パラメータに加え、パース済みの
  主要指標: `msgs_per_sec`, `mb_per_sec`, `avg_latency_us`, `p50`/`p90`/`p95`/`p99`
  ［#4の片道レイテンシスクリプトの場合のみ算出可］等）。
- `results\run-index.csv`（または JSON Lines）を「全run横断の一覧サマリ」として定義し、
  #5のオーケストレーターが1run=1行で追記していく。列例: timestamp, category, label, params(要約),
  msgs_per_sec, mb_per_sec, p50_latency_us, p99_latency_us, run_dir。
- `nats bench --csv`出力のヘッダー行が`#`始まりで`Import-Csv`にスキップされてしまう既知の落とし穴
  （`CLAUDE.md`に記載済み、`smoke-test.ps1`で実際に踏んで修正済み）を踏まえ、
  `ConvertFrom-Csv` + ヘッダー行の`#`除去パターンを`Common.ps1`に共通ヘルパーとして切り出す
  （現状はsmoke-test.ps1にしかこのロジックがない）。

### 出力例（イメージ）

実際に取得済みのスモークテスト結果（`results\smoke\..\pub.csv` / `sub.csv` / `meta.json`）を元にした、
`result.json`・`run-index.csv`の具体例。`pub.csv`は実際には以下の列を持つことを確認済み
（`sub.csv`にはレイテンシ列がなく、集計値のみ＝#4で片道レイテンシを別途測る理由の裏付け）:

```
#RunID,ClientID,MsgCount,MsgBytes,MsgsPerSec,BytesPerSec,DurationSecs,MinLatencyMicroSecs,
AvgLatencyMicroSecs,MaxLatencyMicroSecs,P50LatencyMicroSecs,P90LatencyMicroSecs,
P99LatencyMicroSecs,P99.9LatencyMicroSecs,StdDevLatencyMicroSecs   ← pub.csv
#RunID,ClientID,MsgCount,MsgBytes,MsgsPerSec,BytesPerSec,DurationSecs   ← sub.csv（レイテンシ列なし）
```

**① `results\throughput\<timestamp>_<label>\result.json`**（`bench-throughput.ps1`用）
```json
{
  "run_id": "20260822-153000_size128-1x1",
  "category": "throughput",
  "label": "size128-1x1",
  "timestamp": "2026-08-22T15:30:00+09:00",
  "params": {
    "subject": "BENCH.THROUGHPUT",
    "msgs": 1000000,
    "size": 128,
    "pubClients": 1,
    "subClients": 1
  },
  "environment": {
    "nats_cli": "0.4.0",
    "server_id": "NCA2PSDGHBRS3Y3QNNLRREXDTAAYXNQM6TDCM5EJFHTMLYE4QYRIC4BX",
    "server_ver": "2.11.17",
    "image": "nats:2.11-alpine"
  },
  "metrics": {
    "pub": { "msgs_per_sec": 812345, "mb_per_sec": 99.2, "duration_sec": 1.231 },
    "sub": { "msgs_per_sec": 805112, "mb_per_sec": 98.3, "duration_sec": 1.242 },
    "msg_loss": 0
  }
}
```
`msg_loss = params.msgs - sub.msgs_per_sec×sub.duration_sec`（≒`sub.csv`の`MsgCount`との差分）で算出。

**② `results\latency\<timestamp>_<label>\result.json`**（#4の片道レイテンシC++ツール用・将来）
```json
{
  "run_id": "20260822-160000_size128-rate1000",
  "category": "latency",
  "label": "size128-rate1000",
  "timestamp": "2026-08-22T16:00:00+09:00",
  "params": {
    "subject": "BENCH.LATENCY.ONEWAY",
    "msgs": 100000,
    "size": 128,
    "targetMsgsPerSec": 1000
  },
  "environment": {
    "latency_tool_version": "latency_oneway 0.1.0 (gcc 11, CentOS 7, C++17)",
    "server_id": "NCA2PSDGHBRS3Y3QNNLRREXDTAAYXNQM6TDCM5EJFHTMLYE4QYRIC4BX",
    "server_ver": "2.11.17"
  },
  "metrics": {
    "latency_us": {
      "min": 42.1, "avg": 68.4, "p50": 61.0, "p90": 95.2,
      "p95": 110.7, "p99": 210.5, "p99_9": 480.2, "max": 900.1, "stddev": 25.3
    },
    "msgs_sent": 100000,
    "msgs_received": 100000,
    "msg_loss": 0
  }
}
```
片道レイテンシはp50/p90/p99だけでなく`p95`も生サンプルCSVから算出可能（nats bench CLIのRTT計測には
p95が無いという#4の元々の課題を、自作ツールなら解消できる）。

**③ `results\scalability\<timestamp>_sweep\clients-<N>\result.json`**（throughputと同スキーマ + `clients`）
throughputの①と同じ構造に`"params.clients": 100`のように接続数を1フィールド追加するのみ。
`bench-scalability.ps1`は各`clients-<N>\`フォルダごとにこの形式で1件出力する。

**④ `results\run-index.csv`**（全run横断の一覧サマリ、#5のオーケストレーターが1run=1行で追記）
```
run_id,category,label,timestamp,params_summary,pub_msgs_per_sec,sub_msgs_per_sec,p50_latency_us,p99_latency_us,msg_loss,run_dir
20260822-153000_size128-1x1,throughput,size128-1x1,2026-08-22T15:30:00+09:00,"size=128;pub=1;sub=1",812345,805112,,,0,results\throughput\20260822-153000_size128-1x1
20260822-160000_size128-rate1000,latency,size128-rate1000,2026-08-22T16:00:00+09:00,"size=128;rate=1000/s",,,61.0,210.5,0,results\latency\20260822-160000_size128-rate1000
20260822-170000_clients-100,scalability,clients-100,2026-08-22T17:00:00+09:00,"size=128;clients=100",790012,781344,,,0,results\scalability\20260822-170000_sweep\clients-100
```
スループット系（throughput/scalability）は`p50_latency_us`/`p99_latency_us`列を空欄にし、
レイテンシ系は`pub_msgs_per_sec`/`sub_msgs_per_sec`を空欄にする＝1つのCSVで全カテゴリを横断比較できる
「疎な共通スキーマ」とする。
