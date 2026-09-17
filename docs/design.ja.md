# agmsg — 設計とアーキテクチャ

*[English](design.md)*

コントリビューターおよびメンテナー向けの開発者ドキュメント。

## アイデンティティモデル

エージェントは `(name, team)` によって識別される。プロジェクトパスとエージェントタイプ（claude-code, codex, gemini）はメタデータであり、アイデンティティと合わせて保存される参照情報だが、アイデンティティそのものの一部ではない。

- 同じ名前のエージェントを複数のプロジェクトから登録できる
- `whoami.sh` はプロジェクトパスとタイプからアイデンティティを提案するが、ユーザーは任意の名前を選択できる
- 進行中のアイデンティティ再設計については [#15](https://github.com/fujibee/agmsg/issues/15) を参照

## データストレージ

### メッセージ — SQLite

`~/.agents/skills/<cmd>/db/messages.db`

- パスは `scripts/lib/storage.sh`（`agmsg_db_path`）によって解決される。ストレージディレクトリは `AGMSG_STORAGE_PATH`（env が組み込みデフォルトより優先）で上書き可能。SQLite ストアのみに適用される。
- 並行アクセス（複数リーダー + 1 ライター）のための WAL ジャーナルモード
- スキーマ:
  ```sql
  CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    team TEXT NOT NULL,
    from_agent TEXT NOT NULL,
    to_agent TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    read_at TEXT
  );
  ```
- 未読クエリ用に `(team, to_agent, read_at)`、履歴用に `(team, created_at)` にインデックスを付与

### チーム設定 — JSON

`~/.agents/skills/<cmd>/teams/<team>/config.json`

```json
{
  "name": "myteam",
  "agents": {
    "alice": { "type": "claude-code", "project": "/path/to/project" }
  },
  "created_at": "2026-01-01T00:00:00Z"
}
```

sqlite3 の JSON1 関数を介して操作される（python3 依存なし）。

### ユーザー設定 — YAML

`~/.agents/skills/<cmd>/db/config.yaml`

```yaml
# agmsg configuration
hook:
  check_interval: 60  # seconds between inbox checks
```

`config.sh` が awk を使って読み書きする。ドット区切りキー（`hook.check_interval`）をサポート。

## フックシステム

自動メッセージ検出は、各応答の後に新着メッセージをチェックするためにホストエージェントのフック機構を利用する。

### フロー

```
Agent responds → Stop hook fires → check-inbox.sh runs
  ├─ Cooldown active? → skip (Codex: JSON systemMessage)
  ├─ No unread messages? → silent (Codex: JSON systemMessage)
  └─ Unread messages found:
       1. Build notification text
       2. Mark messages as read_at
       3. Return JSON { "decision": "block", "reason": "..." }
       4. Agent sees messages in context and continues
```

### クールダウン

マーカーファイル（`run/.lastcheck-<agent>`）が最終チェック時刻を追跡する。`hook.check_interval`（デフォルト 60 秒）で設定可能。これは run ディレクトリ（フックのランタイム状態）に置かれ、メッセージストアには含まれないため、`AGMSG_STORAGE_PATH` の影響を受けない。

### Claude Code と Codex の比較

| 項目 | Claude Code | Codex |
|---|---|---|
| フック設定 | `.claude/settings.local.json` | `.codex/hooks.json` |
| 機能フラグ | 不要 | `config.toml` の `codex_hooks = true` |
| サイレント出力 | 出力なしで exit 0 | JSON `{ "continue": true }` |
| 新着メッセージ | `decision: "block"` | `decision: "block"` |
| UI 表示ラベル | "Stop hook error:"（[#2](https://github.com/fujibee/agmsg/issues/2)） | "warning:"（[#2](https://github.com/fujibee/agmsg/issues/2)） |

### プロジェクト解決（[#92](https://github.com/fujibee/agmsg/issues/92)）

スラッシュコマンドはプロジェクトキーとして `"$(pwd)"` を渡す。ユーザーがセッションの実体が存在するプロジェクトのサブディレクトリや git worktree に `cd` すると、その pwd は登録済みプロジェクトと一致しなくなり、ルックアップが外れてサブディレクトリ用の幽霊レコードが作られてしまう。`lib/resolve-project.sh` は、安定した `session_id` を必要としない（Codex はそれを公開していない）3 つのシグナルを使って本当のルートを復元する。

1. **プロセス単位のマーカー。** SessionStart 時に、`proj.<agent_pid>.project` が正式なプロジェクト（フックに組み込まれた `$2`）を、包含するエージェントプロセスの PID をキーとして記録する。スラッシュコマンドはその同じプロセスの子として実行されるため、ppid チェーンを遡ってエージェント PID にたどり着き、マーカーを読み戻す。信頼するかどうかは、その PID がまだ生きているエージェントプロセスであること（リサイクルガード）に依存し、古いマーカーは SessionStart/SessionEnd で GC される。**Claude Code の monitor/both のみ** — Codex は monitor モードを拒否する（Monitor ツールがない）ため `session-start.sh` をインストールせず、マーカーも書き込まない。Codex はシグナル 2〜3 に依存する。
2. **祖先ウォーク。** マーカーが見つからない場合、そのタイプについて登録済みプロジェクトである pwd の最も近い祖先が採用される。git に依存しないため、登録済みプロジェクトの*配下*にあるネストしたサブディレクトリや worktree を、cc と Codex の両方でカバーできる。
3. **git 共通ディレクトリ。** それも失敗した場合、pwd の git リポジトリの登録済みメインチェックアウト（`git rev-parse --git-common-dir` 経由）を使う。これにより、祖先ウォークでは到達できない*兄弟*の worktree を復元できる。レジストリと突き合わせて検証されるため、登録がアンブレラの親ディレクトリ上にある場合は採用を見送る。

順序: マーカー → 祖先 → git 共通ディレクトリ → pwd（変更なしのフォールバック）。
解決処理はエージェント主導のエントリポイント（`whoami.sh`、`actas-claim.sh`、`join.sh`、`reset.sh`、そして同じ解決済みプロジェクトを追跡しなければならない購読を持つ `watch.sh`）から適用される。直接のシェル呼び出しと、`spawn.sh` の明示的な `--project` オプションは `AGMSG_RESOLVE_PROJECT=0` によってこれをオプトアウトする。
`identities.sh` は純粋なルックアップのままであり、その呼び出し元はすでに解決済みのパスを渡す。

## スクリプト

| スクリプト | 用途 |
|---|---|
| `internal/init-db.sh` | スキーマ付き SQLite データベースを作成 |
| `send.sh` | データベースにメッセージを挿入 |
| `inbox.sh` | 未読メッセージを表示し既読にする |
| `history.sh` | メッセージ履歴を表示（新しい順に取得し、古い順に表示） |
| `join.sh` | エージェントをチームに追加（必要ならチームを作成） |
| `leave.sh` | エージェントをチームから削除（チームが空になれば削除） |
| `team.sh` | チームメンバーを一覧表示 |
| `whoami.sh` | プロジェクトパスとタイプでエージェントを識別 |
| `rename.sh` | 設定とメッセージ履歴内でエージェント名を変更 |
| `check-inbox.sh` | フックのエントリポイント — クールダウン、チェック、通知 |
| `config.sh` | ユーザー設定（YAML）の読み書き |

上記のスクリプトはすべて **core** 依存階層に属する: `bash` と `sqlite3` のみで、python3 は不要。全体像は下記の「依存関係」を参照 — E2EE（`key.sh`）と remote（`remote.sh`、`team-list.sh`）は、その機能を使うインストールにのみ、それぞれ追加のバイナリを要求する。

## インストールレイアウト

```
~/.agents/skills/<cmd>/
├── SKILL.md              # Read by Codex (generated from cmd.codex.md template)
├── agents/
│   └── openai.yaml       # Codex metadata
├── scripts/              # All shell scripts
├── templates/            # Command templates (cmd.claude-code.md, cmd.codex.md)
├── db/
│   ├── messages.db       # SQLite message store (relocatable via AGMSG_STORAGE_PATH)
│   └── config.yaml       # User configuration
├── run/                  # Hook/watcher runtime state
│   ├── watch.<sid>.pid   # Monitor watcher pidfiles
│   ├── proj.<pid>.project # Session's real project root, keyed by agent PID (#92)
│   └── .lastcheck-*      # Cooldown markers
└── teams/
    └── <team>/
        └── config.json   # Team member registry
```

Claude Code コマンドは別途 `~/.claude/commands/<cmd>.md` にインストールされる。

## 依存関係

依存関係はそれを必要とする機能の範囲に閉じる — まとめて一括要求する
のではなく、local-only のインストールは最小限のまま、追加の機能は
それぞれが個別に必要とするバイナリだけを持ち込む（2026-07-25 に確定した
方針:「依存は機能の範囲に閉じる」。以下の階層はこの原則を現在の
コードベースの事実に当てはめた結果であり、推測ではなく直接確認した
もの — 以前の版はcore→E2EE→remoteの一直線モデルを暗に前提としており、
どちらとも無関係にNodeが必要な箇所を見落としていた）。

- **core（local-onlyのメッセージング）** — `bash`、`sqlite3`（JSON1拡張
  経由のデータベース操作とJSON操作）、`awk`/`sed`（設定・TOML編集）。
  `send`/`inbox`/`history`/`team`/`join`/`leave`/`rename` など、ローカルの
  SQLiteストアとしかやり取りしないもの全てをカバーする。python3もnode
  もネットワークもデーモンも不要。
- **codex agent type / launcher付きspawn** — coreに加えて `node`
  （`scripts/lib/node.sh` が解決する。Codex monitorの配送ブリッジ
  `codex-bridge.js` はNodeプログラム）。launcherを持つagent typeに対して
  `spawn.sh` は明示的にdieする（`'node' not found on PATH — spawning
  '<type>' requires Node.js`）。下記のE2EE/remoteとは無関係 — この依存は
  既に`main`に存在する。
- **E2EE（エンドツーエンド暗号化されたチーム鍵）** — coreに加えて
  `age`/`age-keygen`（`key.sh`）。暗号化された鍵プロファイルを使うチーム
  にのみ必要。
- **remote control plane（connect/status/disconnect/pending、team list）**
  — coreに加えて `python3`（`remote.sh`、`team-list.sh`、およびそれらが
  使う`scripts/internal/*.py`ヘルパー群 — 応答/設定の厳密な検証をbashで
  再実装せずPythonで行っている）。チームを同期サービスへ接続する場合に
  のみ必要。各エントリポイントは最初のpython3呼び出しの前に必ず
  `agmsg_require_python3`（`scripts/lib/require-python3.sh`）を呼び、
  python3が使用不能なら即座にインストール方法つきのメッセージで失敗する
  — `key.sh`の既存の`age`前段チェックと同じ形。これは単に分かりやすい
  エラーのためだけではない: macOSでXcode Command Line Toolsが未導入の
  状態で素の`python3`を呼び出すと、通常の「見つかりません」エラーでは
  なくOS自体のCLTインストールダイアログが起動してしまう。さらに厄介な
  ことに、`command -v python3`だけではこれを検出できない —
  AppleはCLT未導入でもPATH上に実在する`/usr/bin/python3`トランポリンを
  同梱しているため、単純なPATHチェックは、実際に何かがそれを実行する
  その瞬間まで「成功」を報告し続ける。`/usr/bin/python3`という文字列との
  単純な比較でも不十分: PATHはシンボリックリンク経由でpython3を解決する
  ことがあり（例: `~/bin/python3 -> /usr/bin/python3`）、リンク先を実行
  すればトランポリンに到達するにも関わらず、その解決結果の文字列自体は
  トランポリンのパスと異なる。そのため解決されたパスは、相対・絶対を問わず
  全てのシンボリックリンクのホップを辿り（`-f`/canonicalize相当のフラグが
  無いBSD/macOSの`readlink`にも対応できる形で）、実体パスへ到達してから
  比較する。このチェックは、その実体パスがDarwin上でちょうど
  `/usr/bin/python3`である場合に限り、追加で`xcode-select -p`
  （インストール済みツールの状態を調べるだけの、実在し常に存在する
  非対話的なバイナリ）を確認する。python3自体は、いかなる
  プラットフォームでも、いかなる状況でも、自身の使用可否を確認する目的
  で実行されることは無い — 「試しに実行してみて様子を見る」という類の
  解決策こそ、このチェックが避けようとしているものそのものである。
- **remote sync data plane（Stage-1のポーリング同期クライアント）** —
  coreに加えて `node`（`remote-sync.sh`が`AGMSG_SYNC_NODE_BIN`/
  `agmsg_resolve_node`経由で`internal/remote-sync.mjs`とその周辺の`.mjs`
  ヘルパー群をexecする）。上記control planeのpython3必要性とは別の、
  独立したNode依存理由。

`doctor`（`remote.sh doctor`）は`age`・`python3`・`node`を確認し、実際の
ゲートと同じ判定helper（`agmsg_python3_usable`、`agmsg_node_usable`）を
共有するため、診断表示とゲートが食い違うことはない。
`agmsg_node_usable`（`scripts/lib/node.sh`）は独自の単純な`command -v
node`判定を新設するのではなく、`agmsg_resolve_node`自体の解決契約
（`AGMSG_NODE`override、version-manager paths、PATH）をそのまま再利用
しているため、doctorの「使用可能」判定は`remote-sync.sh`が実際に試みる
ものと常に一致する。
