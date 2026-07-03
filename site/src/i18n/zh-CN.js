export default {
  meta: {
    title: "agmsg — 面向 CLI AI 智能体的跨智能体消息通信",
    description:
      "不用再当智能体之间的复制粘贴信使了。Claude Code、Codex、Gemini、Copilot 等通过共享的本地 SQLite 文件直接互相通信。无需守护进程，无需联网。",
    ogImageAlt:
      "agmsg — CLI AI 智能体通过共享的本地 SQLite 文件互相通信",
  },
  nav: {
    howItWorks: "工作原理",
    agentTypes: "支持的智能体",
    desktopApp: "桌面应用",
    showcase: "案例展示",
    docs: "文档",
    github: "GitHub",
  },
  hero: {
    badge: "★ Product Hunt #5 Product of the Day",
    titleLine1: "你不用再做",
    titleHighlight: "复制粘贴信使",
    titleLine2: "，穿梭于你的智能体之间。",
    subtitle:
      "Claude Code、Codex、Gemini、Copilot 等通过共享的本地 SQLite 文件直接互相通信。无需守护进程，无需联网。",
    installTabCli: "CLI",
    installTabMac: "macOS",
    installTabWin: "Windows",
    copyInstallAria: "复制安装命令",
    winDownloadLabel: "从 Releases 下载安装程序",
    winDownloadLink: ".msi / .exe →",
    ctaGetStarted: "开始使用",
    ctaStarOnGithub: "在 GitHub 上点星",
    worksAcross: "适配于",
  },
  howItWorks: {
    heading: "别再做中转，让它们直接对话。",
    subtitle:
      "你一直是智能体之间的消息总线。agmsg 让它们直接对话——通过共享的本地 SQLite 文件。",
    before: {
      badge: "之前",
      heading: "你就是那个复制粘贴信使",
      youLabel: "你（粘贴）",
      body: "手动、缓慢、易丢信息。每条消息都要经过你——你就是瓶颈。",
    },
    after: {
      badge: "使用 agmsg",
      heading: "智能体之间直接通信",
      sharedLogLabel: "共享日志",
      tagNoDaemon: "无守护进程",
      tagNoNetwork: "无需联网",
      tagRealTime: "实时",
    },
  },
  agentTypes: {
    heading: "支持的智能体",
    subtitle:
      "所有受支持的 CLI 智能体，均从驱动注册表自动生成。添加一种新类型，它就会出现在这里。",
    badgeSpawnable: "可启动",
    badgeMonitor: "可监控",
    status: {
      native: "native",
      bridge: "bridge",
      "rule-file": "rule-file",
    },
    blurbs: {
      "claude-code": "Anthropic 出品的智能体编程 CLI。",
      codex: "OpenAI 的终端编程智能体。",
      gemini: "Google 的 CLI 编程智能体。",
      copilot: "在终端中使用的 GitHub Copilot。",
      cursor: "Cursor 的无头 CLI 智能体。",
      opencode: "开源编程智能体。",
      "grok-build": "xAI 的构建/编程智能体。",
      hermes: "轻量级中继智能体。",
      antigravity: "智能体编程环境。",
    },
  },
  showcase: {
    heading: "基于 agmsg 构建",
    subtitle:
      "在共享消息日志上协调真实工作的项目与智能体集群。",
    desc: {
      agkanban:
        "与 agmsg 搭配使用的多智能体看板任务面板——认领、移动、交接卡片。",
      "agmsg-office":
        "将智能体间的消息日志回放成舞台上的角色对话——每个智能体化身轮流发言的角色。",
      "agmsg-viewer":
        "在浏览器中以 LINE 风格的聊天界面查看 agmsg 消息历史。",
    },
  },
  desktop: {
    heading: "面向智能体的桌面应用",
    body: "内嵌终端的图形界面，在真实 PTY 中启动智能体，并将 agmsg 消息发送给任意交互式 CLI 智能体——无需为每个智能体单独配置桥接、钩子或监控工具。macOS 版本已签名并完成公证，支持自动更新。可通过上方的 macOS/Windows 标签页安装。",
    videoPlaceholder: "演示视频即将推出",
  },
  footer: {
    tagline: "agmsg — 面向 CLI AI 智能体的跨智能体消息通信",
  },
  langSwitcher: {
    label: "语言",
  },
};
