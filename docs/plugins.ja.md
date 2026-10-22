# プラグイン(外部ドライバー)

*[English](plugins.md)*

agmsgのプラグイン可能な単位は**ドライバー**であり、**軸(axis)**ごとにグループ化される:

| axis | 何を差し替えるか | status |
|---|---|---|
| `types` | エージェントランタイム(claude-code, codex, gemini, …) | shipping |
| `ext-tools` | チームメンバーになれる外部ツール(Slackなど) | shipping |
| `terminals` | ターミナルドライバー(tmux, herdr, …) | shipping |
| `storage` | メッセージストア(sqlite, …) | planned |
| `delivery` | メッセージがエージェントに届く方法(monitor / turn / …) | planned |

組み込みドライバーは `scripts/drivers/<axis>/<name>` 配下にツリー内で同梱される。**プラグイン**
とは、コアの*外側*で配布され、フォークもパッチも不要で置くだけのドライバーのことだ。本ドキュメントでは
それらの発見・信頼・作成方法を扱う。設計上の根拠は
[ADR 0002](adr/0002-driver-discovery-and-plugin-opt-in.md) に、ドライバーの契約は
[docs/spec/driver-interface.md](spec/driver-interface.md) にある。

## プラグインの置き場所

agmsgは次のベースを順番に探索する:

1. `<skill>/scripts/drivers/` — 組み込み(常に信頼される)
2. `<skill>/plugins/` — デフォルトのプラグイン配置ディレクトリ
3. `<skill>/db/plugin-sources` に記録されたインストール済みのプラグインソース(
   [GitHubからプラグインをインストールする](#githubからプラグインをインストールする) を参照)
4. `$AGMSG_PLUGIN_DIRS` の `:` 区切りの各エントリ — 追加ディレクトリ

`<skill>` はインストールディレクトリ(`~/.agents/skills/<cmd>/`)である。各ベースは
axisごとのサブディレクトリを持つため、`foo` という名前のtypesプラグインは
`<skill>/plugins/types/foo/` に置かれる(組み込みtypeと同じレイアウト — 詳細は
[Agent types](agent-types.md) を参照)。

同じ `<axis>/<name>` の**適格な**候補の中では、**後のベースが優先される**ため、
信頼済みのプラグインは組み込みを意図的に上書きできる(例: `codex` をローカルでカスタマイズする)。

## 信頼: 外部ドライバーはオプトイン

ドライバーはあなたの権限で実行されるシェルコードだ。そのためagmsgは、**明示的にオプトインするまで
外部ドライバーを一切読み込まない** — これにより、紛れ込んだ、あるいは悪意のあるプラグインが
コード実行のベクターになることを防ぎ、単なる無害な無視されたディレクトリにする。

- 組み込み(`scripts/drivers/`)は常に信頼される。
- `plugins/` または `$AGMSG_PLUGIN_DIRS` 配下のものは**信頼されるまで無視される** —
  レジストリが最初に実行された際にstderrへ一行の警告が出る:

  ```
  agmsg: external plugin 'types/foo' found at /…/plugins/types/foo but not trusted (ignored).
         Opt in if you put it there intentionally: agmsg plugin trust types/foo
  ```

- 信頼は**パスに紐付けられる**: allowlistは `<axis>/<name>` → 信頼した絶対パスを記録する。
  同じ名前のドライバーが*別の*パスで解決された場合は**信頼されない**ため、
  ディレクトリの中身を差し替えたり(あるいはより優先度の高いベースから覆い隠したり)しても、
  未レビューのコードが黙って有効化されることはない。したがって信頼済みプラグインを移動する場合は
  再度信頼し直す必要がある — これは意図的な摩擦だ。

allowlistは `<skill>/db/trusted-plugins` にある単純なTSVで(`config.yaml` と同様に
`--update` の際も保持される)。通常は以下のCLIで管理する。

## `agmsg plugin` コマンド

```
agmsg plugin list                 # every discovered driver + its trust state
agmsg plugin trust <ref>          # opt into an external driver
agmsg plugin untrust <ref>        # revoke
agmsg plugin install|update|remove ...   # GitHubから。下記を参照
```

`<ref>` は `<axis>/<name>`(例: `types/codex`)または裸の `<name>` である。裸の名前は
axisをまたいでマッチするため、複数のaxisに存在する場合は修飾する必要がある:

```
$ agmsg plugin trust codex
agmsg plugin: 'codex' is ambiguous across axes:
  types/codex
  storage/codex
       qualify it, e.g. agmsg plugin trust types/codex
```

`agmsg plugin list` は各ドライバーを `builtin`、`trusted`、`UNTRUSTED` のいずれかで示す:

```
AXIS/NAME                  STATE       SOURCE                       COMMIT        PATH
types/codex                builtin     -                            -             /…/scripts/drivers/types/codex
types/foo                  trusted     -                            -             /…/plugins/types/foo
types/bar                  UNTRUSTED   -                            -             /…/plugins/types/bar
types/baz                  trusted     github/acme/baz              9074a92c6404  /…/plugins/sources/github/acme/baz/9074…/types/baz
```

> Windows以外のホストでは、`agmsg` コマンドの表面はエージェントのskillフローによって提供される。
> スクリプトを直接呼び出すこともできる:
> `~/.agents/skills/<cmd>/scripts/plugin.sh list`。
> `install`、`update`、`remove` も同じ方法で使えるほか、エージェント内の `/agmsg plugin ...` でも使える
> (エージェントは何かをインストールする前にあなたへ確認する)。

## typesプラグインの作成

typesプラグインとは、`scripts/drivers/types/` の代わりに `plugins/types/<name>/` に置かれる
組み込みtypeそのものだ。最低限必要なのは `type.conf` マニフェストと `template.md` であり、
独自のdeliveryを実装する場合は `_delivery.sh` プラグを追加する。マニフェストのキー一覧全体と
deliveryのTemplate Methodは [Agent types](agent-types.md) にある。

```
<skill>/plugins/types/foo/
├── type.conf          # name=foo, template=template.md, hooks_file=…, delivery_modes=…
├── template.md        # the /agmsg command template (becomes SKILL.md)
└── _delivery.sh       # optional: override agmsg_delivery_apply / on_enable / …
```

その後、信頼して確認する:

```
agmsg plugin trust types/foo
agmsg plugin list          # types/foo -> trusted
```

マニフェストは**データ**として読み込まれ(決して `source` されない)ため、プラグインの
`type.conf` がコードを実行することはできない。実行されるのは `_delivery.sh` /
ランチャースクリプトのみであり、それもプラグインを信頼した後に限られる。

## GitHubからプラグインをインストールする

プラグインは独立したGitHubリポジトリとして公開でき、1つのコマンドでインストールできる。
この方法で入れるプラグインはサードパーティのコードであり、**自己責任でインストールすること。
agmsgはプラグインのレビューも署名も行わない。** バージョン1がサポートするのは `git` のみ
(アーカイブURLは不可)なので、`git` が必要である。

```
agmsg plugin install <owner>/<repo>[@<ref>] [--yes] [--override]   # alias: add
agmsg plugin update  <owner>/<repo>[@<ref>] [--yes] [--override]
agmsg plugin remove  <owner>/<repo>                                 # alias: uninstall
agmsg plugin list
```

`<ref>` はブランチ、タグ、または完全なコミットSHAである。省略するとデフォルトブランチを使う。
インストールと更新は、必ず先に内容を表示して確認を求める。端末がなく `--yes` もない場合は、
同じレポートを表示し、何もインストールせずステータス3("needs confirmation")で終了する。

**`install` の動作**

1. `https://github.com/<owner>/<repo>` の浅いチェックアウトをステージング用ディレクトリに取得する。
2. 検査する: `agmsg-plugin.conf` があること、使えるaxisは `ext-tools` / `terminals` / `types`
   のみ(それ以外は無視され、その旨が表示される)、ドライバー名が `[a-z0-9-]+` であること、
   シンボリックリンクがないこと、`min_core` がこのagmsgより新しくないこと、衝突がないこと
   (後述)。
3. ソースとコミット、追加される `<axis>/<name>`、実行されうるすべてのファイル(shebangまたは
   実行ビットがあるもの)、自己責任の注意を表示する。
4. `y/N` を尋ね(または `--yes`)、各ドライバーをインストールして信頼する。

チェックアウトは `<skill>/plugins/sources/github/<owner>/<repo>/<sha>/` に置かれ、
`<skill>/db/plugin-sources` に記録される。残るのは `agmsg-plugin.conf` とドライバーのディレクトリ
だけである。`plugins/sources/` はこれらのコマンドが管理するので、手作りのプラグインを置かないこと。

**コミットは固定される。** ディレクトリ名がコミットSHAで、信頼はパスに固定される(上記)ため、
信頼はそのコミットそのものに結び付く。`update` は同じ指定をもう一度取得する: コミットが同じなら
その旨を表示し、新しければ旧SHAと新SHA、追加・変更・削除されたファイルを表示して再度確認する。
確認した後にだけ新しいコミットを信頼し、古い方を削除する。自動更新は一切ない
(`install --update` でも、バックグラウンドでも更新しない)。自分で固定したい場合は
`<owner>/<repo>@<完全なSHA>` をインストールする。エージェントがコマンドを実行する場合は、
レポートを見せてチャットで確認し、表示したコミットに固定して
`plugin install <owner>/<repo>@<sha> --yes` を再実行する。

**衝突。**

- 他のインストール済みソース、または `plugins/` に手で置いたドライバーと同じ `<axis>/<name>` は、
  双方を示して拒否される。
- **組み込み**と同じ `<axis>/<name>`(例: `types/codex`)は、このマシンのすべてのチームで
  組み込みを置き換えてしまう。`install` は停止し、何が置き換わるか、何が壊れうるか、
  `plugin remove` で組み込みに戻ることを説明する。意図して進めるには `--override` を付ける。
  `update` が `--override` を求めるのは、インストール済みのコミットがまだ置き換えていなかった
  組み込みに限る。

**`remove`** はそのソースのドライバーの信頼を外し、チェックアウトと記録を削除し、組み込みが
再び使われる場合はその旨を表示する。

**`agmsg-plugin.conf`** は `key=value` のデータである(`source` されない):

```
name=my-plugin
description=What it adds
min_core=1.6.0
```

`name` と `description` はレポートに表示される。`min_core` は任意で、実行中のagmsgより新しい
場合はインストールが拒否される。

**リポジトリの構成**

```
<repo>/
├── agmsg-plugin.conf
├── ext-tools/<tool>/...      # scripts/drivers/ext-tools/README.md と同じ契約
├── terminals/<name>/...      # 組み込みterminalドライバーと同じ契約
└── types/<name>/...          # agent-types.md と同じ契約
```

`storage` プラグインは、GitHubからはまだ受け付けない。プラグインのagent typeは従来のdelivery
経路で配信され、agmsgdのネイティブ配信には乗らない。

> ここで扱うのは**agmsgプラグイン**(ドライバー)である。agmsg自体の配布方法の1つである
> *Claude Codeプラグイン*とは別物である。

テスト用に、`AGMSG_PLUGIN_GIT_BASE` でクローンURLの `https://github.com` の部分を置き換えられる
(例: ローカルの `file://` ディレクトリ)。

## 未サポート

署名とサンドボックス化は先送りされている([ADR 0001](adr/0001-storage-driver-pluginization.md) §5 と
[ADR 0002](adr/0002-driver-discovery-and-plugin-opt-in.md) を参照)。アーカイブURLからの
インストールと、`storage` プラグインのインストールも同様である。プラグインとは、パス(GitHubから
入れた場合はコミットも)で信頼するコードである。
