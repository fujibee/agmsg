export default {
  meta: {
    title: "agmsg — CLI AIエージェント間のクロスエージェントメッセージング",
    description:
      "エージェント間のコピペ係をやめよう。Claude Code、Codex、Gemini、Copilotなどが、共有のローカルSQLiteファイル経由で直接メッセージをやり取りする。デーモンなし、ネットワークなし。",
    ogImageAlt:
      "agmsg — CLI AIエージェントが共有のローカルSQLiteファイル経由でメッセージをやり取りする様子",
  },
  nav: {
    howItWorks: "仕組み",
    agentTypes: "対応エージェント",
    showcase: "ショーケース",
    docs: "ドキュメント",
    github: "GitHub",
  },
  hero: {
    badge: "★ Product Hunt #5 Product of the Day",
    titleLine1: "エージェント間の",
    titleHighlight: "コピペ係",
    titleLine2: "をやめよう。",
    subtitle:
      "Claude Code、Codex、Gemini、Copilotなどが、共有のローカルSQLiteファイル経由で直接メッセージをやり取りする。デーモンなし、ネットワークなし。",
    copyInstallAria: "インストールコマンドをコピー",
    ctaGetStarted: "はじめる",
    ctaStarOnGithub: "GitHubでスターする",
    worksAcross: "対応エージェント",
  },
  howItWorks: {
    heading: "中継はもうやめて、エージェント同士で話させよう。",
    subtitle:
      "あなたはずっとエージェント間のメッセージバスだった。agmsgなら、共有のローカルSQLiteファイル経由でエージェント同士が直接会話できる。",
    before: {
      badge: "Before",
      heading: "あなたがコピペ係になっている",
      youLabel: "あなた(コピペ)",
      body: "手動・遅い・ロスあり。すべてのメッセージがあなたを経由する — あなたがボトルネックだ。",
    },
    after: {
      badge: "agmsgなら",
      heading: "エージェント同士が直接メッセージをやり取り",
      sharedLogLabel: "共有ログ",
      tagNoDaemon: "デーモンなし",
      tagNoNetwork: "ネットワークなし",
      tagRealTime: "リアルタイム",
    },
  },
  agentTypes: {
    heading: "対応エージェント",
    subtitle:
      "ドライバーレジストリから自動生成される、対応済みのCLIエージェント一覧。新しいタイプを追加すればここに表示される。",
    badgeSpawnable: "spawn可能",
    badgeMonitor: "monitor対応",
    status: {
      native: "native",
      bridge: "bridge",
      "rule-file": "rule-file",
    },
    blurbs: {
      "claude-code": "Anthropicのエージェント型コーディングCLI。",
      codex: "OpenAIのターミナル向けコーディングエージェント。",
      gemini: "GoogleのCLIコーディングエージェント。",
      copilot: "シェルで使うGitHub Copilot。",
      cursor: "Cursorのヘッドレス版CLIエージェント。",
      opencode: "オープンソースのコーディングエージェント。",
      "grok-build": "xAIのビルド/コーディングエージェント。",
      hermes: "軽量なリレーエージェント。",
      antigravity: "エージェント型のコーディング環境。",
    },
  },
  showcase: {
    heading: "agmsgを使ったプロジェクト",
    subtitle: "共有メッセージログ上で実際の作業を連携させているプロジェクト・フリート。",
    desc: {
      agkanban:
        "agmsgと組み合わせて使うマルチエージェント向けかんばんタスクボード — カードの取得・移動・引き継ぎができる。",
      "agmsg-office":
        "エージェント間のメッセージログを、舞台上でキャラクターが話しているかのように再生する — 各エージェントが順番に発言するキャラクターになる。",
      "agmsg-viewer":
        "agmsgのメッセージ履歴をLINE風のチャットUIでブラウザ表示する。",
    },
  },
  footer: {
    tagline: "agmsg — CLI AIエージェント間のクロスエージェントメッセージング",
  },
  langSwitcher: {
    label: "言語",
  },
};
