# ドライバーインターフェース仕様

*[English](driver-interface.md)*

**Status:** draft (epic [#51](https://github.com/fujibee/agmsg/issues/51))
**Scope:** 軸A — storage。共通プロトコルの節は軸B（agent）および軸C（delivery）にも適用されるが、それらの軸固有の関数はここでは対象外とする。

本書は、agmsgコアとstorageドライバー間の契約を定義する。新規ドライバーが実装すべき内容の正式な情報源である。

**v1のスコープ:** バンドル済みドライバーのみ。プラグインパス（`~/.agents/agmsg/plugins/`）、`plugin.json` のメタデータ、`min_core_version` によるゲーティングは将来のリビジョンに先送りされる。§6を参照。

## 1. 共通ドライバープロトコル

これらの規約はすべての軸のすべてのドライバーに適用される。

### 1.1 ドライバーの配置場所

バンドル済みドライバーは `scripts/drivers/<axis>/<name>` に配置される。ファイルベースの軸では単一の `<name>.sh` を使用し、エージェントタイプ（"types"）軸では `type.conf` マニフェストとそのタイプのランタイムを格納するディレクトリ `scripts/drivers/types/<name>/` を使用する。それらのメタデータは暗黙的であり、agmsgコアのバージョンに紐づく。

外部（非バンドル）ドライバーは `<install_dir>/plugins/<axis>/<name>` および `$AGMSG_PLUGIN_DIRS` から検出され、明示的なオプトインが必要である — 詳細は [ADR 0002](../adr/0002-driver-discovery-and-plugin-opt-in.md) を参照。

### 1.2 呼び出し規約

ドライバーはbashスクリプトであり、agmsgコアがこれを `source` してから関数名で呼び出す。関数名は衝突を避けるため軸ごとにプレフィックスが付く：storageドライバーは `storage_*` 関数を、agentドライバーは `agent_*` 関数を、deliveryドライバーは `delivery_*` 関数を公開する。

ドライバーはそのプレフィックスを超えてグローバル名前空間を汚染してはならず、`set -e`/`set -u` のセマンティクスを定義してはならない。これらは呼び出し元の責任である。

### 1.3 必須の共通関数

すべての軸のすべてのドライバーは以下を実装する：

| Function | Purpose | Returns |
|---|---|---|
| `<axis>_check` | すべてのランタイム依存関係が存在し、ドライバーが有効化できることを検証する。依存関係が不足している場合、stdoutに `AGMSG-DIRECTIVE` を出力することがある。 | ステータスコード（§1.4を参照） |
| `<axis>_describe` | stdoutに人間可読な1行の説明を出力する。 | 常に0 |

### 1.4 ステータスコード

失敗しうるドライバー関数は、終了コード**および**stdoutの最終行にステータス名を出力することで、構造化されたステータスを報告する。ステータス名は以下の通り：

| Code | Name | Meaning |
|---|---|---|
| 0 | `ok` | 操作が成功した |
| 10 | `missing_deps` | 必要な外部依存関係がインストールされていない。インストール方法を記述した `AGMSG-DIRECTIVE` がstdoutに出力された。 |
| 12 | `corrupt_state` | ドライバーがデータストア内で回復不能な不整合を検出した。手動での対応が必要。 |
| 13 | `runtime_error` | その他すべての失敗。stderrにメッセージが含まれる。 |

（コード `11 incompatible_core` は将来のプラグインローダー用に予約されており、v1では使用されない。）

呼び出し元は非ゼロの終了コードをすべて失敗として扱ってよいが、ホストエージェントの挙動決定においてはステータス名が正となる。

### 1.6 `AGMSG-DIRECTIVE`

stdoutに書き込まれる1行で、`AGMSG-DIRECTIVE: ` というプレフィックスの後にJSONオブジェクトが続く。ホストエージェントはこのディレクティブを読み取り、パースし、それに基づいて動作する。

```
AGMSG-DIRECTIVE: {"type":"install_deps","driver":"jsonl-duckdb","commands":["brew install duckdb"],"reason":"duckdb binary not found on PATH"}
```

| Field | Type | Description |
|---|---|---|
| `type` | string | `install_deps`、`invoke_monitor`、`stop_task` のいずれか。拡張可能。 |
| `driver` | string | ディレクティブを発行したドライバー名（該当する場合） |
| `commands` | string[] | ホストエージェントが順に実行してよいシェルコマンド。任意。 |
| `reason` | string | ユーザー向けの人間可読な説明。 |
| `*` | any | タイプ固有のフィールド。本書内のタイプ別スキーマを参照。 |

ディレクティブはあくまで助言であり、ユーザーに提示するか、自動的に実行するか、無視するかはホストエージェントが決定する。

## 2. Storageドライバー

### 2.1 必須関数

```
storage_check
storage_describe
storage_init
storage_insert_message <team> <from> <to> <body>
storage_unread <team> <agent> [--limit N]
storage_mark_read <id>
storage_mark_read_batch <id> [<id> ...]
storage_history <team> <agent> [--limit N]
storage_teams
storage_team_members <team>
storage_export <file>
storage_import <file>
```

すべての関数は、レコードを返す際にstdoutへ構造化された出力（JSONL）を書き込み、ステータスについては§1.4に従う。レコードには常に `id`（新規書き込みではUUIDv7、レガシーIDでは不透明な文字列）と `at`（ISO-8601 UTC）が含まれる。

### 2.2 イベントログスキーマ

バンドル済みドライバーは、状態を追記専用のイベントログとして表現する。各イベントは `type` 判別子を持つ1レコードである：

```jsonl
{"type":"message_sent","id":"0192...","team":"agsuite","from":"alice","to":"bob","body":"...","at":"2026-05-30T19:00:00Z"}
{"type":"message_read","id":"0192...","msg_id":"0192...","agent":"bob","at":"2026-05-30T19:05:00Z"}
{"type":"team_joined","id":"0192...","team":"agsuite","agent":"alice","agent_type":"claude-code","project":"/path","at":"..."}
{"type":"team_left","id":"0192...","team":"agsuite","agent":"alice","at":"..."}
```

ドライバーはこれらのイベントを射影してクエリに応答する。`storage_unread` は、要求元エージェントに対応する `message_read` が存在しない `id` を持つ `message_sent` イベントを返す。

### 2.3 レガシー互換性（sqliteのみ）

バンドル済みのsqliteドライバーは、`storage_unread` と `storage_history` について2つのソースを読み取る：

1. イベントログのリファクタリング以前のインストールのための、レガシーな `messages` テーブル（`read=0` の行）
2. リファクタリング後に書き込まれたすべてのデータのための、新しいイベントログテーブル

書き込みはイベントログのみを対象とする。自動的なマイグレーションは存在せず、レガシーな行はそのまま残り、無期限にクエリ可能であり続ける。

### 2.4 識別子

ドライバーが生成するすべてのIDは**UUIDv7**文字列でなければならない。インターフェースはIDを不透明なものとして扱うため、レガシーデータ（sqliteの整数自動採番ID）を読み取るドライバーは、それらを10進数文字列としてそのまま通過させてよい。

UUIDv7はドライバー内部で生成する（例：`python -c "..."`、v7に対応するプラットフォームでの `uuidgen`、またはシェル実装）。ドライバーはカウンターファイルに依存してはならない。

### 2.5 並行性

ドライバーは、そのバッキングストアの並行性モデルに責任を持つ：

- sqliteドライバーはSQLiteのWALモードに依存する。
- `jsonl-duckdb` ドライバーは、mark-readのシーケンス周辺および `convert`/`export`/`import` の周辺でロックファイルを使用しなければならない。単一メッセージの追記は、`PIPE_BUF` バイト以下の書き込みについてはPOSIXの追記アトミック性に依存してよい。

### 2.6 コンパクション

イベントログは無制限に増加する。ドライバーは、冗長なイベントを圧縮する内部関数 `storage_compact` を実装しなければならない（例：`message_read` マーカーの統合、削除済みチームのイベントの削除）。v1ではこれを内部コマンドとしてのみ公開し、ユーザー向けCLIは今後追加される可能性がある。

### 2.7 任意の lifecycle-v1 拡張

lifecycle-v1 拡張は、既存の storage 軸に operation identity、receipt、処理中配信の lease、application acknowledgement、work history、notifier outbox を追加する。
storage ドライバーにとって、この拡張は任意である。
ただし、capability の報告は必須である。
ドライバーは lifecycle-v1 capability ごとに `supported` または `unsupported` を明示する。
lifecycle 契約を必要とする呼び出し側は、全 capability の `supported` を要求する。
core は private table、第二の ledger、delivery hook に暗黙でフォールバックしない。

公開関数は次のとおりである。

```text
storage_capabilities [<team>]
storage_operation_send <team> <sender> <recipient> <kind> <operation-key> <wake-target> <body>
storage_operation_fetch <team> <recipient> <consumer> <lease-seconds>
storage_operation_renew <team> <recipient> <message-id> <operation-key> <consumer> <lease-seconds>
storage_operation_ack <team> <recipient> <message-id> <operation-key> <consumer> <result> <cleanup-target> [<reason>]
storage_work_register <team> <work-key> <operation-key> <actor> <generation> <origin> <launch-target> <wake-target> <stall-deadline>
storage_work_event <team> <work-key> <operation-key> <actor> <state> [<result>] [<reason>]
storage_outbox_claim <team> <owner> <lease-seconds>
storage_outbox_complete <team> <outbox-id> <owner>
storage_outbox_retry <team> <outbox-id> <owner> <delay-seconds> [<error>]
storage_lifecycle_history <team> [--operation-key <key>]
storage_lifecycle_active <team> [<recipient>]
```

`storage_capabilities` は、schema を `agmsg-lifecycle-capabilities/v1` とする JSON object を一つ出力する。
この object は active driver 名と、`operation_key`、`delivery_receipt`、`read_receipt`、`processing_lease_renewal`、`application_ack`、`work_registration`、`work_event`、`outbox`、`history_query` の `supported` または `unsupported` を含む。
同梱の SQLite ドライバーは全 capability を実装する。
拡張を実装しない同梱ドライバーと外部ドライバーには fail-closed stub が入る。
lifecycle の write と query は終了コード13で失敗し、stdout に data を書かず、stderr に `unsupported_capability` を出力する。

operation key は `(team, sender, operation_key)` の範囲で安定する。
同じ send を再試行すると、同じ logical message、delivery receipt、wake outbox を返す。
同じ key を異なる immutable content に再利用すると、処理は明示的に失敗する。
message、delivery receipt、wake outbox は一つの transaction で commit される。
fetch は read receipt を記録し、`action` または `terminal` では message を削除せず processing lease を作る。
期限内の lease を renew または ACK できるのは現在の consumer だけである。
lease が期限切れになると、同じ message が再配信可能になる。
新しい logical message は作られない。

application ACK は `applied`、`rejected`、`failed` のいずれかを記録する。
`applied` ACK は同じ transaction で cleanup outbox を作る。
outbox control frame は durable state transition であり、control frame 自体には ACK を要求しない。
この制約により、wake と cleanup の再帰を防ぐ。
work registration は registration event と launch outbox を一つの transaction で commit する。
後続の work event でも、active projection は registration の generation、origin、wake target、stall deadline を保持する。
history query と active query は receipt、lease、ACK、outbox、error、work state を公開し、呼び出し側に driver-private storage を読ませない。

API facade は、この関数群を `GET teams <team> capabilities|lifecycle|active` と `POST teams <team> messages|fetch|lease-renewals|acknowledgements|registrations|work-events|outbox-claims|outbox-completions|outbox-retries` に対応づける。
request body は型付き JSON object である。
型違反、必須 token の空文字、control character を含む token、owner の競合、期限切れ lease は、部分 mutation が起きる前に失敗する。

lifecycle table は SQLite への additive migration である。
既存の message、unread、history、cursor、export、import は legacy client から引き続き利用できる。
SQLite export は whole-store backup/convert operation である。
選択された physical store から、legacy v1 event と全 team の lifecycle message、event、outbox、processing lease を出力する。
import は完全一致する duplicate を受け入れるが、意味的に不正な既知 lifecycle record と既存 record に競合する入力を拒否し、file 全体を一つの transaction で適用する。
未知の event-log record type には、§2.2 の forward compatibility 規則を適用する。

## 3. CLIマッピング

| User command | Driver function(s) |
|---|---|
| `agmsg storage` | アクティブなドライバーの `storage_describe` |
| `agmsg storage list` | 利用可能なドライバーを列挙し、ドライバーごとに `<axis>_describe` を呼び出す |
| `agmsg storage switch <name>` | 新しいドライバーの `storage_check`；`ok` の場合は設定を更新し、`missing_deps` の場合は切り替えずにディレクティブを伝播する |
| `agmsg storage convert <to>` | 新しいドライバーの `storage_check`；`ok` であれば、現行の `storage_export` → 一時ファイル → 新ドライバーの `storage_import` → 検証 → 設定のアトミックな更新 |
| `agmsg storage export <file>` | アクティブなドライバーの `storage_export` |
| `agmsg storage import <file>` | アクティブなドライバーの `storage_import` |

## 4. 設定

軸ごとのアクティブなドライバーは `~/.agents/agmsg/config.json` に記録される：

```json
{
  "storage": "sqlite",
  "delivery": { "claude-code": "monitor", "codex": "turn" }
}
```

`storage` は単一の文字列（マシン全体で共通）。`delivery` はエージェントタイプごとに設定される。これはランタイムによって利用可能な配送メカニズムが異なるためである。`agent` は呼び出しごとの `<type>` 引数から暗黙的に決まる。

## 5. スコープ外（先送り）

- **プラグインローダー** — 外部ドライバーの検出（`<install_dir>/plugins/`、`$AGMSG_PLUGIN_DIRS`）とオプトインの信頼モデルは、現在 [ADR 0002](../adr/0002-driver-discovery-and-plugin-opt-in.md) で定義されている。そのローダーからなお先送りされているのは、`plugin.json` のメタデータ解析、`min_core_version` によるゲーティング、および `incompatible_core` ステータスコードである。
- **プラグインの署名またはサンドボックス化** — ローダーとは直交する問題であり、ローダーが実装された時点で対応される。
- **プロジェクトごとのアクティブドライバーの上書き** — v1はマシン全体で共通であり、将来の拡張項目とする。
- **サブコマンド + JSONLパイプによるドライバープロトコル**（言語非依存のドライバー） — bash以外のドライバーが実際に必要になるまで先送りする。
- **クロスマシンのstorageドライバー**（postgres、s3-jsonl） — 本仕様によってブロックされるものではなく、必要になれば同じプロトコルの下で追加できる。
