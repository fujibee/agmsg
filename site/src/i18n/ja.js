export default {
  meta: {
    title: "agmsg — CLI AIエージェント間のクロスエージェントメッセージング",
    description:
      "エージェント間の伝書鳩をやめましょう。Claude Code、Codex、Gemini、Copilotなどが、共有のローカルSQLiteファイル経由で直接メッセージをやり取りします。デーモンなし、ネットワークなし。",
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
    titleHighlight: "伝書鳩",
    titleLine2: "もうやめよう。",
    subtitle:
      "Claude Code、Codex、Gemini、Copilotなどが、共有のローカルSQLiteファイル経由で直接メッセージをやり取りします。デーモンなし、ネットワークなし。",
    copyInstallAria: "インストールコマンドをコピー",
    ctaGetStarted: "はじめる",
    ctaStarOnGithub: "GitHubでStar",
    worksAcross: "対応ツール",
  },
  howItWorks: {
    heading: "中継はもうやめて、エージェント同士で会話させよう。",
    subtitle:
      "あなたはずっとエージェント間のメッセージ仲介係でした。agmsgなら、共有のローカルSQLiteファイル経由でエージェント同士が直接会話できます。",
    before: {
      badge: "Before",
      heading: "あなたが伝書鳩に",
      youLabel: "あなた(伝書鳩)",
      body: "手動・遅い・抜け漏れあり。すべてのメッセージがあなたを経由します — あなたがボトルネック",
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
      "ドライバーレジストリから自動生成される、対応済みのCLIエージェント一覧です。新しいタイプを追加すればここに表示されます。",
    badgeSpawnable: "spawn可能",
    badgeMonitor: "monitor対応",
    status: {
      native: "native",
      bridge: "bridge",
      "rule-file": "rule-file",
    },
    blurbs: {
      "claude-code": "Anthropicのエージェント型コーディングCLI",
      codex: "OpenAIのターミナル向けコーディングエージェント",
      gemini: "GoogleのCLIコーディングエージェント",
      copilot: "シェルで使うGitHub Copilot",
      cursor: "Cursorのヘッドレス版CLIエージェント",
      opencode: "オープンソースのコーディングエージェント",
      "grok-build": "xAIのビルド/コーディングエージェント",
      hermes: "軽量なリレーエージェント",
      antigravity: "エージェント型のコーディング環境",
    },
  },
  showcase: {
    heading: "agmsgを使ったプロジェクト",
    subtitle: "共有のメッセージログを利用して実際の作業を連携させているプロジェクトやチームです。",
    desc: {
      agkanban:
        "agmsgと組み合わせて使うマルチエージェント向けかんばんタスクボード — カードの取得・移動・引き継ぎができる",
      "agmsg-office":
        "エージェント間のメッセージログを、舞台上でキャラクターが話しているかのように再生する — 各エージェントが順番に発言するキャラクターになる",
      "agmsg-viewer":
        "agmsgのメッセージ履歴をLINE風のチャットUIでブラウザ表示する",
    },
  },
  footer: {
    tagline: "agmsg — CLI AIエージェント間のクロスエージェントメッセージング",
  },
  langSwitcher: {
    label: "言語",
  },
};
