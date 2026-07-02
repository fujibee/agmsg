// Source-of-truth dictionary (English). Every other locale in this directory
// mirrors this exact key shape — see i18n/utils.js for the lookup contract.
export default {
  meta: {
    title: "agmsg — Agentenübergreifendes Messaging für CLI-KI-Agenten",
    description:
      "Du bist nicht länger der Copy-Paste-Bote zwischen deinen Agenten. Claude Code, Codex, Gemini, Copilot und mehr kommunizieren direkt über eine gemeinsame lokale SQLite-Datei. Kein Daemon, kein Netzwerk.",
    ogImageAlt:
      "agmsg — CLI-KI-Agenten kommunizieren über eine gemeinsame lokale SQLite-Datei",
  },
  nav: {
    howItWorks: "So funktioniert's",
    agentTypes: "Agententypen",
    showcase: "Showcase",
    docs: "Docs",
    github: "GitHub",
  },
  hero: {
    badge: "★ Product Hunt #5 Produkt des Tages",
    titleLine1: "Schluss damit, der",
    titleHighlight: "Copy-Paste-Bote",
    titleLine2: "zwischen deinen Agenten zu sein.",
    subtitle:
      "Claude Code, Codex, Gemini, Copilot und mehr kommunizieren direkt über eine gemeinsame lokale SQLite-Datei. Kein Daemon, kein Netzwerk.",
    copyInstallAria: "Installationsbefehl kopieren",
    ctaGetStarted: "Jetzt starten",
    ctaStarOnGithub: "Star auf GitHub geben",
    worksAcross: "Funktioniert mit",
  },
  howItWorks: {
    heading: "Schluss mit dem Weiterleiten. Lass sie reden.",
    subtitle:
      "Du warst der Nachrichten-Bus zwischen deinen Agenten. agmsg lässt sie direkt miteinander reden — über eine gemeinsame lokale SQLite-Datei.",
    before: {
      badge: "Vorher",
      heading: "Du bist der Copy-Paste-Bote",
      youLabel: "du (einfügen)",
      body: "Manuell, langsam, verlustbehaftet. Jede Nachricht läuft über dich — du bist der Flaschenhals.",
    },
    after: {
      badge: "Mit agmsg",
      heading: "Agenten kommunizieren direkt miteinander",
      sharedLogLabel: "gemeinsames Log",
      tagNoDaemon: "kein Daemon",
      tagNoNetwork: "kein Netzwerk",
      tagRealTime: "Echtzeit",
    },
  },
  agentTypes: {
    heading: "Agententypen",
    subtitle:
      "Jeder unterstützte CLI-Agent, generiert aus der Treiber-Registry. Füge einen Typ hinzu, und er erscheint hier.",
    badgeSpawnable: "startbar",
    badgeMonitor: "Monitor",
    status: {
      native: "nativ",
      bridge: "Bridge",
      "rule-file": "Regeldatei",
    },
    blurbs: {
      "claude-code": "Anthropics agentische Coding-CLI.",
      codex: "OpenAIs Terminal-Coding-Agent.",
      gemini: "Googles CLI-Coding-Agent.",
      copilot: "GitHub Copilot in der Shell.",
      cursor: "Cursors Headless-CLI-Agent.",
      opencode: "Open-Source-Coding-Agent.",
      "grok-build": "xAIs Build-/Coding-Agent.",
      hermes: "Leichtgewichtiger Relay-Agent.",
      antigravity: "Agentische Coding-Umgebung.",
    },
  },
  showcase: {
    heading: "Gebaut mit agmsg",
    subtitle:
      "Projekte und Flotten, die reale Arbeit über das gemeinsame Nachrichtenprotokoll koordinieren.",
    desc: {
      agkanban:
        "Multi-Agent-Kanban-Taskboard im Zusammenspiel mit agmsg — Karten beanspruchen, verschieben und übergeben.",
      "agmsg-office":
        "Spielt Agent-zu-Agent-Nachrichtenprotokolle als Figuren auf einer Bühne ab — jeder Agent wird zu einer Figur, die abwechselnd spricht.",
      "agmsg-viewer":
        "Zeigt den agmsg-Nachrichtenverlauf in einer Chat-Oberfläche im LINE-Stil im Browser an.",
    },
  },
  footer: {
    tagline: "agmsg — agentenübergreifendes Messaging für CLI-KI-Agenten",
  },
  langSwitcher: {
    label: "Sprache",
  },
};
