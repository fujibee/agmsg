# agmsg への貢献

*[English](CONTRIBUTING.md)*

コントリビューションを検討してくれてありがとう。agmsg は小規模なプロジェクトなので、このガイドも意図的に短くしてある。

## まず読むもの

- agmsg が何をするものか、どうインストールするかは [`README.md`](README.md) を読むこと。
- メンタルモデル(3軸ドライバ、用語、依存関係管理の考え方)は [`ARCHITECTURE.md`](ARCHITECTURE.md) を読むこと。
- 設計判断の経緯は [`docs/adr/`](docs/adr/) を眺めること — *なぜ*今の形になっているかが分かる。
- [`docs/spec/`](docs/spec/) ディレクトリには正式な契約(コントラクト)がある。ドライバを実装・拡張する際はこれを参照すること。

## バグ報告と機能要望

[`fujibee/agmsg`](https://github.com/fujibee/agmsg/issues) に issue を立てる。agmsg のバージョン、ホストエージェント(Claude Code / Codex / Gemini CLI / Antigravity)、可能なら最小の再現手順を含めること。

## プルリクエスト

1. 大きな変更はまず issue で議論する。
2. `main` からブランチを切る。PR は焦点を絞ること — 1 PR につき論理的な変更 1 つ。
3. テストスイートを実行する: `bats tests/`。
4. 周囲のコードスタイルに合わせる。Bash が主要言語であり、すべてのスクリプトの先頭で `set -euo pipefail` を使うこと。
5. ユーザーから見える変更であれば、ドキュメントも更新する。

## リリース

[`RELEASING.md`](RELEASING.md) を参照。手短に言うと: [`VERSION`](VERSION) を上げ、`./scripts/release/sync-version.sh` を実行し、コミットし、`v$(cat VERSION)` としてタグを打ち、push する。あとは CI がやってくれる。

## Architecture Decision Records

agmsg は重要な設計判断を記録するために ADR([Architecture Decision Records](https://adr.github.io/))を使っている。ADR にはコンテキスト、決定内容、検討した代替案、そしてその結果(consequences)を記録する。

### ADR を書くべきタイミング

以下のいずれかに該当する変更を提案・受け入れる場合は、新しい ADR を書くこと:

- ドライバ軸を追加・削除・置き換える、
- ドライバインターフェースや `AGMSG-DIRECTIVE` スキーマを変更する、
- ディスク上のデータレイアウトを後方互換性のない形で変更する、
- 新しい外部依存を導入する(オプションのものであっても)、
- プロジェクトの用語や命名規則を変更する、
- あるいは、それ以外でも将来のコントリビューターが理解したいと思うような判断が必要な場合。

小さなバグ修正、ドキュメント更新、依存関係のバージョンアップ、新規テストの追加には ADR は不要。

### ADR の書き方

1. [`docs/adr/template.md`](docs/adr/template.md) を `docs/adr/NNNN-short-title.md` としてコピーする。`NNNN` は次に空いている番号。
2. 各セクションを埋める。*Alternatives considered*(検討した代替案)は正直に書くこと — ADR の価値の多くは、何を却下したか、なぜ却下したかを記録している点にある。
3. PR を開く。議論は PR 上で行う。ステータスは最初 `proposed` とし、マージされたら `accepted` に変更する。
4. 後のADRが以前のADRを置き換える(supersede)場合は、元の ADR はそのまま残し、前方リンクを張る(`Status: superseded by ADR-XXXX`)。ADR は不変の履歴であり、wiki ではない。

### ドキュメント化されていない決定を見つけたとき

コード中に根拠が不明な設計上の選択を見つけた場合、それを遡って記録する ADR は歓迎されるコントリビューションである。ステータスは `accepted` とし、その挙動を最初に導入したコミットや PR を参照すること。

## ドライバの追加

バンドルされているドライバは `scripts/drivers/<axis>/<name>.sh` にある。(`scripts/` 直下の `.sh` ファイルは直接実行可能なコマンドであり、サブディレクトリは実装コードをまとめたもの。)サードパーティのプラグインドライバは `~/.agents/agmsg/plugins/<axis>/<name>/` にある。どちらも [`docs/spec/driver-interface.md`](docs/spec/driver-interface.md) にある契約を実装する必要がある。

新しいバンドルドライバには以下が揃っていることが望ましい:

- ドライバスクリプト本体、
- `tests/` 配下の bats テスト、
- そのドライバを使う際のトレードオフを説明する README セクションまたはドキュメントページ、
- ドライバのプロトコル自体を変更する場合は ADR。

## 行動規範

親切であること。善意を前提とすること。技術的な議論での意見の相違は歓迎するが、人格への攻撃は認めない。
