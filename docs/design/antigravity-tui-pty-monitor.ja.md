# Antigravity TUI PTY monitor 設計

状態: 実装・隔離実機試験済み。軽量画面モデル、端末サイズ同期、receipt構成規則の変更は再レビュー前で、pushは未実施。
作成者: luna。作成日: 2026-09-06（JST）。

## 1. 結論と根拠

agmsg の Antigravity 自動受信は、専用 wrapper が起動した `agy` の PTY を一元所有し、未読を安全な idle 境界で同じ TUI へ入力する方式とする。

既存の headless bridge は、別プロセスの `agy --input-format stream-json` に未読を渡す方式である。これは worker conversation には届くが、人間が見ている TUI の live context を更新しない。2026-09-06 14:03 JST の同一 conversation ID 実験で、headless の `mango` は成功した一方、TUI は先行 turn の `kiwi` だけを記憶していた。このため、conversation ID 登録と headless 再開を TUI 配信として使わない。

2026-09-06 14:45 JST から 14:48 JST に、使い捨て project `/tmp/agmsg-agy-pty-probe.13nFeO` の `agy 1.1.27` TUI を PTY 経由で起動して検証した。TUI conversation は `33044ac8-6b1d-4f7d-aea4-06b810cbe8c1` である。日本語の初回 turn は `READY`、外部配信を模した turn は `RECEIVED` を返し、後続 turn は更新後の記憶語 `kohaku` を返した。PTY 入力は同じ live TUI conversation へ反映される。

一方、TUI の入力欄に `DRAFT:` が残る状態で外部入力を注入すると、画面上では `DRAFT:INCOMING` と連結した。送信済みの外部メッセージだけでなく、人間が書きかけの内容を壊すため、入力欄を観測せずに注入してはならない。

この検証は、PTY で起動した TUI へ同じ PTY から逐次入力したものに限る。raw transcript、TUI PID、relay 中の人間入力との多重化は保存・実測していない。従ってこれは方式選定の根拠であって、実装の合格証跡ではない。§10 の隔離実機試験で、raw transcript、child PID/start token、conversation ID、terminal attach 状態を保存して再検証する。

現行 `agy 1.1.27` の公開 CLI には、稼働中 TUI の conversation を発見し、そこへ turn を開始する API は確認できなかった。`--conversation` と Remote Control はこの用途の API として扱わない。従って wrapper を経由せず起動した既存 TUI は初期実装の monitor 対象外とする。

## 2. 範囲

対象は Linux の新規起動 TUI 一つと、対応する一つの `project/team/role` である。起動例は次とする。

```text
bash scripts/drivers/types/antigravity/antigravity-tui-monitor.sh \
  --project <absolute-project> --team <team> --name <registered-role>
```

このコマンドは PTY を作成し、`agy` をその slave 側で起動し、ユーザー端末と agmsg bridge の両方を master 側で仲介する。通常の `agy`、既存の `spawn antigravity`、headless 用 `antigravity-monitor.sh` は変更しない。TUI monitor は明示起動に限定し、`delivery.sh set monitor` は設定と起動方法の案内だけを行う。

対象外は、既存 TUI の takeover、別 terminal の画面走査、tmux の既存 pane への `send-keys`、Desktop/Remote Control の操作、複数 TUI への一つの inbox の fan-out、Windows/macOS、未確認の permission 画面の自動応答である。

## 3. 構成

```text
人間の terminal stdin ─┐
                         ├─ TUI PTY supervisor ─ PTY master/slave ─ agy TUI
agmsg unread snapshot ──┘          │
                                    ├─ durable state / reservation
                                    └─ inbox-transport peek / ack
```

PTY backend には Python 3 の標準ライブラリ `pty` と `termios` を採用する。agmsg には既存の Python 3 事前検査があり、追加パッケージや native build を導入しない。stdout を pipe にする実装は TUI の端末制御列、サイズ通知、貼り付けモードを失うため採用しない。supervisor は child の stdin/stdout を直接所有し、親 terminal の raw input を relay する。起動前に親 terminal の `TIOCGWINSZ` を child PTY へ `TIOCSWINSZ` で設定し、親の `SIGWINCH` ごとに同じ同期と child への通知を行う。PTY は入れ子間で端末サイズを自動継承しないため、この同期を起動条件とする。

`antigravity-tui-monitor.sh` は引数検証と Linux/TTY 検証だけを行い、supervisor を `exec` する。supervisor は `actas_lock_claim` と既存の bridge reservation を利用し、同じ role を headless bridge、turn rule、別 supervisor が同時に既読化できないようにする。reservation は既存 ack 認可に必要な `owner`、`pid`、`start`、`state`、`actas`、`violations`、`capHash` をすべて持つ。ack transport は supervisor の直接の子として起動し、capability を fd 3 だけで渡す。これにより `parent.ppid===reservation.pid`、PID/start token、capHash、batch ID 集合の既存検査を満たす。capability は agy child や人間入力を読む relay へ継承しない。

## 4. 状態と既読処理

既存の `inbox-transport.sh` と `bridge-read-guard.mjs` を再利用する。未読取得と既読化の順序は変更しない。

```text
IDLE
  → peek
  → prepared を永続化
  → 注入待ち
  → PTY へ paste + Enter
  → sent を永続化
  → TUI turn 完了を確認
  → completed を永続化
  → ack（保存済み ID だけ）
  → IDLE
```

state file は `$SKILL_DIR/run/antigravity-tui-pty.<encoded-project>.<encoded-team>.<encoded-role>.state.json` とする。三つの key は既存 `_actas_lock_encode` と同じエンコードを必須とする。schemaVersion、project、team、role、owner、PTY child PID/start token、supervisorPhase、batch、注入時刻、完了検出の証拠を保存する。本文は既存 headless state と同様に最小限だけ保存し、通常ログには書かない。

`supervisorPhase` と `batch.phase` は別軸であり、値を混用しない。前者は `STARTING`、`WAITING_FOR_IDLE`、`PREPARED`、`INJECTED`、`WAITING_FOR_RESULT`、`ACK_PENDING`、`STOPPING`、`NEEDS_ATTENTION` とする。後者は既存 ack 認可と完全に一致する小文字の `prepared`、`sent`、`completed`、`uncertain` だけである。ack の直前に `batch.phase==='completed'` と、保存済み `messages[].id` 全件を再照合する。

`PREPARED` 以降で supervisor が停止・終了・再同期不能になった場合は batch を `uncertain` として保持し、自動再送・自動 ack を行わない。既存の `--action ack|replay` と同等の明示復旧を、TUI 向けにも batch ID と ID 集合の照合つきで提供する。

## 5. 注入を許す条件

PTY の bytes だけでは「入力欄が空」「モデルが idle」「承認待ちではない」を完全には判別できない。初期実装では false positive を避けるため、次のすべてを満たす場合だけ注入する。

1. supervisor が起動した child の PID/start token が一致している。
2. 起動後の初期化 turn、または直近の人間入力のいずれかに対応する TUI の完了マーカーを一度観測している。
3. 直近の TUI 画面状態が、対応バージョンの idle prompt signature と完全一致する。
4. input buffer の内容が空であることを、端末プロトコル上の消去・cursor 更新を含めて確認できる。
5. permission、trust、選択 UI、slash-command picker、生成中、エラーの signature がなく、alt-screen切替後の完全な通常idle描画を観測している。
6. supervisor が前回注入した batch を持たない。

条件のどれかが不明なら `WAITING_FOR_IDLE` に留める。一定時間の経過だけで「idle と推定」してはならない。`agy 1.1.27` の実測では、通常 idle は最下部の空 prompt `>` と `? for shortcuts` footer の組であり、trust UI は `Do you trust the contents of this project?` と選択肢、permission UI は `Requesting permission for:` と選択肢、生成中は `Generating...` と `esc to cancel` footerを表示する。supervisorはブラックリスト語句を画面全体から探さず、最下部が実測済みの通常 idle signatureに一致する場合だけ許可する。これにより過去の会話本文にUI文言が含まれても停止せず、選択UI・生成中・エラー・alt-screen切替中は通常idleとして扱わない。slash-command pickerは実transcript未採取のため、通常idleと一致しない限り保留する。通常の人間入力を観測した直後は直交フィールド `humanInputActive=true` として自動注入を止める。live経路では、その後に通常idleではない画面を一度観測し、stdinとPTY masterに未処理がなく、実測済みの通常idleが連続した安定期間にわたって成立し、未解決batch・`manualResumeRequired`・`durableAttention`・violationsがない場合だけ自動解除する。古いidle表示のまま終わるEscは解除しない。再起動経路は別条件とし、通常入力由来の一時状態だけを、新しいTUIで通常idleを再観測できた場合に解除する。既存の `manualResumeRequired=true` は明示resume専用の耐久ラッチとして意味を変えず、自動解除しない。終了時に prepared batch があれば `uncertain` として停止する。

`agy 1.1.27` は起動から終了までalternate screenを通常画面として使用する。したがってalternate screenに居ること自体は拒否条件にしない。`?47`、`?1047`、`?1049` の切替を観測した瞬間に旧画面モデルを破棄し、切替後の完全な通常idle描画を再び観測するまで保留する。注入する bracketed paste envelope は CR（Enter）で終わるため、通常idle以外へ送れば許可・選択UIを確定しうる。`peek` と prepared state の保存中にも画面は変化しうるため、注入直前に通常idle signatureを再評価し、PTY masterに未処理のchild出力または親terminalに未処理の人間入力があれば、batchをpreparedのまま保留する。これにより画面モデルを確認した後にpermission・trust・選択UI・生成中へ遷移した場合、末尾のEnterを送らない。

screen parser の完了 marker は ack の十分条件ではない。現行実装では、画面上の完全なreceipt、error・cancel・interrupt signature の不在、未対応terminal制御列がないこと、および凍結済み本文に同じreceipt全体が含まれないことを同時に要求する。receiptリテラルはenvelopeへ含めず、構成規則だけを指示する。注入したenvelopeのechoを画面から消し込む照合は、§11の来歴保持に関する制約のため未実装である。どれかを判別できないバージョンでは自動 ack を有効にせず `NEEDS_ATTENTION` にする。

初期対象の `agy` バージョンは、実測済みの 1.1.27 のみに固定する。`agy --version` が異なる場合は signature を信用せず開始前に停止する。バージョン追加は、実 TUI の idle、生成中、入力途中、permission、trust、resume の transcript を fixture 化してから行う。

## 6. 注入形式と受領確認

本文を keystroke 単位で流すと IME と入力途中状態に干渉する。bracketed paste を使い、明示的な inbox envelope を一塊で貼り付け、最後に supervisor が Enter を一度送る。

```text
[agmsg batch id=<uuid> count=<N>]
[agmsg message id=<message-id-1>]
from: <sender-1>
at: <JST timestamp-1>
body:
<body-1>
[/agmsg message]
[agmsg message id=<message-id-2>]
from: <sender-2>
at: <JST timestamp-2>
body:
<body-2>
[/agmsg message]
[/agmsg batch]
```

本文に端末制御列を混ぜないため、supervisor は control byte を表示可能な形式にエンコードする。agent には envelope を通常の受信メッセージとして扱い、返信が必要なら既存 `send.sh ... --stdin` を使うよう template で指示する。

batch 内の `messages[]` は envelope の message block と ID で一対一に対応する。envelope の count、各 ID、順序、本文ハッシュを prepared state と照合し、一件でも不一致なら注入しない。

PTY への書込成功は受領確認に使わない。注入後、supervisor は agy が出力した端末制御列を軽量画面モデルへ適用し、画面上の完全な receipt を照合する。狭い端末では agy のレンダラが論理一行を複数の連続した物理行へ折り返すため、空行をまたがない連続行を連結して UUID を含む receipt 全体と一致するときも同じreceiptとして扱う。ただし、凍結済みの受信本文が同じ規則でreceipt全体を含む場合は、画面上の一致が本文由来か区別できないためfail-closedとしackしない。receiptのリテラルはenvelopeへ含めず、英字 `AGMSG_RECEIVED`、ASCIIコロン（U+003A）、batch idを空白なしで連結する構成規則だけを指示する。これはuuid4のbatch idを知る前の事前構成を防ぐが、画面セル上での合成不可能性までは保証しない。

安全境界は、画面モデルへ入力される端末制御列を出力できる主体をagy childに限定することに置く。人間の入力byteはPTY masterへ転送するだけで画面モデルへ直接入力せず、外部メッセージ本文のESCは表示可能な文字列へ無害化する。agyのレンダラがenvelope上のglyphをreceiptへ意図的に再配置しないことを信頼する。この境界を崩す本文ESCの素通し、人間入力の`screen.feed()`、agy以外の出力の混入を禁止する。

注入後にhuman inputを観測した場合は原則として`NEEDS_ATTENTION`にして自動ackしない。例外として、実測済みの permission または trust modal の footer・選択肢・見出しが同時に画面下部で一致する場合だけ、利用者の確認入力をそのままPTTYへrelayする。この例外では `humanInputActive` だけを立て、既存の `manualResumeRequired=true` には触れず、新たに立てない。現在のbatchは同じreceiptだけを待ち、画面上の完全なreceiptを確認できた場合だけackする。ackとbatch消去後はlive経路の安全条件を満たした場合だけ `humanInputActive` を自動解除する。error、cancel、interrupt、permission、pickerはreceipt行より画面上で後ろに残っている場合だけ補助的に検査し、上書き済み表示は検知できない。receiptが無ければackしない。受信turn中のresizeまたは未対応制御列は画面を`uncertain`にし、receiptが見えてもackしない。待機中のresizeは画面モデルとidle判定を初期化し、同期後に新しいidle描画を観測してから注入を再評価する。

permission modal は、最終行の `esc to cancel...` だけで判定しない。識別子は、その直前に `↑/↓ Navigate · tab Amend...` が隣接すること、見出し、選択肢の同時一致である。agy 1.1.27 の生成中 UI は同じ最終 footer を持つが、footer の直前は `>` と罫線であり Nav 行ではない。この観測済みの画面配置により、受信本文に permission の語句や Nav 行が含まれても、生成中 chrome を伴う画面では確認入力を relay しない。画面配置を変える agy の版を使う場合は、実画面を採取してこの判定を再検証する。

agy 1.1.27 の `Read` 表示では、`CSI ?5W`（DECST8C、8列ごとのtab stop初期化）と `CSI Z`（CBT、逆方向tab移動）が出る。画面モデルは既定tab stopとしてこの二つだけを扱う。ほかの `W`、private な `Z`、および未対応の制御列は引き続き`uncertain`にして、receiptをackしない。

これは「モデルが業務を理解した」ことの保証ではない。agmsg の既読は TUI が受信 turn を終えたことだけを表す。

## 7. 人間入力と衝突時の動作

human input は常に先に PTY へ転送する。supervisor は人間入力を取り消し、書き換え、遅延送信しない。外部 batch が `PREPARED` または `WAITING_FOR_IDLE` の間に人間が任意のキーを入力した場合、idle 判定を無効化して `humanInputActive=true` を立てる。`supervisorPhase` とbatch phaseは変更しない。その後、live用の非idle再観測と安定idle条件を満たした場合だけ一時状態を解除する。`manualResumeRequired=true`、`durableAttention=true`、未解決batch、violationsのいずれかがある間は解除しない。

`INJECTED` または `WAITING_FOR_RESULT` の間に human input byte を一つでも観測した場合、その batch を `uncertain` にして `NEEDS_ATTENTION` へ移る。ただし、上記の実測済み permission/trust modal が画面下部で確認できる場合の確認入力だけは例外とする。入力は TUI へ転送し、`humanInputActive=true` にして後続batchを止める。本文が単独の `>` 行と直後の `? for shortcuts` 行を含む場合も、本文と画面chromeの文字列来歴は区別できないため、ack後に `manualResumeRequired=true` として後続batchを止める。`manualResumeRequired=true`、`durableAttention=true`、未解決batch、violationsのいずれかがある間は解除しない。Ctrl-C、Esc、Enter を含むため、modal確認なしの入力ではturnの中断と画面上の正常復帰を混同しない。

入力途中に注入候補があっても、通知ベル、画面外ログ、prompt の追記では代替しない。TUI と会話の一貫性を壊さないことを優先し、保留状態を terminal の status line へ本文なしで表示する。

permission または trust UI を検知した場合は、ユーザーが TUI 上で完了・取消するまで batch を保留する。supervisor は許可キー、Y/N、Esc、Enter を自動送信しない。`INJECTED` 後にこれらの UI を検知した場合は batch を uncertain にする。検知不能な画面変化は `NEEDS_ATTENTION` とし、復旧コマンドで人間が batch を ack または replay する。

予約中の TUI では bare `$agmsg`、`inbox.sh`、`check-inbox.sh` を通常受信に使わない。template の TUI-monitor 分岐はこれらの代わりに、既読化しない `tui-monitor status` を案内する。この状態表示は supervisor が保持する prepared batch の ID、送信元、到着時刻だけを返し、本文を再表示しない。agent または人間が通常の inbox 経路を実行して read-denied が記録された場合、これは第二書き手の試行として violations latch の対象に残す。supervisor は `NEEDS_ATTENTION` にして ack しない。headless と同じ既読ガードを緩めない。

read-denied latch の後に supervisor が終了した場合、`agy-tui reset-guard --team <team> --name <role>` を明示実行して復旧する。この操作は、state の project/team/role が一致し、batch が phase にかかわらず存在せず、対象 identity の予約がなく（stale な予約を含む）、TUI supervisor が稼働しておらず、actas 排他を取得できた場合だけ violations latch を解除する。headless bridgeなど別kindの予約や壊れた予約情報が残っている場合も拒否する。未読メッセージと ack 状態は変更しない。条件を満たさない場合は fail-closed とし、通常の `resume` では代用しない。

## 8. 起動・停止・モード変更

起動前に、role の登録、monitor marker、TTY、`agy 1.1.27`、PTY backend、既存 reservation、未解決 batch を確認する。いずれかが失敗したら agy を起動しない。

`delivery.sh set turn|off antigravity <project>` が active TUI supervisor を検知した場合、TUI を外部から終了させず失敗する。利用者は入力欄を空にしたことを確認した後の再開に `antigravity-tui-monitor.sh resume`、TUIを閉じる意思の明示操作に `antigravity-tui-monitor.sh stop --project ... --team ... --name ...` を使う。停止中の batch は ack せず state に残す。headless bridge と TUI supervisor は同じ reservation namespace を使い、相互に起動を拒否する。

正常停止は、新規 `peek` を止め、current turn がないことを確認し、child に EOF を送って終了を待つ。timeout 後に signal を送れるのは、起動時の child PID/start token が一致する child だけとする。reservation と actas lock は所有者一致を再検証してから解放する。`antigravity-mode.mjs status` は headless state と TUI PTY state を別名で表示し、mode 変更前の active TUI supervisor を識別できるようにする。

## 9. 実装候補

| ファイル | 役割 |
|---|---|
| `scripts/drivers/types/antigravity/antigravity-tui-monitor.sh` | 明示起動、TTY/Linux 検証、supervisor exec |
| `scripts/drivers/types/antigravity/antigravity-tui-supervisor.py` | Python標準ライブラリのPTY、`TerminalScreen`によるversion固定の画面parser、入力仲介、batch state、停止 |
| `scripts/drivers/types/antigravity/inbox-transport.sh` | capability・reservation 対応済みの `peek`/`ack` を無変更で再利用するか、TUI専用 status を最小追加するかを確認 |
| `scripts/drivers/types/antigravity/_delivery.sh` | monitor 起動案内と、active TUI を検知した turn/off 変更の拒否 |
| `scripts/drivers/types/antigravity/antigravity-mode.mjs` | headless と TUI PTY の runtime/status を区別し、mode変更前に active TUI を報告 |
| `scripts/drivers/types/antigravity/template.md` | TUI monitor 中の受信・返信・permission の指示 |
| `tests/antigravity_tui_supervisor.test.mjs` | 偽 PTY/TUI transcript による状態機械の検証 |

`antigravity-bridge.mjs` は headless 専用の既存動作を保つ。TUI supervisor との共通化は、reservation、state atomic write、transport のみとし、stream-json と terminal transcript を同じ parser に混ぜない。

## 10. 検証計画

1. 偽 PTY で、idle signature が完全一致するときだけ bracketed paste と一度の Enter が出ること。
2. 入力途中、生成中、permission、trust、picker、未知画面では注入せず batch を保持すること。待機中のresize後は画面モデルを初期化して親terminalとchild PTYのサイズ一致および新しいidle描画を確認してから注入を再開し、受信turn中のresizeではbatchを`uncertain`にしてackしないこと。
3. injected 後の任意の human input、error、cancel、interrupt、completion signature欠落では `uncertain` となり、自動 ack・自動 replay をしないこと。
4. `peek → batch.phase=prepared → sent → completed → ack` の順序、supervisorPhaseとの分離、ack が保存済み ID だけに限られること。
5. 最大20件の batch envelope が全 message ID、本文、送信元、時刻を一対一に表し、ID/hash/count不一致を拒否すること。
6. bare `$agmsg` / inbox 経路の read-denied が violations latch となり、TUI supervisor が ack せず `NEEDS_ATTENTION` へ移ること。TUI-monitor status は既読化しないこと。
7. headless bridge と TUI supervisor の同時起動を互いに拒否し、既存 `tests/antigravity_bridge.test.mjs` と `tests/test_delivery.bats` が回帰しないこと。
8. active TUI のある turn/off mode変更が拒否され、明示 stop 後だけ rulefile を更新すること。headless と TUI の status を区別して表示すること。人間入力直後の古いidle描画、安定期間未満、未解決batch、旧 `manualResumeRequired`、`durableAttention`、violationsでは注入せず、liveの非idle再観測後または再起動後の新しいidle再観測後だけ通常入力の一時停止を自動解除すること。permission/trust確認後はreceiptとackを維持し、batch消去後に同じlive条件で自動復帰すること。
9. 実機では使い捨て project・別 role・限定本文で、idle 受信、文脈保持、relay中の人間入力、入力途中保留、permission 保留、stop/restart、送信元への返信まで確認すること。
10. 実機の表示を screenshot と raw PTY transcript の両方で保存し、child PID/start token、conversation ID、terminal attach状態、現在 TUI に届いたことを人間が確認すること。

2026-09-06の隔離実機試験では、使い捨てproject `/tmp/agmsg-agy-screen-e2e-np6JfK/project`、隔離SQLite、`agy 1.1.27`を使用した。batch `46e6cd17-ccca-4dae-8a91-da567d993adc`について、trust後の明示resume、注入、差分描画されたreceiptの画面復元、ack、停止後の`No new messages.`を確認した。agy child PIDは`3867910`、start tokenは`3820534`、stdinは`/dev/pts/6`で、raw transcriptは`/tmp/agmsg-agy-screen-e2e-np6JfK/raw-pty.transcript`へ保存した。保存済みtranscriptを67 byte単位で再生してもreceipt行を復元し、注入後の未知制御列が無いことを確認した。conversation IDとscreenshotはTUI出力から取得できず、この試験の未取得項目として残す。

設計変更と実装は同じcommitへ記録し、fake PTYのテスト、隔離storeのend-to-end、実機TUIの限定試験を通した後、そのcommitを独立レビューへ提出する。pushの可否はレビュー結果を見て判断する。

## 11. 未解決事項

- slash-command pickerの実transcriptは未採取。idle、trust、permission、生成中は匿名化した実画面断片を `tests/fixtures/agy-1.1.27-screen-transcripts.json` に固定済み。
- ack前に注入したenvelopeのechoを画面から消し込む照合は未実装。現行の軽量画面モデルは最終セルだけを保持し、文字ごとの「envelope由来」「モデル応答由来」の来歴を保持しない。折り返し、再描画、cursor移動をまたぐ消し込みは、現在の証拠では安全に実装できない。receiptリテラルをenvelopeへ含めないこと、本文内の同一receiptをfail-closedで拒否すること、および未知terminal制御列をuncertainにすることを当面の境界とする。
- 将来の代替案として、注入直後の画面を行単位でsnapshotし、ack照合時に変化していない行を除外する方式を実測する余地がある。注入前から残るreceipt行には効く可能性があるが、agyが画面全体を再描画する場合の有効性は未確認であり、provenance追跡を導入する前に隔離実機で評価する。
- §5 条件5は、既知語句を画面全体から探すブラックリストでは実装しない。最下部の空promptとfooterから成る実測済み通常idle signatureだけを許可し、permission、trust、生成中、picker、error、切替中の画面は通常idleと一致しない限り保留する。slash-command pickerは実transcript未採取であり、対応バージョンを広げる前に採取と回帰試験が必要である。狭い端末幅は40列×24行で採取済みで、agy 1.1.27のfooter右側statusは物理行へ折り返る。通常idleとpermission UIのfooter/NAV判定は、footer本体と実測済み64セル以内のstatusに必要な最下部物理行だけを論理行として照合する。対応バージョンを広げる前には再採取する。
- terminal emulator ごとの差、IME、tmux/SSH、alternate screen の観測範囲。
- alternate screen切替後の画面再構築が、terminal emulatorごとに同じ制御列となるかは未確認。
- 未対応のIL/DL、SU/SD、DECSTBM、DSR、DAをagyがreceipt turnで使うと安全側に停止し、ack不能になる可用性リスクがある。
- user が既存 `agy` を直接起動した場合に、monitor wrapper の再起動へどこまで案内するか。

これらは実装前レビューで決める。未解決のまま signature を緩めたり、既存 TUI への best-effort 注入を追加したりしない。
