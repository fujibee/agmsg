# agmsg remote sync のセキュリティ特性

*[English](security.md) — **英語版が正典です。この日本語版は参考訳であり、両者が
食い違った場合は英語版が正しい。** セキュリティ上の判断は英語版を根拠にしてくだ
さい。*

この文書は、remote-sync プロトコルが何を守り、何を守らず、何を調べていないかを
述べる。RFC 3552 (BCP 72) が求める構造に従っている。その構造が、2番目と3番目を
暗黙にせず書き下すことを強制するからである。

検算する意図のある読者に向けて書かれている。**中心的な主張 —— 何が守られ、何が守
られず、なぜか —— には、このリポジトリの `file:line` を付けてある。** 特性の表の一
部の行は要約であり、引用を持たない。行がこのツリー以外の何かに乗っている場合は、引
用の代わりにそう書いてある(`age` フォーマット自体の性質なら `inherited`、与件とし
て扱うものなら `assumption`)。

これは、この段落がかつてしていた約束より弱い。以前の版は「すべての主張は citation
を持ち、無いものは assumption と印を付けてある」と書いていた。どちらの半分も偽であ
り、そしてその文自体が、文書についての引用のない主張だった —— この文書全体が拒もう
としている形そのものである。真の弱い約束のほうが、ここでは厳密に良い: セキュリティ
文書において、自分自身の厳密さについての偽の記述は、厳密である部分の信用まで落とす。

**主張していないこと:** 以下のすべての文が個別に分類されている、ということ。主張の
集合を導出して1つずつラベルを付けるのは本物の労力であり、`fujibee/agmsg#787` と
して起票してある。

引用がこの文書の言うとおりのことを言っていない場合、他のすべての主張も、再確認す
るまで未検証として扱ってほしい —— それが正しい対応であり、引用がここに在る理由で
ある。

`integration/remote` で測定した。引用はこのブランチの head で解決する。このブラン
チが変更するファイルは `docs/security.md` と `docs/security.ja.md` だけであり ——
コードは1行も動かない —— したがって以下のすべての `file:line` は、head でも分岐点
`452da72` でも同一のコードを指す。手元にあるほうで検証してほしい。

## 範囲

**範囲内:** このリポジトリの remote-sync プロトコルと参照メッセージサーバ ——
`server/`、`docs/spec/`、`docs/design/`。

**範囲外:** ホストされたサービス。この文書は対象としない。

**範囲内:** 受信した envelope に対する sync クライアントの扱い。ここに在る ——
`scripts/internal/sync-cipher.mjs` と `scripts/internal/remote-sync.mjs` —— そして
それが決めるダウングレードの問いは、先送りせず測定した。

## 攻撃者は誰か

RFC 3552 はこれを明示的に求めており、これなしでは以下の主張は無意味である。3種類
の攻撃者を考え、それらは同じだけ制約されているわけではない。

**A. メッセージサーバ。** honest-but-curious、あるいは完全に悪意がある。すべての
envelope を見て、保存し、再生・並べ替え・破棄でき、自分が生成できるものは何でも
捏造できる。`age-v1` プロファイルが狙う攻撃者であり、「読めない、偽造できない」と
いう主張が対象とする相手である。この文書のどこでも、信頼できるものとは*仮定しな
い*。

**B. 参加者とサーバの間のネットワーク攻撃者。** トランスポートが扱うものとし、こ
の文書の範囲外とする。以下のどれも、ネットワークが秘匿されていることに依存しない
—— `age-v1` では envelope の内容は送信前に既に保護されており、`cipher: "none"` で
はこの文書が扱うどの層でも保護されていない。

**C. identity が侵害された参加者。** その identity が属する epoch 宛のすべてを読
む。侵害より前に送られたメッセージも含む。「前方秘匿性について」を参照 —— これは
緩和されておらず、鍵の回転はその後に来るものだけを扱う。

**考慮しないもの:** 参加者のマシンが動作中にそこへアクセスできる攻撃者、サイド
チャネル、そして「メタデータは見える」という平明な記述を超えるトラフィック解析。

## 短い版

`age-v1` cipher プロファイルを選択した deployment について、**メッセージサーバは
参加者のメッセージを読むことも偽造することもできない。**

別々の2つの論証があり、2番目のほうがたいてい人を驚かせる:

- **読めない。** 復号には private identity が要る。サーバはそれを持たず、仕様は
  identity をサーバの外に置いている。
- **偽造できない。** 妥当な age ファイルの生成には受信者の**公開**鍵が要る。X25519
  の公開鍵暗号では、「鍵なしに偽造できない」は*公開*鍵なしに、という意味になる ——
  珍しい性質であり、この問いを決めるのはそこである。仕様はそれらもサーバの外に置
  いている。

その配置は**仕様上の要件**であって、現在のサーバがたまたまそう書かれている、とい
う類のものではない:

```
docs/spec/ref/age-v1-profile.md:342-345
  "Recipient public keys, private identities, recipient-set manifests, and
   epoch history are provisioned outside the message server over an
   authenticated, freshness-proving channel. Copying only the current private
   key is insufficient for history or rollback resistance."
```

**そして既定のプロファイルは `age-v1` ではない。** 上記を稼働中の deployment の性
質として読む前に、次の節を読んでほしい。

### 実装は仕様と一致しており、安価に確かめられる

コードが黙って別のことをしていれば仕様上の要件の価値は下がるので、これは仮定せず
測定した。サーバの実装を暗号に関わる語 —— `age-`、`AGE-SECRET`、`x25519`、
`recipient`、`decrypt`、`privateKey` —— で検索すると**7件**ヒットし、そのすべてが
プロファイル名として比較あるいは保存されている*文字列* `"age-v1"` である:

```
server/src/storage.ts:206     ["none", "age-v1"].includes(envelope.cipher)
server/src/storage.ts:891     ARRAY['none', 'age-v1']::TEXT[]
server/src/storage.ts:921     ARRAY['none', 'age-v1']::TEXT[]
server/src/provision.ts:102   ARRAY['none', 'age-v1']::TEXT[]
server/src/provision.ts:109   ARRAY['none', 'age-v1']::TEXT[]
server/src/protocol.ts:197    cipher_profile: z.enum(["none", "age-v1"])
server/src/storage.ts:269     (a comment)
```

サーバは `cipher` を不透明なラベルとして扱い、文字パターンに対してのみ検証する:

```
server/src/protocol.ts:13     const cipherPattern = /^[a-z0-9][a-z0-9._-]{0,63}$/;
server/src/protocol.ts:68     cipher: z.string().regex(cipherPattern),
```

これが正確に測っているのは、**`server/` に age の語彙が無い**ことである —— 実装も、
鍵の解釈も、復号経路も、recipient stanza を名指すものも無い。

そして測って**いない**ことと、その違いが重要である: サーバは不透明な blob を保存し
転送する。age 固有語の不在は、汎用バッファの中身については何も制約しない。この検索
は、決して名指さない鍵素材をたまたま保持しているサーバを排除できない。排除できるの
は、鍵を*扱う*サーバである。

鍵がそもそもそこに無いという主張は、この grep の発見ではなく**仕様上の要件**であ
る —— 上で引用した `docs/spec/ref/age-v1-profile.md:342-345`。両者は互いを支え、ど
ちらも他方を置き換えない: 仕様は鍵が別の場所で供給されると述べ、この検索はコードに
それが届いたとして使うものが無いと述べる。

1つのコマンドで再現できる:

```
grep -rniE '\bage-|AGE-SECRET|x25519|recipient|decrypt|privateKey' server/src --include='*.ts'
```

プロファイル名の比較でないヒットは、この節と矛盾する。その場合、上の2つの主張とも
矛盾するものとして扱うべきである。

## 特性の表を読む前に

読者がいずれ自分で見つける3つの事実。見つけた時点で、ここに書かれた他のすべての
価値が下がる。

### 1. 既定は `cipher: "none"`。エンドツーエンド暗号化は opt-in である。

```
docs/design/remote-sync.md:83-85
  "## No required keys
   `cipher: "none"` is the base, as the envelope spec already says. E2EE
   remains …"
```

この文書の「読めない」「偽造できない」というすべての記述は、`age-v1` を選択した
deployment についての記述である。選択していない deployment はそのどれも得ない。

### 2. ピア認証は運用者の責任である。

プロトコルの中に、鍵を人に結びつけるものは何もない。鍵配布を便利にしていたはずの
handshake は、意図的に削除された:

```
docs/design/remote-sync.md:93-94
  "What this removes is the machinery for making key distribution
   *convenient*: the `key request` / `key approve` handshake between two of
   your machines."
```

上で引用した「認証され、鮮度を証明できるチャネル」という仕様の要件は、**運用者に
対する**要件である。ある deployment がそれを満たしているかどうかは、このリポジト
リからは判定できない。

### 3. メタデータは保護されない。

誰が誰と、いつ、どれだけ話しているかはサーバから見える。envelope の宛先と時刻は、
サーバがメッセージを配送し順序付ける手段そのものであり、暗号化されていない。設計
のどの部分もそうだと主張していない。

## 特性

各行は、`age-v1` を選択した deployment について、行に別段の記載がない限り**攻撃者
A**(サーバ)に対して、**provided**、**not provided**、**out of scope** のいずれか
である。「not provided」はその特性が無く、それが分かっていることを意味する。「out
of scope」はこの文書が調べていないことを意味する —— 「not provided」の弱い言い方
ではない。

2行は A ではなく攻撃者 C についてのもので、そう印を付けてある。この表のどの行も
攻撃者 B についての主張ではない。

| 特性 | 状態 | 根拠 |
|---|---|---|
| メッセージ内容の秘匿性 | **Provided** | age X25519 暗号化。identity はサーバの外に在る (`docs/spec/ref/age-v1-profile.md:342-345`) |
| メッセージ内容の完全性 | **Provided** | **inherited** —— age 自身の AEAD であり、このツリーではなく age フォーマットの性質である。プロファイルは意図的に第2の AEAD 層を足していない (`docs/spec/ref/age-v1-profile.md:13`) ので、保証は age のものであり、確かめるには age を読む。サーバの digest は*その機構ではない* —— 下記参照 |
| メッセージ内容の偽造不可能性 | **Provided** | 受信者の公開鍵を要し、仕様はそれをサーバの外に置く (`docs/spec/ref/age-v1-profile.md:342-345`, `:58-63`) |
| ピア認証 | **Not provided** | プロトコルに鍵と人の結びつきがない (`docs/design/remote-sync.md:93-94`) |
| メタデータの秘匿性 | **Not provided** | **assumption**、しかも容易な種類のもの: サーバは envelope の宛先と時刻で配送し順序付けるので、それらを読む。引用を示さないのは、ツリーの中にそれを規則として述べたものが無いからである —— サーバが自分の仕事をすることから従う |
| 前方秘匿性 (攻撃者 C) | **Not provided** | recipient set は epoch 単位で不変 (`docs/spec/ref/age-v1-profile.md:88`)。後に侵害された identity はその epoch の履歴を復号する |
| 侵害後の回復 (攻撃者 C) | **Partial, by rotation** | 新しい epoch は新しい recipient set である。journal は回転と fingerprint を記録し、鍵は決して記録しない (`docs/design/remote-sync.md:103-104`) |
| ダウングレード耐性 (サーバによる強制) | **Provided by the spec's stanza rules** | Scrypt、SSH、plugin、その他すべての非 X25519 stanza が除外される (`docs/spec/ref/age-v1-profile.md:58-63`) |
| ダウングレード耐性 (クライアントが `cipher: none` を受理) | **Provided by every caller in the tree** | 2つの `configure` 呼び出しはどちらも `--cipher age-v1` と `--minimum-security e2ee-required` を一緒に渡し (`scripts/remote.sh:1280`, `:1758`)、3つ目は存在しない。拒否は `scripts/internal/remote-sync.mjs:1686`。`configure` を直接 `plaintext-allowed` で叩いた場合にのみ外れる |

### 前方秘匿性について

`age-v1` はこれを提供しない。理由は見落としではなく構造的なものである。`key_id`
は**不変の** recipient set を指す:

```
docs/spec/ref/age-v1-profile.md:88
  "A `key_id` identifies an immutable set of X25519 recipients and its private …"
```

時刻 T に侵害された identity は、その identity が属する epoch 宛のすべてのメッセ
ージを復号する。T より前に送られたものも含む。鍵の回転はこれから先の窓を狭めるが、
既に書かれたものを閉じはしない。

## `envelopeDigest` は署名ではなく、その必要もない

これはコードについて最も起こりやすい誤読なので、ここで明示的に閉じる。この digest
はサーバが自分自身のために計算する**鍵なしの SHA-256** である:

```
server/src/protocol.ts:221-238
  export function envelopeDigest(envelope: Envelope): Buffer {
    …
    return createHash("sha256")
      .update(…)
      .digest();
  }

server/src/storage.ts:307
  const digest = envelopeDigest(message.envelope);

server/src/storage.ts:189
  : record.digest.equals(envelopeDigest(message.envelope));
```

鍵を持たないので何も認証せず、envelope を持つ者なら誰でも自明に再計算できる。それ
は弱点ではない。**その仕事をしていないから**である。用途は `storage.ts:189` に在
る —— 同じメッセージ id が異なる内容で再送されたことの検出であり、サーバはそれを
拒否する。

誤った場所へ導く推論はこうである: *digest には鍵がない → 内容は保護されていない*。
破綻するのは2番目の段である。`age-v1` では、内容はサーバが見るより前に age 自身の
AEAD で保護されている。digest はその上に重ねられた帳簿であって、攻撃者と平文の間
に立つものではない。`cipher: "none"` では内容は保護されないが、それは上の第1節で
あって、digest の性質ではない。

## 受信時のダウングレード: 測定した。答えは2層に分かれる

**問い: `age-v1` に設定された参加者は、注入された `cipher: "none"` envelope を受理
するか。**

sync クライアントはこのリポジトリに在る —— `scripts/internal/sync-cipher.mjs`
(819行、完全な age 実装)と `scripts/internal/remote-sync.mjs`。したがってここで
答えられる問いであり、読むのではなく走らせて答えた。

**第1層 —— envelope を開く側はこれを決めない。** `openEnvelope` は envelope 自身の
`cipher` フィールドで分岐し、設定されたプロファイルを一切参照しない:

```
scripts/internal/sync-cipher.mjs:718-725
  export async function openEnvelope(input) {
    …
    const profile = cipherProfiles[envelope.cipher];
    if (!profile) throw new CipherStateError("unsupported_cipher", …);
    return profile.open(input);
  }
```

リポジトリ自身のテストベクタから作った well-formed な `cipher: "none"` envelope を
直接渡すと、**平文の projection を返す**。測定結果:

```
node -e '… sealEnvelope({…, cipher: "none", key_id: null, recipients: []}) …'
  ACCEPTED — openEnvelope returned the plaintext projection, with no reference
             to any configured profile
```

**第2層 —— 呼び出し側がこれを決め、拒否する。** 唯一の呼び出し箇所は、3つ上の検査
で守られている:

```
scripts/internal/remote-sync.mjs:1686
  (localPolicy.minimum_security_mode === "e2ee-required" && message.envelope.cipher === "none")
    -> status: "policy_violation", reason: "envelope violates effective policy"
```

したがって答えはこうである: **ダウングレードされた envelope は拒否される。cipher
の層ではなく、pull 経路のポリシー検査によって。** 保護は本物であり、そして平文まで
`if` 1つ分の距離しかない —— これは正確に知っておく価値がある。`openEnvelope` の将
来の呼び出し元がその検査を再現しなければ、注入された平文を黙って受理することにな
るからである。

`scripts/internal/remote-sync.mjs:1699` も見てほしい。設定されたプロファイルとの
一致を見る検査は `if (message.envelope.cipher === "age-v1")` の中でしか走らない。
`none` の envelope はその分岐にそもそも入らない。1686行が防御のすべてである。

### その2つの条件のうち、あなたを守るのは片方だけである

1686行は3つの選言を持つ1つの `if` であり、読者はそれを3つの防御と受け取る。1つで
ある:

```
scripts/internal/remote-sync.mjs:1684-1686
  !serverPolicy.accepted_envelope_versions.includes(message.envelope.v) ||
  !serverPolicy.write_allowed_ciphers.includes(message.envelope.cipher) ||
  (localPolicy.minimum_security_mode === "e2ee-required" && message.envelope.cipher === "none")
```

前の2つは `serverPolicy` を読む —— **サーバが宣言する値**である。攻撃者 A に対して
は何の価値もない。平文を注入したいサーバは、平文を許すポリシーを宣言する。これら
は設定ミスやバージョンのずれを捕まえるのには有用だが、攻撃に対してではない。

**3番目の選言が、敵対的なサーバに対する防御のすべてである。** その条件の中で、
`localPolicy` だけがサーバの供給しない項だからである。

### deployment はどうやって `e2ee-required` に至るか

仮定ではなく導出した —— このリポジトリにおける `remote-sync.sh configure` のすべ
ての呼び出しと、それぞれが渡すフラグ。

```
scripts/remote.sh:1280    --minimum-security e2ee-required --cipher age-v1
scripts/remote.sh:1758    --minimum-security e2ee-required --cipher age-v1
```

これが2つだけであり、検索は `docs/` を除いたツリー全体である —— 以前の版は
`scripts/` と `tests/` を見ており、それが支える文よりも狭く、さらに悪いことに
`server/test/` を落としたまま「テストも見た」と読める形だった:

```
grep -rn 'remote-sync\.sh' . --exclude-dir=docs --exclude-dir=.git \
  --exclude-dir=node_modules | grep configure

scripts/remote.sh:1280                a caller
scripts/remote.sh:1758                a caller
scripts/internal/remote-sync.mjs:29   a usage string
```

`server/test/sync-client.integration.test.ts` は `...args` を転送する汎用ヘルパを
通して `remote-sync.sh` を呼んでおり、原理的には `configure` を呼びうる。呼んでい
ない —— そのファイルに `configure` は0件である。

**したがって、このリポジトリのどのコードを通って `age-v1` に到達するマシンも、
`e2ee-required` を同時に設定せずにそこへ至ることはできない** —— 2つのフラグは両方
の箇所で一緒に渡されており、3つ目の箇所は存在しない。これは「既定が安全である」よ
り強い。安全でない組み合わせに至る、サポートされた道が無い。

`remote-sync.sh configure` を `--cipher age-v1 --minimum-security plaintext-allowed`
で直接叩けば、なお到達可能である。その組み合わせを禁じるものは何もない。ただ、こ
こにあるどのコード経路もそれをしない、というだけである。

2台目のマシンは別の経路で `age-v1` に至る。それも未解決のままにせず追跡した。
`remote.sh` の `cmd_pull` は、チームが宣言した cipher を `configure` を呼ばずに
binding へ写す (`scripts/remote.sh:916`) —— その時点でマシンは
`cipher_profile: "age-v1"` を持ち、自分自身の `minimum_security_mode` を持たない。

その状態では同期できない。メッセージを読むには `unlock` が要り、`cmd_unlock` は
`configure` の2つの呼び出し元の一方である:

```
scripts/remote.sh:1076   cmd_unlock() {
scripts/remote.sh:1280     bash "$SCRIPT_DIR/remote-sync.sh" configure \
scripts/remote.sh:1284       --minimum-security e2ee-required \
scripts/remote.sh:1285       --cipher age-v1
```

つまり pull 経路は対を迂回しない。1コマンド遅れてそこへ到達する。もう一方の呼び出
し元 `_remote_configure_keyed_team` (`scripts/remote.sh:1729`、`:1916` から到達)も
同じ2つのフラグを渡す。

これで集合は閉じている —— 上で導出したのと同じ2つの呼び出し元である。どちらも
`--minimum-security e2ee-required` と `--cipher age-v1` を**リテラル**として渡して
おり、上流の何かが別々に設定できる変数ではない。そしてどちらも、マシンが何かを読
めるようになる前に必ず通る経路の上に在る。

### それが特性の表にとって意味すること

その行は **provided by every caller in the tree** と読む —— 「out of scope」でも
なく、単に「conditional」でもない。リポジトリ全体で `remote-sync.sh configure` の
呼び出し元は2つ、どちらも対をリテラルで渡し、どちらもマシンが何かを読めるようにな
る前に通る経路の上に在る。

残る境界は狭く、名指しする価値がある: これが測っているのは**このリポジトリの中の**
呼び出し元である。`remote-sync.sh configure` を手で、あるいは自前のスクリプトから
呼ぶ者は、`--cipher age-v1` と `--minimum-security plaintext-allowed` を組み合わせ
られる。その組み合わせを禁じるものは何もない。ここで出荷されるものはそれを作らな
い。

## 調べていないこと

**ホストされたサービス。** 範囲外。

*(この節がかつて未解決のまま残していた `minimum_security_mode` の問いは測定済みで
ある。上の「deployment はどうやって `e2ee-required` に至るか」を参照。)*

## この文書が引用する仕様の古さについて

`docs/spec/ref/age-v1-profile.md` は **"Status: proposed (dogfood profile)"** と記
されており、最後に触れられたのは 2026-07-27、それを参照資料として整理したコミット
`1a56d8e docs: file superseded work as reference` による。`ref/` の下に在り、その
README はこう明言している: *"Nobody is building toward anything in a `ref/`
directory."*

これはそれを疑うに足る本当の理由なので、この文書が寄りかかっている2つの引用は、文
書の権威に頼らずコードに対して確かめた:

- **`:342-345`(鍵はメッセージサーバの外で供給される)。** 実装と整合しており、その
  文が主張するより強く整合している: サーバには age の実装がそもそも無い(「実装は
  仕様と一致しており、安価に確かめられる」を参照)。`server/` の中に、recipient 鍵
  を保持・中継・使用しうるものは何もない。
- **`:58-63`(X25519 stanza のみ。scrypt、SSH、plugin は除外)。** 強制されている。
  サーバではなくクライアントで:

```
scripts/internal/sync-cipher.mjs:277-281
  const activeType = fields[1] === "scrypt" || fields[1] === "ssh-rsa" ||
    fields[1] === "ssh-ed25519" || fields[1].startsWith("plugin-");
  …
  if (!stanzaIsGrease) malformed("age-v1 rejects active non-X25519 recipient stanzas");
```

したがって引用した2つの要件は、今日のコードで成立している。それでも読者はこのプロ
ファイル文書を*proposed* として読むべきであり、この文書が引用していない主張は未確
認として扱うべきである —— この文書が検証したのは、寄りかかっている2つであって、プ
ロファイル全体ではない。

## 付録: OWASP ASVS V6 mapping

ASVS を起点に作業する読者のための相互参照として提供する。この文書の背骨では
**ない** —— 実体は上に在り、両者が食い違う場合は上の節のほうが主張である。

| ASVS V6 area | この文書のどこが扱っているか |
|---|---|
| V6.1 Data classification | 「特性の表を読む前に」の項目 1 と 3 |
| V6.2 Algorithms | 特性の表。`docs/spec/ref/age-v1-profile.md:58-63`(X25519 のみ) |
| V6.2 Integrity | 「`envelopeDigest` は署名ではない」 |
| V6.4 Secret management | `docs/spec/ref/age-v1-profile.md:342-345`(供給はサーバの外) |
| V6.4 Key rotation | 特性の表の侵害後の回復。`docs/design/remote-sync.md:103-104` |

## この文書の確かめ方

すべての引用は `path:line` である。1つを検証するには、このブランチの head でも分岐
点でもよい —— コードはどちらでも同じである:

```
sed -n '342,345p' docs/spec/ref/age-v1-profile.md
sed -n '221,238p' server/src/protocol.ts
```

行番号は動く。引用がここに書かれた場所に着かない場合は、主張が誤っていると結論す
る前に、同じファイルを `452da72` で確認してほしい —— そして実際に誤っているなら、
それは報告する価値がある。この文書の残りは、その中で最も弱い引用と同じだけの価値
しか持たないからである。
