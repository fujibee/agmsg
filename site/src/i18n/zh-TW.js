// Source-of-truth dictionary (English). Every other locale in this directory
// mirrors this exact key shape — see i18n/utils.js for the lookup contract.
export default {
  meta: {
    title: "agmsg — 讓 CLI AI 代理彼此通訊",
    description:
      "別再當代理之間的複製貼上信差。Claude Code、Codex、Gemini、Copilot 等透過共享的本機 SQLite 檔案互相傳訊。無需常駐程式，無需網路。",
    ogImageAlt:
      "agmsg — CLI AI 代理透過共享的本機 SQLite 檔案互相傳訊",
  },
  nav: {
    howItWorks: "運作原理",
    agentTypes: "代理類型",
    showcase: "案例展示",
    docs: "文件",
    github: "GitHub",
  },
  hero: {
    badge: "★ Product Hunt 當日產品 #5",
    titleLine1: "別再當",
    titleHighlight: "複製貼上信差",
    titleLine2: "在你的代理之間奔波。",
    subtitle:
      "Claude Code、Codex、Gemini、Copilot 等透過共享的本機 SQLite 檔案互相傳訊。無需常駐程式，無需網路。",
    copyInstallAria: "複製安裝指令",
    ctaGetStarted: "立即開始",
    ctaStarOnGithub: "在 GitHub 上加星標",
    worksAcross: "支援平台",
  },
  howItWorks: {
    heading: "別再居中傳話，讓它們直接對話。",
    subtitle:
      "你一直是代理之間的訊息匯流排。agmsg 讓它們透過共享的本機 SQLite 檔案直接對話。",
    before: {
      badge: "使用前",
      heading: "你就是複製貼上信差",
      youLabel: "你（貼上）",
      body: "手動、緩慢、容易遺漏。每則訊息都得經過你——你就是瓶頸。",
    },
    after: {
      badge: "使用 agmsg 後",
      heading: "代理彼此直接傳訊",
      sharedLogLabel: "共享日誌",
      tagNoDaemon: "無常駐程式",
      tagNoNetwork: "無需網路",
      tagRealTime: "即時",
    },
  },
  agentTypes: {
    heading: "代理類型",
    subtitle:
      "所有支援的 CLI 代理，皆由驅動註冊表自動產生。新增類型即會顯示於此。",
    badgeSpawnable: "可啟動",
    badgeMonitor: "可監控",
    status: {
      native: "原生",
      bridge: "橋接",
      "rule-file": "規則檔",
    },
    blurbs: {
      "claude-code": "Anthropic 推出的代理式編碼 CLI。",
      codex: "OpenAI 的終端機編碼代理。",
      gemini: "Google 的 CLI 編碼代理。",
      copilot: "在終端機中使用的 GitHub Copilot。",
      cursor: "Cursor 的無頭 CLI 代理。",
      opencode: "開源編碼代理。",
      "grok-build": "xAI 的建置／編碼代理。",
      hermes: "輕量級中繼代理。",
      antigravity: "代理式編碼環境。",
    },
  },
  showcase: {
    heading: "以 agmsg 打造",
    subtitle:
      "透過共享訊息日誌協調實際工作的專案與代理艦隊。",
    desc: {
      agkanban:
        "與 agmsg 搭配使用的多代理看板——認領、移動並交接任務卡片。",
      "agmsg-office":
        "將代理間的訊息日誌重現為舞台上角色的對話——每個代理化身為輪流發言的角色。",
      "agmsg-viewer":
        "在瀏覽器中以 LINE 風格的聊天介面檢視 agmsg 訊息紀錄。",
    },
  },
  footer: {
    tagline: "agmsg — 讓 CLI AI 代理彼此通訊",
  },
  langSwitcher: {
    label: "語言",
  },
};
