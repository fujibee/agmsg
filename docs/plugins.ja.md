# プラグイン(外部ドライバー)

*[English](plugins.md)*

agmsgのプラグイン可能な単位は**ドライバー**であり、**軸(axis)**ごとにグループ化される:

| axis | 何を差し替えるか | status |
|---|---|---|
| `types` | エージェントランタイム(claude-code, codex, gemini, …) | shipping |
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
3. `$AGMSG_PLUGIN_DIRS` の `:` 区切りの各エントリ — 追加ディレクトリ

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
AXIS/NAME                  STATE       PATH
types/codex                builtin     /…/scripts/drivers/types/codex
types/foo                  trusted     /…/plugins/types/foo
types/bar                  UNTRUSTED   /…/plugins/types/bar
```

> Windows以外のホストでは、`agmsg` コマンドの表面はエージェントのskillフローによって提供される。
> スクリプトを直接呼び出すこともできる:
> `~/.agents/skills/<cmd>/scripts/plugin.sh list`。

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

## 未サポート

`plugin.json` メタデータ、`min_core_version` によるゲーティング、署名/サンドボックス化は
先送りされている([ADR 0001](adr/0001-storage-driver-pluginization.md) §5 と
[ADR 0002](adr/0002-driver-discovery-and-plugin-opt-in.md) を参照)。現時点でのプラグインとは、
パスを信頼するだけの単なるディレクトリである。
