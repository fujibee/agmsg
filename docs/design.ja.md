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

すべてのスクリプトは `bash` と `sqlite3` のみを使用する。python3 依存はない。

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

- **bash** — シェル
- **sqlite3** — データベースおよび JSON 操作（JSON1 拡張）
- **awk/sed** — テキスト処理（設定、TOML 編集）

python3 も node も、ネットワークもデーモンも不要。
