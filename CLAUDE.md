# messaging_middlewear

複数のメッセージングミドルウェアのパフォーマンス検証環境を集約するリポジトリ。See README.md
for the current subproject list.

## 構成の原則

- **ミドルウェアごとにトップレベルのサブディレクトリを持つ**（例: `nats/`、`fast-dds/`）。各
  サブディレクトリは自己完結させる — 自分専用の`docker-compose.yml`／`scripts/`／`results/`／
  `README.md`／`TODO.md`／`CLAUDE.md`を持ち、他のサブディレクトリの結果やスクリプトと混ぜない。
- **サブディレクトリ固有の規約はそのディレクトリの`CLAUDE.md`に書く**（このファイルには書かない）。
  このファイルは複数サブプロジェクトにまたがる、リポジトリ全体レベルの規約のみを扱う。
- 新しいミドルウェアの検証環境を追加する際は、既存の`nats/`の構造（サーバーはDockerコンテナ、
  ベンチマーク結果は`results/<category>/<timestamp>_<label>/`、`README.md`/`TODO.md`/`CLAUDE.md`の
  3点セット）を出発点にする — ゼロから設計し直す前に、`nats/CLAUDE.md`に記録済みの既知の落とし穴
  （Windows/Docker Desktopの仮想化オーバーヘッド、`docker cp` vs バインドマウント等、ミドルウェア
  非依存の一般的な教訓）を確認する。
