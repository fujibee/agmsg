# Antigravity TUI conversation 登録と既知 ID 再開の詳細設計

状態: 実機機能検証で不採用。実装・commit・push・既存インストールへの反映は行わない。
作成者: luna。作成日: 2026-09-06（JST）。

## 1. 目的と結論

Antigravity (`agy`) の TUI が自分の `conversation_id` を agmsg bridge から読める場所へ登録し、bridge がその既知 ID を指定して headless 子プロセスを再開できるようにする。

monitor の本来の目的は、ユーザーが操作している TUI の会話へ agmsg の着信を届けることである。
現行の独立 headless conversation は、TUI の ID を安全に解決できなかった時点の次善策であり、新規運用の正本にはしない。
ただし、既存 state と既存利用者を一度の更新で壊さないため、独立 conversation は明示的な `standalone` フォールバックと移行期間中の既存 state 継続に限って残す。

2026-09-06 12:54 JST の実機検証で、稼働中 TUI と headless `agy` が同じ conversation ID で同時に接続を確立できることを確認した。
しかし、2026-09-06 14:03 JST の機能検証で、headless turnは永続会話上で成功しても稼働中TUIのインメモリ文脈へ反映されないことを確認した。
同じIDで接続できることは、稼働TUIへ自動着信を表示できることを意味しない。
したがって本書のregistration・既知ID併走方式は不採用とし、TUIへ外部turnを反映・再読込させる確認済みAPIが得られるまで実装しない。

Codex monitor も TUI 非依存ではない。
`codex-monitor.sh` は TUI を共有 app-server へ `--remote` 接続し、bridge は `thread/loaded/list` または記録済み thread ID を解決して、同じ TUI threadへ `turn/start` する。
Antigravity は app-server の thread discovery APIが無いため、本案はregistrationで同じ責務を補うことを狙った。
この差はregistrationだけでは補えなかった。Codexの共有app-serverは同じlive threadへturnを配信するが、agyの別processは同じconversation IDを指定しても稼働TUIのlive stateを更新しない。

現行の `agy` には Codex の `thread/loaded/list` 相当の、稼働中 TUI conversation を列挙する確認済み API がない。
したがって、bridge が会話を発見する方式ではなく、TUI 起動側が明示的に登録する方式を採用する。
未登録の TUI に対して bridge が `--continue` や会話 ID なしで推測起動することは禁止し、既存の新規会話作成方式との互換性は明示的な移行モードに限定する。

本書の設計対象は agmsg 正規リポジトリ `/home/joel/projects/agmsg` の Antigravity driver である。
調査時点の実測は次のとおり。

- HEAD: `b57258f9da02f2f3730cb19d6d2f0ad06253cf0c`
- `origin/main`: `e127b06b63ade2f34b6f0698d1dc3375d6ed4c0c`
- 作業ツリー: clean
- ホストの `agy --version`: `1.1.27`
- `agy --help` の会話指定: `--continue` と `--conversation <ID>`。loaded conversation 一覧指定は未確認。
- `agy --input-format stream-json --output-format stream-json` は一つの headless conversation を stdin の複数ターンで継続する。
- 稼働中 TUI の実測 conversation ID `691ad6cf-2e20-4e01-a5a9-1c995ed5a9fb` を指定した headless 接続は、同じ ID の `init` を返した。
- 接続前後とも TUI PID `23563` は生存し、headless stderr に `active writer`、`already has`、conversation resume failure は無かった。
- headless へ user input は送らず、接続確認後に process group を終了した。TUI の操作・会話内容・agmsg の既読状態は変更していない。
- `lsof` で presence lock を保持していたのは TUI PID だけだった。このため、二つのプロセスが同じ lock file descriptor を持つことまでは確認していない。確認済みの保証は、TUI 生存中に headless が同一 ID で `init` まで成功し、Codex 型の resume 排他エラーが発生しないことに限定する。
- 使い捨てTUI conversation `b342aff2-614d-4f7f-a2f2-eb2775fc1caa` で、TUIは最初に `kiwi` を記憶した。
- TUI idle中、同じIDのheadlessへ `mango` とだけ返す限定turnを一件投入した。headlessは同一IDのinit、`mango` 一回、SUCCESSを返し、TUI PIDは生存した。
- 続けて稼働TUIへ「直前に別接続から追加された果物」を質問したところ、TUIは `kiwi` と回答した。外部turnの `mango` はlive TUI文脈へ反映されていない。
- §6.1の最初の合格基準「同じconversation履歴へ現れ、応答完了後もTUIがその文脈で応答できる」を満たさないため、busy中投入は実施せず検証を終了した。

今回の計画書更新では、製品実装・設定変更は行わない。実機検証は `/tmp/agy-concurrent-tui-project` の使い捨てTUIと上記限定turnだけで行い、既存TUI、agmsg既読、既存bridge stateは変更していない。

現行の独立 headless conversation方式は、TUI自動着信という本来目標を満たすものではないが、現時点で安全に動作する次善策として正式運用を継続する。
registration方式の実装候補は本書に記録として残すが、後続節の実装仕様は採用済み要件ではない。

## 2. 用語と責務

| 用語 | 意味 | 所有者 |
|---|---|---|
| TUI | 人間が操作する `agy` の対話セッション | TUI 起動 wrapper / SessionStart 経路 |
| bridge | agmsg 未読を headless `agy` へ渡す常駐プロセス | `antigravity-bridge.mjs` |
| registration | TUI と bridge の対応を示す JSON レコード | TUI 登録ヘルパ |
| lease | 登録の生存を示す所有者・開始時刻・期限の組 | TUI 起動 wrapper |
| worker conversation | bridge が `--conversation` で再開する headless 会話 | bridge |

TUI の conversation と bridge の headless conversation は、同じ ID を使える場合に限って同一文脈として扱う。
ID が異なる場合は自動統合・自動 fork・新規会話への黙った切替をしない。

## 3. 登録データの配置とスキーマ

### 3.1 配置

登録データは agmsg の既存状態ファイルと同じインストールの `run/` 配下に置く。
DB、team config、プロジェクトの git 管理ファイルには登録を書かない。

project ごとに一つの JSON を置くが、複数 TUI を上書きしないよう `sessions` 配列で保持する。
候補パスは次のとおりとし、実装時に既存の `storage` / path helper の命名規約へ合わせる。

```text
~/.agents/skills/agmsg/run/antigravity-tui.<project-hash>.json
```

bridge はこの JSON を直接自由に読むのではなく、既存の Bash/Node helper を介して読み取る。
helper は `flock` 下の read-modify-write、同一ディレクトリへの一時ファイル作成、`fsync`、atomic rename、所有者限定 permission、壊れた JSON の fail-closed を提供する。
複数 TUI wrapper が同時登録しても、lock 取得後に最新 JSON を再読込してから自 instance だけを更新する。
lock を取れない、再読込後の世代が想定と異なる、rename に失敗した場合は登録を変更しない。

### 3.2 レコード

```json
{
  "schemaVersion": 1,
  "project": "/absolute/project",
  "sessions": [
    {
      "instanceId": "stable-tui-instance-id",
      "team": "airsurf",
      "role": "agy",
      "conversationId": "uuid",
      "ownerPid": 1234,
      "ownerStart": "process-start-token",
      "registeredAt": "2026-09-06T12:00:00+09:00",
      "lastSeenAt": "2026-09-06T12:00:00+09:00",
      "leaseExpiresAt": "2026-09-06T12:05:00+09:00",
      "state": "active"
    }
  ]
}
```

必須項目は `schemaVersion`、正規化済み `project`、`instanceId`、`team`、`role`、`conversationId`、`ownerPid`、`ownerStart`、`registeredAt`、`lastSeenAt`、`state` とする。
`conversationId` は空文字・推測値・`loaded` を許可しない。
時刻は保存形式として ISO 8601 の `+09:00` を使い、人間向けログも JST とする。

`ownerPid` だけでは PID 再利用を判別できないため、`ownerStart` と組み合わせる。
lease の失効だけでは即座に別 TUI の登録を削除せず、所有者の process start token を再確認する。
bridge が採用できるのは `state=active` のレコードだけとする。
`state=closed` は履歴表示の対象にはできるが、conversation 解決、候補数、最新値選択には含めない。

## 4. 登録タイミングと書き込み主体

### 4.1 TUI 起動時

既存の通常 `spawn antigravity` を直接書き換えず、TUI 起動を担当する driver wrapper に登録処理を追加する。
起動順序は次のとおり。

1. wrapper が `instanceId` を生成または既存の起動引数から復元する。
2. `agy` を TUI モードで起動する。
3. TUI が会話 ID を確定した後、TUI と同じ所有者プロセスから登録 helper を呼ぶ。
4. helper が `conversationId`、process start token、team、role、project を atomic に登録する。
5. 登録成功を確認してから bridge 起動通知または bridge の再接続を許可する。
6. 登録できない場合は bridge を起動せず、TUI は通常利用可能なままエラーを表示する。

書き込み主体は、会話 ID を実際に知っている TUI wrapper/SessionStart 経路とする。
bridge が会話 ID を推測して登録すること、headless bridge が TUI の代わりに登録することは禁止する。

この禁止は呼出し規約だけに依存させない。
TUI wrapper は起動前に暗号学的乱数 capability を生成し、環境変数や argv へ置かず、専用 file descriptor で登録 helper にだけ渡す。
helper は capability に加えて、登録対象 PID が wrapper の直接の TUI 子プロセスであること、PID/start token が一致すること、その PID が対象 `conversationId` の presence lock を実際に保持すること、cwd が正規化済み project と一致することを検証する。
一つでも不一致なら書き込まない。
headless bridge とその `agy` 子では capability の file descriptor を起動前に閉じ、登録 helper は capability なしの呼出しを拒否する。
同一 OS user の任意コードに対する秘密保護を保証するものではないが、bridge の通常経路や誤呼出しが registration writer になることは機械的に閉じる。

初期実装の presence 検証は、実測済みの Linux 経路だけに限定する。
対象パスは `${HOME}/.gemini/antigravity-cli/presence/<conversationId>.lock` で、`conversationId` は UUID と完全一致させる。
helper は `lsof` の表示文字列を判定に使わず、`/proc/<ownerPid>/fd/*` の symlink を列挙し、canonical path が対象 lock と完全一致する fd が一つ以上あることを確認する。
実測では TUI PID `23563` の `/proc/23563/fd/46` が `/home/joel/.gemini/antigravity-cli/presence/691ad6cf-2e20-4e01-a5a9-1c995ed5a9fb.lock` を指し、lock は owner `joel`、mode `0600` だった。
wrapper は同じ fd 対応から conversation ID を取得し、最新mtime、ファイル名一覧、`last_conversations.json` から推測しない。

`/proc` が無いOS、既定外の app data directory、fd symlink を読めない権限、複数の UUID presence lock を同じ PID が保持する状態では TUI registration を作らない。
その場合は自動登録を成功扱いにせず、`tui` mode を fail-closed で停止する。
対応OSを増やすときは、PIDとconversation IDを同じ強さで結び付ける取得経路を先に実測して計画を更新する。

現行 `agy` が TUI 起動後に会話 ID を hook へ渡さない場合は、wrapper が標準出力・既知の CLI 応答・公式に提供された session metadata のいずれかから取得できるかを実装前に実測する。
取得経路が確認できない場合、TUI 側の小さな明示操作（例: bridge register コマンド）へ切り替え、自動登録を実装したとは記載しない。

### 4.2 heartbeat と終了

TUI wrapper は一定間隔で `lastSeenAt` と lease を更新する。
正常終了時は自分の `instanceId` と `ownerStart` が一致するレコードだけを `state=closed` として atomic 更新する。
bridge は TUI の終了を検知して自分の headless child を終了するが、TUI の所有プロセスを終了させない。

close 更新も登録時と同じ `flock` と世代再読込を使う。
既に別 ownerStart で更新済みの同名 instance、または既に closed のレコードを上書きしない。

異常終了時に残った registration は、次回起動時に process start token と lease を検証して stale と分類する。
stale record の削除は、同じ instance の所有権が確認できる場合に限る。別 instance の登録は削除しない。

## 5. 複数 TUI セッション

### 5.1 同一 role の複数 instance

同じ `project/team/role` に複数 TUI がある場合、単一の bridge が複数 conversation を同時に監視してはならない。
各 TUI は固有 `instanceId` を持ち、role の bridge は次のいずれかの明示選択を要求する。

- `--instance <instanceId>` で一つの TUI に固定する。
- role を TUI ごとに分ける（例: `agy-w1-pS`、`agy-w1-pT`）。

既定値として「最新登録」「最初の登録」「PID 最大」を採用しない。
複数候補で instance 指定がない場合は `NEEDS_ATTENTION` とし、未読取得を開始しない。

### 5.2 同一 role の排他

既存の agmsg actas/role 排他を conversation registration に結び付ける。
一つの role を一つの bridge が所有している間、別 TUI は同じ role の bridge 登録を奪えない。
複数 TUI を正式に許可する場合は、role を分割して別 inbox と別 bridge lease にする。

この設計により、同じ agmsg inbox を複数 conversation が競合して既読化する事故を防ぐ。
複数 TUI 対応を一つの inbox の fan-out として実装することは今回の範囲外とする。

## 6. bridge の起動・再開ロジック

`antigravity-bridge.mjs` の初期化前に、対象 `project/team/role/instanceId` の有効 registration を一つ解決する。

1. registration が一つで、lease・PID・start token・project・role が一致する場合だけ `conversationId` を採用する。
2. 有効な ID がある場合は `agy --input-format stream-json --output-format stream-json --conversation <ID>` を起動する。
3. `init` の ID が登録 ID と一致することを確認する。
4. 不一致、複数候補、期限切れ、破損、所有権不一致の場合は新規会話を作らず停止する。
5. state の `conversation_id` は `init` 後に登録 ID と同一であることを再確認して保存する。

候補抽出時は `state=active` を必須とし、closed、schema不正、期限切れ、PID/start不一致を有効候補として数えない。

### 6.1 TUI と bridge の同時ターン

同一 ID の `init` 成功だけでは、TUI user turn と bridge turn の同時投入が安全とは断定しない。
実装前に、専用の使い捨て TUI conversation で次を実測する。

1. TUI が idle のとき、headless から限定メッセージを一件投入し、同じ conversation 履歴へ一度だけ現れる。
2. 応答完了後も TUI が同じ ID で入力・応答できる。
3. TUI turn 実行中に headless turnを投入した場合、agy が直列化するか明示的に拒否し、既存 turn の応答・履歴を破損しない。
4. 拒否時に bridge は batch を ack せず `uncertain` または再投入可能な状態で停止する。

合格基準は、メッセージ欠落、重複、conversation ID変更、TUI応答不能、履歴上書きが無いこととする。
busy中の挙動を観測できない、または投入が既存 turn と競合して内容を失う場合、TUI併走版を実装しない。
外部 idle oracle が確認できない状態で、時間待ちや最新更新時刻だけを根拠に安全と判定しない。

既存 bridge の headless conversation state は維持する。
registration は TUI の対応先を示す別レイヤーであり、既存のバッチ、ack、reservation、違反ラッチの schema を変更しない。

## 7. 既存 bridge との互換性・移行

### 7.1 互換性

conversation の実行方針は、role単位の専用設定ファイルに明示保存する。
候補パスは `run/antigravity-conversation-policy.<project-hash>.<team>.<role>.json` とし、少なくとも `schemaVersion`、正規化済みproject、team、role、`mode` を持つ。
`mode` は次の三値だけを許可し、bridge state の `conversation_id` 有無から暗黙推定しない。

| mode | 用途 | conversation ID の取得 | 新規 conversation 作成 |
|---|---|---|---|
| `tui` | 新規既定。ユーザーのTUIへ自動着信 | active registrationだけ | 禁止 |
| `standalone` | ユーザーが明示した独立worker | bridge state。無ければagy init | 許可 |
| `legacy-state` | 更新前から存在する独立workerの移行継続 | 更新時に照合した既存bridge stateだけ | 禁止 |

policy が無い状態は `unconfigured` として起動を拒否する。
`delivery.sh set monitor antigravity <project>` は team/role を受け取らないため、conversation policy を作成・変更しない。これは project 単位の delivery envelope だけを設定する。
新規設定の既定が `tui` であるとは、policy不在時にbridgeが暗黙補完する意味ではない。team/roleを確定済みのTUI wrapperがregistration成功と同じ所有権検証の後に、policy不在を再確認して新規`tui` policyを作成し、その成功後にbridge起動を許可するという評価順序を指す。
既存policyがある場合、TUI wrapperは上書きしない。既存modeが`tui`なら同一project/team/roleとして再検証して利用し、`standalone`または`legacy-state`なら明示的なpolicy変更を要求して停止する。
`standalone` policy は、専用の role-aware CLI `antigravity-conversation-policy.sh set standalone --project <project> --team <team> --name <role>` をユーザーが明示実行した場合だけ作成する。
既存 policy の mode 変更も同CLIへ限定し、bridge 起動時の create-if-absent、stateからの推定、全roleへの前倒し作成は行わない。
更新時の migration component は、既存の有効な bridge stateを列挙し、project/team/roleとstate fileの所有権を検証した対象にだけ `legacy-state` policyを作成する。これは§7.2の人手によるTUI移行より前に、既存独立workerを更新だけで止めないための一度限りの互換処理であり、`tui` への切替は行わない。
既存stateが無いrole、壊れたstate、未解決batch、複数stateの曖昧さがあるroleには migration policyを書かず停止する。
TUI wrapper、専用policy CLI、更新時migrationの三つのwriterは、policy単位の `flock` 下で最新内容を再読込し、所有権と期待modeを再検証してから `fsync` とatomic renameで保存する。lock取得・再検証・保存の失敗時は既存policyを保持する。
status は delivery mode と conversation policyを別項目で表示する。

新規設定の既定は `tui` とし、有効 registration が無ければ新規 conversation を作らず fail-closed で登録方法を案内する。
TUI併走が monitor の正本である。

既存インストールで `conversation_id` を持つ bridge state は、更新時migrationが `legacy-state` policyを正常作成した場合に限り、更新だけで無効化しない。
registration がまだ無い間は、その明示policyと照合済みstateの独立 conversationを移行用フォールバックとして継続できる。policy作成に失敗したstateを暗黙継続しない。
ただし新しい TUI registration が作成された後は、state の ID と registration が一致しない限り自動変更せず `NEEDS_ATTENTION` とする。

独立 workerを意図的に使う場合は、明示的な `standalone` modeを指定する。
`standalone` は現行の新規 conversation 作成を許すが、TUIへ届くとは表示しない。
暗黙のフォールバック、registration失敗時の自動 standalone化、`--continue` による推測は行わない。

### 7.2 移行手順

1. 現行 bridge state の `conversation_id`、project/team/role、最終更新を status で表示する。
2. 対応する TUI が既知 ID と一致することを人間が確認する。
3. 一致した ID と instance を registration helper で明示登録する。
4. bridge を停止・再起動する場合は未解決 batch を自動再投入せず、既存 state の phase に従う。
5. registration と bridge state の一致を status と限定 self-test で確認する。

旧 bridge の state を削除・上書きして移行しない。
未解決 batch がある場合は移行を停止し、既存の status/resolve 手順を先に通す。

## 8. 既存稼働 TUI の後登録

### 8.1 自動後登録

現行 `agy` の確認済み公開機能には、稼働中 TUI の conversation ID を外部から列挙する API がないため、既存 TUI を後から自動登録することは今回の実装では保証しない。

### 8.2 明示的な後登録

既存 TUI の手動後登録は、wrapper capability と直接子PIDの検証を満たせないため、初期実装の対象外とする。
conversation IDを表示・コピーできるだけでは writer 権限の証明にならない。
将来、TUI 自身が署名済み session metadata または専用 capability を渡せる場合に限り、次のような helperを再検討する。

```text
bash scripts/drivers/types/antigravity/conversation-register.sh \
  --project <absolute-project> --team <team> --name <role> \
  --instance <instance-id> --conversation <known-id>
```

helper は次を検証する。

- ID が UUID 形式であること。
- project/team/role が登録済み identity と一致すること。
- 同じ instance の既存 ID と衝突していないこと。
- PID/start token、presence lock、wrapper capability が同じ TUI instance を示すこと。
- 同じ role に別の active registration がある場合は拒否すること。

ID を外部から取得できない既存 TUI は、後登録不可と報告し、新しい TUI を登録済み wrapper から起動する代替案を提示する。
履歴ファイルや `last_conversations.json` の最新 IDを「稼働中 TUI」とみなす代替は採用しない。

## 9. 失敗時の安全動作

| 状態 | 動作 |
|---|---|
| registration なし | `tui` modeでは新規会話を作らず停止。登録済みwrapperからの起動を案内 |
| registration 複数 | instance 指定を要求。未読取得しない |
| registration が closed のみ | 有効候補なしとして停止。closed IDを再開しない |
| lease 期限切れ | owner PID/start token を再検証。確認不能なら停止 |
| PID 再利用 | start token 不一致として拒否 |
| init ID 不一致 | bridge を `NEEDS_ATTENTION` にし、既読・再投入しない |
| bridge state と registration 不一致 | 自動切替せず、status/resolve を要求 |
| TUI 異常終了 | registration を即時他 instance へ移譲しない。未解決 batch を保持 |
| JSON破損・atomic更新失敗 | fail-closed。既読を進めない |

この設計では、会話文脈の取り違えと同じ inbox の二重読み取りを優先して防ぐ。
可用性のために未登録状態で新規 conversation を作ることはしない。

## 10. 実装対象とテスト計画

実装開始後の候補ファイルは次のとおり。今回これらは変更しない。

- `scripts/drivers/types/antigravity/antigravity-bridge.mjs`
- `scripts/drivers/types/antigravity/antigravity-monitor.sh`
- `scripts/drivers/types/antigravity/conversation-register.sh`（新設候補）
- `scripts/drivers/types/antigravity/_delivery.sh`
- `scripts/drivers/types/antigravity/template.md`
- `tests/antigravity_bridge.test.mjs`
- `tests/fixtures/fake-antigravity.mjs`

最低限のテストを次の順で追加する。

1. 登録 JSON の flock付きatomic更新、同時writer、schema検証、壊れたJSONのfail-closed。
2. 一つの active registration が `--conversation` に変換されること。
3. registration のない起動が新規会話を作らず停止すること。
4. `init` ID 不一致、PID再利用、lease失効を拒否すること。
5. 同一 role の複数 instance を曖昧選択せず停止すること。
6. role 分割した複数 TUI が別 bridge/inbox として共存すること。
7. 旧 state に ID がある場合の再開と、新 registration との不一致検出。
8. 既存 headless bridge の peek、batch、ack、uncertain 復旧に回帰がないこと。
9. fake agy で `--conversation <ID>` を受け、init ID が一致する複数ターンを確認すること。
10. 実 agy は専用 role・限定メッセージで、明示承認後にのみ検証すること。
11. capability FDなし、bridge PID、presence lock不一致、非直接子PIDからの登録を拒否すること。
12. `state=closed` を候補から除外し、closeとregisterの同時更新で別instanceを失わないこと。
13. 専用TUIでidle時投入とbusy時投入を実測し、§6.1の合格基準を満たすこと。
14. 新規`tui`、既存state移行、明示`standalone`の三経路を混同せずテストすること。
15. policy不在・未知modeを拒否し、delivery modeとconversation policyをstatusで別表示すること。
16. Linux `/proc/<pid>/fd` の単一presence lockだけを登録し、0件・複数件・別PID・別UUID・既定外app data directoryを拒否すること。

TUI wrapper が会話 ID を取得する経路は、fake fixture だけで済ませず、現行 `agy 1.1.27` の実機起動で確認する。
取得できない場合は、計画を修正して明示登録方式へ限定し、自動登録を実装範囲に残さない。

## 11. レビューで確認してほしい論点

- registration の書き込み主体が TUI 側に限定され、bridge が会話を推測しないか。
- state.json と registration の二つの source of truth の不一致時に fail-closed になるか。
- 複数 TUI の同一 role/inbox 競合を、最新値や PID だけで誤選択しないか。
- PID 再利用、lease失効、TUI異常終了後の所有権判定が十分か。
- 既存 bridge の batch/ack/uncertain 仕様を壊さず移行できるか。
- 既存 TUI の後登録を「可能」と過大主張していないか。
- `--continue`、履歴キャッシュ、desktop import を live TUI 発見APIと誤認していないか。
- 実装・commit・push前に必要な fake/実機検証が計画に含まれているか。

## 12. 対象外

- agy CLI や desktop 側への新API実装
- 外部プロセスへの任意入力注入、TUI画面の自動操作
- 複数 conversation への inbox fan-out
- registration を使った既存 TUI の強制 takeover
- DB、team config、既存 bridge state の直接編集
- 今回の計画段階での実装、commit、push、既存インストールへの反映
