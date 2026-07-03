// Source-of-truth dictionary (English). Every other locale in this directory
// mirrors this exact key shape — see i18n/utils.js for the lookup contract.
export default {
  meta: {
    title: "agmsg — Cross-agent messaging for CLI AI agents",
    description:
      "You stop being the copy-paste courier between your agents. Claude Code, Codex, Gemini, Copilot and more message each other over a shared local SQLite file. No daemon, no network.",
    ogImageAlt:
      "agmsg — CLI AI agents messaging each other over a shared local SQLite file",
  },
  nav: {
    howItWorks: "How it works",
    agentTypes: "Agent types",
    desktopApp: "Desktop app",
    showcase: "Showcase",
    docs: "Docs",
    github: "GitHub",
  },
  hero: {
    badge: "★ Product Hunt #5 Product of the Day",
    titleLine1: "You stop being the",
    titleHighlight: "copy-paste courier",
    titleLine2: "between your agents.",
    subtitle:
      "Claude Code, Codex, Gemini, Copilot and more message each other over a shared local SQLite file. No daemon, no network.",
    installTabCli: "CLI",
    installTabMac: "macOS",
    installTabWin: "Windows",
    copyInstallAria: "Copy install command",
    winDownloadLabel: "Download the installer from Releases",
    winDownloadLink: ".msi / .exe →",
    ctaGetStarted: "Get started",
    ctaStarOnGithub: "Star on GitHub",
    worksAcross: "Works across",
  },
  howItWorks: {
    heading: "Stop relaying. Let them talk.",
    subtitle:
      "You've been the message bus between your agents. agmsg makes them talk directly — over a shared local SQLite file.",
    before: {
      badge: "Before",
      heading: "You're the copy-paste courier",
      youLabel: "you (paste)",
      body: "Manual, slow, lossy. Every message routes through you — you're the bottleneck.",
    },
    after: {
      badge: "With agmsg",
      heading: "Agents message each other directly",
      sharedLogLabel: "shared log",
      tagNoDaemon: "no daemon",
      tagNoNetwork: "no network",
      tagRealTime: "real-time",
    },
  },
  agentTypes: {
    heading: "Agent types",
    subtitle:
      "Every supported CLI agent, generated from the driver registry. Add a type, it shows up here.",
    badgeSpawnable: "spawnable",
    badgeMonitor: "monitor",
    status: {
      native: "native",
      bridge: "bridge",
      "rule-file": "rule-file",
    },
    blurbs: {
      "claude-code": "Anthropic's agentic coding CLI.",
      codex: "OpenAI's terminal coding agent.",
      gemini: "Google's CLI coding agent.",
      copilot: "GitHub Copilot in the shell.",
      cursor: "Cursor's headless CLI agent.",
      opencode: "Open-source coding agent.",
      "grok-build": "xAI's build/coding agent.",
      hermes: "Lightweight relay agent.",
      antigravity: "Agentic coding environment.",
    },
  },
  showcase: {
    heading: "Built with agmsg",
    subtitle:
      "Projects and fleets coordinating real work over the shared message log.",
    desc: {
      agkanban:
        "Multi-agent kanban task board that pairs with agmsg — claim, move, and hand off cards.",
      "agmsg-office":
        "Replays agent-to-agent message logs as characters talking on a stage — each agent becomes a character taking turns speaking.",
      "agmsg-viewer":
        "View agmsg message history in a LINE-style chat interface in the browser.",
    },
  },
  desktop: {
    heading: "A desktop app for your agents",
    body: "A terminal-embedded GUI that spawns agents in real PTYs and delivers agmsg messages to any interactive CLI agent — no per-agent bridge, hook, or monitor tool. Signed and notarized on macOS, auto-updating. Install with the macOS/Windows tabs up top.",
    videoPlaceholder: "Demo video coming soon",
  },
  footer: {
    tagline: "agmsg — cross-agent messaging for CLI AI agents",
  },
  langSwitcher: {
    label: "Language",
  },
};
