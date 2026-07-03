// French translation dictionary. Mirrors the exact key shape of en.js —
// see i18n/utils.js for the lookup contract.
export default {
  meta: {
    title: "agmsg — Messagerie inter-agents pour les agents IA en CLI",
    description:
      "Tu arrêtes de faire le coursier copier-coller entre tes agents. Claude Code, Codex, Gemini, Copilot et bien d'autres échangent des messages via un fichier SQLite local partagé. Pas de daemon, pas de réseau.",
    ogImageAlt:
      "agmsg — des agents IA en CLI qui échangent des messages via un fichier SQLite local partagé",
  },
  nav: {
    howItWorks: "Comment ça marche",
    agentTypes: "Types d'agents",
    desktopApp: "Application de bureau",
    showcase: "Vitrine",
    docs: "Docs",
    github: "GitHub",
  },
  hero: {
    badge: "★ Product Hunt #5 Produit du jour",
    titleLine1: "Tu arrêtes de faire le",
    titleHighlight: "coursier copier-coller",
    titleLine2: "entre tes agents.",
    subtitle:
      "Claude Code, Codex, Gemini, Copilot et bien d'autres échangent des messages via un fichier SQLite local partagé. Pas de daemon, pas de réseau.",
    installTabCli: "CLI",
    installTabMac: "macOS",
    installTabWin: "Windows",
    copyInstallAria: "Copier la commande d'installation",
    winDownloadLabel: "Télécharger l'installateur depuis Releases",
    winDownloadLink: ".msi / .exe →",
    ctaGetStarted: "Commencer",
    ctaStarOnGithub: "Star sur GitHub",
    worksAcross: "Compatible avec",
  },
  howItWorks: {
    heading: "Arrête de relayer. Laisse-les parler.",
    subtitle:
      "Tu as été le bus de messages entre tes agents. agmsg les fait se parler directement — via un fichier SQLite local partagé.",
    before: {
      badge: "Avant",
      heading: "Tu es le coursier copier-coller",
      youLabel: "toi (colle)",
      body: "Manuel, lent, avec pertes. Chaque message passe par toi — tu es le goulot d'étranglement.",
    },
    after: {
      badge: "Avec agmsg",
      heading: "Les agents se parlent directement",
      sharedLogLabel: "journal partagé",
      tagNoDaemon: "pas de daemon",
      tagNoNetwork: "pas de réseau",
      tagRealTime: "temps réel",
    },
  },
  agentTypes: {
    heading: "Types d'agents",
    subtitle:
      "Tous les agents CLI pris en charge, générés depuis le registre des drivers. Ajoute un type, il apparaît ici.",
    badgeSpawnable: "lançable",
    badgeMonitor: "moniteur",
    status: {
      native: "natif",
      bridge: "bridge",
      "rule-file": "fichier de règles",
    },
    blurbs: {
      "claude-code": "Le CLI de codage agentique d'Anthropic.",
      codex: "L'agent de codage en terminal d'OpenAI.",
      gemini: "L'agent de codage CLI de Google.",
      copilot: "GitHub Copilot dans le shell.",
      cursor: "L'agent CLI headless de Cursor.",
      opencode: "Agent de codage open source.",
      "grok-build": "L'agent de build/codage de xAI.",
      hermes: "Agent relais léger.",
      antigravity: "Environnement de codage agentique.",
    },
  },
  showcase: {
    heading: "Construit avec agmsg",
    subtitle:
      "Des projets et des flottes d'agents qui coordonnent du vrai travail via le journal de messages partagé.",
    desc: {
      agkanban:
        "Tableau kanban multi-agents conçu pour agmsg — réclame, déplace et transmets des cartes.",
      "agmsg-office":
        "Rejoue les journaux de messages entre agents comme des personnages qui parlent sur une scène — chaque agent devient un personnage qui prend la parole à son tour.",
      "agmsg-viewer":
        "Consulte l'historique des messages agmsg dans une interface de chat façon LINE, dans le navigateur.",
    },
  },
  desktop: {
    heading: "Une application de bureau pour tes agents",
    body: "Une interface graphique avec terminal intégré qui lance les agents dans de vrais PTY et livre les messages agmsg à n'importe quel agent CLI interactif — pas de bridge, de hook ni d'outil de monitoring par agent. Signée et notarisée sur macOS, mise à jour automatique. Installe-la avec les onglets macOS/Windows ci-dessus.",
    videoPlaceholder: "Vidéo de démonstration bientôt disponible",
  },
  footer: {
    tagline: "agmsg — messagerie inter-agents pour les agents IA en CLI",
  },
  langSwitcher: {
    label: "Langue",
  },
};
