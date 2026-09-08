# Antigravity monitor bridge 実装計画

状態: 提案・レビュー待ち。実装、commit、push、既存インストールへの反映は未承認・未実施。
作成者: luna。作成日: 2026-09-05（JST）。

## 1. 対象と調査基準

専用の `agy` headless 常駐子プロセスへ agmsg の未読を中継する。
到着したメッセージは会話の次のターンとして処理し、同じ `conversation_id` の文脈を維持する。
既に動いている対話 TUI への注入、TUI の画面・対話承認の再実装、Gemini ドライバーの変更は対象外とする。

正規クローンは `/home/joel/projects/agmsg`。
調査開始時のブランチは `main`、HEAD は `e0f10a87ed07561812a5cff89b85fcf934573e7c`、作業ツリーはクリーンだった。
`origin` は `fujibee/agmsg`、fork のリモート名は `joelmitz` である。
依頼文の基準 `e1eb933` とは異なるため、本書は上記ローカル HEAD のソースを基準とし、実装前に差分を再確認する。
この計画作成では fetch、checkout、merge は行わない。

文書配置は既存の [docs/design/remote-sync.md](remote-sync.md) と同じ `docs/design/` に合わせた。
`ref/` は採用に向けた計画の置き場ではないため使わない。

根拠の区別:

- ローカルコードで確認: Antigravity は `monitor=no`、`delivery_modes=turn off`、配信 plug は rule-file 方式。
- luna が実機の version/help で確認: `agy 1.1.26` は双方向 stream-json と `--conversation` を提供する。
- agy の担当者による実機検証として依頼文から受領: 1ターン後もプロセスが生存し、次の stdin 入力で文脈を維持して会話を継続できる。
- 公式仕様で確認: user 入力、init/step_update/result 出力、result 待ち、EOF 終了、control_request/control_response 非対応。
  参照: [Headless mode](https://antigravity.google/docs/cli/headless)。
- 本書では未実測: エラー・再起動・承認拒否・Windows の全組合せ、stream-json と明示 conversation 再開の組合せ。

## 2. 最初の実装の範囲

最初の利用形態は、端末から明示起動する単一ロールの headless worker とする。
人間は別の agmsg セッションからメッセージを送り、bridge の端末に処理結果を見る。
自由入力を読む新しい対話 UI やシステム常駐サービスは追加しない。
Node.js と Bash を用い、別の WebSocket サーバーは立てない。

提案する起動インターフェース:

```text
bash scripts/drivers/types/antigravity/antigravity-monitor.sh \
  --project <absolute-project> --team <team> --name <registered-role>
```

`delivery.sh set monitor antigravity <project>` は設定と起動方法の案内だけを行う。
モード変更だけで課金を伴う会話を自動開始しない。
起動時は登録済みのロールを必須とし、他の生存セッションが所有していれば拒否する。
既存の agy TUI と同じロールを奪い合わないよう、初回は headless 用の別ロールで試す。
モードは project/type 単位だが、実プロセスは project/team/role 単位で管理する。

## 3. 既存 Codex 方式との差分

| 責務 | 既存実装 | Antigravity での扱い |
|---|---|---|
| 未読の検出 | `codex/watch-once.sh`、storage facade | 共通の storage/subscription API を利用する。初期版では専用 Bash ヘルパで検出と取得をまとめ、Codex の既存動作は変更しない |
| ロール排他 | `scripts/lib/actas-lock.sh`、`subscription.sh` | 同じ所有権判定・エンコード・所有者限定解放を利用 |
| 会話記録 | `scripts/lib/role-session.sh` | advisory な再開先として利用。配信中の記録は別に持つ |
| 実行環境 | app-server と TUI が同じ WebSocket endpoint を共有 | bridge が `agy` 子プロセスの stdin/stdout を直接所有 |
| 新規入力 | `codex-bridge.js` の `turn/start` | NDJSON の user イベントを1行投入 |
| busy/idle | turn/thread 通知、watchdog | 入力投入後から result までを busy とする |
| 起動監督 | `codex-bridge-launcher.sh` | 小さな専用 launcher と bridge 内の再起動方針。Codex launcher 全体は複製しない |
| 本文取得 | inline モードは `inbox.sh` を turn/start 前に呼ぶ | 未読取得と既読確定を分離する。既存 inbox の意味は変更しない |
| Monitor 能力 | Codex も manifest 上は `monitor=no` | native Monitor は無いため `monitor=no` を維持する |

参照コードは `scripts/drivers/types/codex/{codex-monitor.sh,codex-bridge.js,codex-bridge-launcher.sh,watch-once.sh,eligible-pairs.sh}`。
Codex の RPC、thread 探索、TUI 接続、process/spawn は流用しない。
未読集合の比較、排他、再試行上限、診断の方針を利用する。

## 4. プロセスとターンのライフサイクル

```text
送信元 → 既存 agmsg store（remote 同期は既存機構）
                        ↓ 未読 snapshot
                 Antigravity bridge
                        ↓ stdin: user NDJSON
                 agy headless 子プロセス
                        ↓ init / step_update / result
             状態・表示・受領IDの既読確定
```

bridge の stdout は人間向けの起動状態と回答表示、stderr は診断とする。
子プロセスの stdout は機械可読専用として読み、stderr は継続的に drain して詰まりを防ぐ。

| 状態 | 動作・遷移 |
|---|---|
| STARTING | 設定、実行ファイル、ロール所有権、ローカル状態を確認。`agy --input-format stream-json --output-format stream-json` を shell 無しで起動 |
| INITIALIZING | 初期の固定コンテキストを user イベントとして投入。type/project/team/role と返信方法だけを知らせる。未読本文はまだ送らない |
| IDLE | 初期ターンまたは配信ターンが完了し、受領確定も済んだ状態。既定2秒間隔で未読を確認 |
| BUSY | 1バッチを投入済み。次の入力は送らず、後続メッセージは store に残す |
| ACK_PENDING | SUCCESS の result とバッチの対応を保存済み。受領したIDだけを既読化し、成功後に IDLE へ戻す |
| STOPPING | 新しい未読を取らず stdin を閉じる。現在のターンを待って所有するプロセスだけを終了 |
| NEEDS_ATTENTION | 処理結果不明、プロトコル違反、ロール変更、再開不能など。理由を表示し自動配信を停止 |

init が最初の user 入力まで出ない実装でも起動が循環待ちにならないよう、初期コンテキスト入力を先に許す。
初期ターンは agmsg のIDを持たず、既読処理をしない。
会話が初期化され、IDが保存され、初期ターンが正常完了して初めて ready とする。

NDJSON の取り扱い:

- 入力は JSON serializer で生成し、改行を含む本文も必ず1つの JSON 行にする。`-p` や対話用 `--prompt-interactive` は併用しない。
- 部分行・複数行チャンクをバッファし、1行ずつ parse する。初期上限案は1行8 MiB、超過は理由付き停止とする。
- init の `conversation_id` を保存し、以降IDがあるイベントは一致を検査する。別会話への切替を暗黙に許さない。
- step_update の text_delta は増分表示、result.response は完了回答として扱い、重複表示を避ける。
- result は1入力に1件。成功は `SUCCESS` のみとし、ERROR/CANCELED/INTERRUPTED/WAITING 等を成功扱いしない。
- 未知のイベント名は診断して読み飛ばす。壊れたJSON、結果の重複、対応する入力のないresultは停止する。
- stdin の backpressure を待ち、全行を書けたことを確認する。ただし書込成功をモデルの受領完了とはみなさない。
- 初期化上限は60秒、通常ターンは CLI の print-timeout と bridge の上限を整合させる。初期案は5分と追加30秒。時間超過は未完了扱いで停止し、次ターンを同じ会話に重ねない。

## 5. 未読取得・既読確定・クラッシュ時の扱い

bridge 用 Bash ヘルパ `antigravity/inbox-transport.sh` を新設する案とする。
既存 `scripts/inbox.sh` は表示と既読化をまとめて行うため、配信前の取得には使わない。
新ヘルパは `agmsg_storage_load` と storage facade の `storage_list_unread` / `storage_mark_read_batch` を利用し、DBやteamデータを直接読む別実装を作らない。

ヘルパの契約:

- `peek`: project/type/team/role と所有者を確認し、未読の `{id, from, to, body, at}` を既読化せず返す。取得不能と未読0件を別の終了結果にする。
- `ack`: bridge が保存したバッチID集合を stdin JSON で受け取り、所有権と宛先を再確認してそのIDだけ既読化する。後着メッセージは含めない。
- 列名は storage facade の既存レスポンスに適合させる。上記は新ヘルパの外部形であり、保存スキーマ変更を意味しない。
- 初期バッチ上限案は20件・本文合計64 KiB。単独で上限を超えるメッセージは切り詰めず、そのIDと理由を表示して停止する。

bridge は最大1件のバッチ記録を、インストールの `run/` 配下に atomic replace で保持する。
既存 actas の名前エンコードを利用した `antigravity-bridge.<project-key>.<team-key>.<role-key>.state.json` を提案する。
ファイル権限は所有者のみとし、本文を通常ログへ複写しない。
状態には schemaVersion、所有者、project、team、role、conversation_id、バッチID、各メッセージIDと本文、phase を含める。
phase は prepared / sent / completed / uncertain とし、投入前に prepared を永続化する。
role-session は advisory なので、この状態ファイルの代わりにはしない。

通常の順序は「peek → バッチ保存 → user投入 → SUCCESS受信 → completed保存 → ack → バッチ解除」とする。
既読はモデルのターン完了を意味し、依頼された業務の完了・返信済みを意味しない。
返信は agent が既存 `send.sh` を明示的に実行する。
headless の受領管理は bridge に限定する。
初期コンテキストに加え、`antigravity/template.md` に monitor worker 専用の分岐を追加する。
この分岐では引数なし `$agmsg` は既読を伴う取得を行わず、bridge の状態表示だけを案内する。
`inbox.sh` / `check-inbox.sh` を受領に使わないことと、返信には `send.sh` を使うことを明示する。
通常の turn/off セッションの既定動作は維持する。

### 5.1. 既読の第二書き手を防ぐ機械的な境界

template の禁止文だけでは、既存 skill を読んだ worker の呼び出しを防げない。
そのため、monitor worker が所有する team/role には「bridge が既読管理中」という予約を保存し、既読化を行う共有入口で検査する。
予約は actas の所有者と対応付けるが、不明バッチがある限り PID の死亡だけで解除しない。

- 新設する `scripts/lib/bridge-read-guard.sh` を storage facade のロード後に接続し、`storage_mark_read_batch` と `storage_read_cursor_consume` の双方を保護する。
  `inbox.sh` と `check-inbox.sh` が同じ保護を通ることを実装テストで示す。
- 予約中の team/role への通常の既読化は、store を変える前に拒否する。
  worker の環境変数だけを判定材料にせず、予約と所有者を参照するので、環境変数を落とした呼び出しも拒否する。
- 例外は所有者を照合した `inbox-transport.sh ack` の completed バッチだけとする。
  許可の判定は親 bridge の保持する予約・バッチID・保存済みID集合に拘束し、任意の `ALLOW_ACK=1` のような環境変数では解除できない設計にする。
  具体的な親プロセスから ack ヘルパへの認可受け渡しは実装前にレビューし、worker 子プロセスへ継承しない。
- 拒否した試行は本文を含めず予約に紐づく違反記録へ残す。
  既存 inbox が facade の失敗を非致命として扱っても検知できるよう、bridge は投入前・BUSY中・result処理前に違反記録を確認する。
  検出時は NEEDS_ATTENTION にし、SUCCESS が出ても completed保存・ack・次ターン投入を行わない。
- 違反記録の追記成功を親が読めた場合、または当該ターンの stream-json の tool step に `inbox.sh` / `check-inbox.sh` 相当の実コマンドが現れた場合に、親は NEEDS_ATTENTION として扱う。追記失敗かつ stream にも該当 tool が現れない場合は、guard による既読拒否と state 保持を硬い保証とし、親の違反検知までは保証しない（任意コードや stream 外の既読化は脅威モデル外）。
- 人間の手動 inbox も予約中は既読化を拒否する。
  読む必要があれば peek を使い、予約を無断で解除して cursor を進めない。
  予約解除は worker停止・バッチ解決・ロール所有権の確認後に行う。

ここで閉じるのは、同一インストールの通常スクリプトによる偶発的な第二の既読化である。
悪意ある任意コード、DB直接操作、別インストールや別端末からの既読化を防ぐセキュリティ境界ではない。
専用roleを別端末の自動受信に共有しないことを出荷前の運用条件にする。
外部の既読化があっても、保存済みバッチは次節の復旧対象として保持する。

### 5.2. 未読状態から独立したバッチ復旧

| 異常終了時の記録 | 再起動時の扱い |
|---|---|
| バッチ無し、記録済み会話あり | 同じIDで再開を試せる。明示会話再開の実機検証を出荷条件とする |
| prepared / sent / uncertain | 実際に送られたか、toolの副作用があったか断定できない。未読を残し NEEDS_ATTENTION。自動再投入しない |
| completed | 同じID集合への ack のみ再試行。モデルをもう一度動かさない |
| 状態ファイル破損・書込不可 | 既読を進めず停止。新規会話への無言の切替をしない |

この設計は exactly-once の副作用実行を保証しない。
成功後・completed保存前のクラッシュも不明状態になる。
不明状態は履歴と会話を確認して明示的に解決する。
復旧対象の正本は state に保存したメッセージIDと本文であり、現在の未読一覧から再構成しない。
store 側が既読でも prepared/sent/uncertain を完了とみなさず、stateを消さない。
明示再投入では保存済み本文を同じバッチIDと元ID付きで投入し、重複した副作用の可能性を確認してから行う。
明示ackでは保存済みIDだけを対象とし、既に既読のIDを含んでも冪等に解決する。
state未保存の後着を第二書き手が消すことは、5.1の機械的拒否によって防ぐ。
実装時には状態を表示する `status` と、既読確定または再投入を明示選択する復旧コマンドを設計し、その操作対象のIDを確認表示する。
自動的なロール移譲は不明バッチがある間は行わない。

## 6. 再起動、停止、ロール所有権

IDLE で子プロセスが異常終了した場合だけ、同一会話を 1秒・5秒・15秒後の最大3回再起動する。
再開失敗を新規会話作成に置き換えない。
再起動予算は1ターンの正常完了でリセットし、起動失敗だけの無限ループを防ぐ。
bridge 自体の死亡は初期版では自動daemon化せず、端末に終了が見え、次の明示起動で状態を回復する。

起動時に既存の actas 所有権を取得し、peek前・stdin投入直前・ack前に再確認する。
所有権を失ったら次の入力を止め、BUSYなら不明状態を記録する。
他者の PID を kill せず、自分の子プロセスとプロセス開始識別子を照合して停止する。

SIGINT/SIGTERM、monitor→turn/off では新規取得を止め、stdinを閉じて最大30秒終了を待つ。
残る子は自分のものと照合して終了させ、未完了バッチを残す。
通常停止では自分の readiness/PID とロックだけを片付け、conversation記録と不明バッチを消さない。
mode切替の停止処理が完了しなければ、その失敗を表示し turn の自動取得を開始しない。

## 7. delivery.sh と type.conf の統合

`delivery_modes=monitor turn off` を追加する。
`both` は初期版で提供しない。
`monitor=no` は native Monitor がない事実と spawn の ready 待ち判定に使われているため維持する。

| 操作 | 設計する挙動 |
|---|---|
| set monitor | headless用設定を保存。既存turnルールを停止し、起動例を表示。CLIプロセスはまだ起動しない |
| status | configured mode と runtime状態を別々に表示。停止中・ready・busy・要確認を区別 |
| set turn | 対象project/typeのbridgeを停止後、従来のrulefile_apply turnへ委譲 |
| set off | 対象bridgeを停止し自動取得を解除。不明バッチ・会話記録は保持 |
| monitor起動 | mode、登録、ロール所有権、実行ファイル、状態保存先を検査し起動 |

`antigravity/_delivery.sh` の apply/status/on_enable/on_disable/runtime_status と停止案内を専用化する。
現在の rulefile_status はファイル有無だけでturn/offを判定するため、そのまま流用しない。
新モード設定は `hooks_file` の既存領域に明示マーカーとして保存し、他のルールは上書きしない。
保存マーカーの具体形は既存 rulefile 構造を壊さない最小形式として、実装差分レビューで確定する。
設定の読取はマーカーを正本とし、PIDの有無を設定値として使わない。
`set turn` に既存の専用停止callbackが足りない場合は、共通dispatcherの `apply_settings` より前に小さな停止callbackを追加し、他typeは既定no-opとする。
停止と不明バッチの解決が完了するまでは turn 用rulefileを書かず、第二の自動取得を開始しない。

通常の `spawn antigravity` は既存TUI動作を維持する。
初期版のmonitor起動は専用コマンドに限定し、既存 `--prompt-interactive` 経路へ stream-json を混ぜない。
spawn統合は後続とし、採用する場合はmanifestのspawn plugまたはdriver callbackを通じて専用起動に接続する。
headless起動コマンド自体が ready を待って成否を表示するので、native Monitor のsentinel契約を偽装する必要はない。

## 8. 承認と表示

`control_request` / `control_response` は送信しない。
承認不能のtoolがsoft-denyされてもプロセスが正常終了し得るため、SUCCESSを業務成功の判定には使わない。
初期検証は読み取り・定型返信の限定タスクで行う。
`send.sh` 等の許可は既存のユーザー承認方針に従って対象を限定し、権限一括解除フラグを付けない。
対話承認が必要な依頼は別の対話セッションへ判断を戻す。

人間向けログにはJST、role、conversation_id、バッチID、状態、終了理由を表示する。
本文やtool出力は必要な端末表示に限定し、認証情報を診断ファイルへ記録しない。
headlessの回答表示とagmsg返信は別であり、bridgeから送信先への自動返信は追加しない。

## 9. 変更予定ファイルと実装順序

以下は予定パスであり、今回新設するのは本計画書だけである。

| 段階 | 対象 | 完了条件 |
|---|---|---|
| A | `tests/` の偽agy・隔離store用fixture、Antigravity契約テスト | init遅延、複数ターン、異常終了、壊れたJSONを任意に再現できる |
| B | `antigravity/antigravity-bridge.js`、`inbox-transport.sh` | 1ロール、未読取得、1ターンずつ投入、result対応、ID単位ackが成立 |
| C | `antigravity/antigravity-monitor.sh`、state/status/停止ヘルパ | 明示起動、排他、終了、再開と不明状態停止が成立 |
| D | `antigravity/type.conf`、`_delivery.sh`、必要時 `scripts/delivery.sh` | monitor/turn/off設定、状態表示、解除、既存type回帰が成立 |
| E | `antigravity/template.md`、`docs/agent-types.md`、利用手順 | TUIとの違い、起動、返信、承認、復旧を説明 |

Antigravity相対パスの基点は `scripts/drivers/types/antigravity/`。
storage facade の変更は5.1の予約中のteam/roleに対する既読guard接続に限定する。
予約のない既存利用はそのまま通し、Codex bridgeとGemini設定は変更しない。
段階Bの対象に `scripts/lib/bridge-read-guard.sh` と facade の接続箇所を含める。
既存部品の抽出が必要になった場合は、必要性と影響を実装前レビューへ追加する。

## 10. 検証と出荷条件

実装テストは別インストール・別チーム・偽agyで行い、稼働中の `airsurf` や通常のCLI認証を利用しない。
単なる環境変数の差し替えだけで隔離したとみなさず、既存の別インストール手順に従う。

1. 到着前はIDLE、到着後は1ターンが始まり、2通目はresult後に同じ会話へ入る。
2. バッファ分割、複数行、改行を含む本文、未知イベント、stderr大量出力を正しく扱う。
3. stdin途中切断、result前後、completed保存前後、ack前後に終了させ、未読消失と自動二重投入が起きない。
4. ack失敗はモデルを再実行せず、対象IDだけ再処理する。後着IDは未読のまま残る。
5. 二重起動・他role・別project・所有権移動・PID再利用・不明バッチ付き再起動を検査する。
6. monitor→turn/offでbridgeだけが止まり、他typeや他projectの監視は継続する。
7. ready未成立、busyのまま終了、承認拒否、再開不能を「正常配信」と表示しない。
8. Codex/Claude/Geminiの既存delivery・spawn・role-sessionテストを通す。
9. 実agyの限定試験では、専用roleで2通の文脈継続、idle再開、明示返信の履歴を確認する。実行は別途承認後とする。
10. 偽agyがBUSY中に実際の隔離 `inbox.sh` / `check-inbox.sh` を呼ぶケースと、引数なし `$agmsg` 相当の取得を試みるケースを追加する。
    バッチA投入後に後着Bを作り、両方のIDが未読のまま残り、違反が記録され、bridgeがNEEDS_ATTENTIONになることを確認する。
    worker側の終了コードだけを根拠にせず、その後SUCCESSやcrashが起きてもackされないことを調べる。
    同じ隔離storeで予約なしなら既読が進む陽性対照を置き、検査が空振りしていないことを示す。
11. 隔離fixtureでstore側だけを先に既読化したuncertain状態を作り、stateのID/本文から明示再投入・明示ackを選べることを検査する。
    自動再投入も「未読0だから解決済み」という判定も行わない。
12. Linuxを初回対応環境とし、Windows/macOSはパス・プロセス・Bash差分を検証するまで対応済みと記載しない。

## 11. リスク、保留事項、レビュー観点

初期版でも中規模の追加となる。
プロセスadapterだけなら小さいが、既読確定と異常終了の境界が信頼性を決める。
新しい永続キューや汎用bridgeフレームワークは作らず、単一バッチ状態に限定する。

実装前に解決する点:

- `--conversation` とstream-jsonでの再開が同じ会話を維持すること。できなければ自動再起動を無効化し、明示停止を仕様にする。
- 初期コンテキストで必要なtoolが使え、承認拒否を運用者が理解できること。
- 単一バッチstateの保存とID単位ack、および第二書き手の機械的拒否が既存storage driver双方で成立すること。
- ack認可の親限定受け渡し、違反記録の保存不能時の停止、予約の解除順序を実装前レビューで具体化すること。
- mode設定マーカー、復旧コマンドの引数、上限値の妥当性。これらは提案値で、採用済み恒久仕様ではない。

grokには、状態遷移・再送判断・mode解除・ロール排他・既存typeへの影響を中心にPASS/BLOCKERのレビューを依頼する。
計画PASSは実装・commit・push・既存インストール更新の承認ではない。

## 12. 計画レビュー履歴

2026-09-05 18:50 JST、grokが初版をBLOCKERと判定した。
初版SHA-256は `7727c4a8573219f89f0a1fc33f11da1b3464304e3877946a9b96af816965ab43`。
指摘は「workerが既存inbox経由で既読を先に進める第二書き手を閉じていない」の1件。
5.1のtemplate分岐と共有既読入口の機械的guard、5.2のstateを正本とする復旧、検証10・11を追加した。
初版の「初期コンテキストだけで防ぐ」「予約中も手動inboxを許す」という設計を撤回し、予約中の既読はbridge ackに限定した。
再レビューは未完了。
agyの版は初回luna実測1.1.26として記録を維持し、grokから1.1.27への更新報告を受領したことを付記する。
