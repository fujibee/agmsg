// Source-of-truth dictionary (English). Every other locale in this directory
// mirrors this exact key shape — see i18n/utils.js for the lookup contract.
export default {
  meta: {
    title: "agmsg — Mensagens entre agentes de IA via CLI",
    description:
      "Você para de ser o mensageiro de copiar e colar entre seus agentes. Claude Code, Codex, Gemini, Copilot e outros trocam mensagens entre si por meio de um arquivo SQLite local compartilhado. Sem daemon, sem rede.",
    ogImageAlt:
      "agmsg — agentes de IA de CLI trocando mensagens entre si por meio de um arquivo SQLite local compartilhado",
  },
  nav: {
    howItWorks: "Como funciona",
    agentTypes: "Tipos de agente",
    showcase: "Vitrine",
    docs: "Documentação",
    github: "GitHub",
  },
  hero: {
    badge: "★ Product Hunt #5 Produto do Dia",
    titleLine1: "Você para de ser o",
    titleHighlight: "mensageiro de copiar e colar",
    titleLine2: "entre seus agentes.",
    subtitle:
      "Claude Code, Codex, Gemini, Copilot e outros trocam mensagens entre si por meio de um arquivo SQLite local compartilhado. Sem daemon, sem rede.",
    copyInstallAria: "Copiar comando de instalação",
    ctaGetStarted: "Comece agora",
    ctaStarOnGithub: "Dar estrela no GitHub",
    worksAcross: "Funciona com",
  },
  howItWorks: {
    heading: "Pare de retransmitir. Deixe-os conversar.",
    subtitle:
      "Você tem sido o barramento de mensagens entre seus agentes. O agmsg faz com que eles conversem diretamente — por meio de um arquivo SQLite local compartilhado.",
    before: {
      badge: "Antes",
      heading: "Você é o mensageiro de copiar e colar",
      youLabel: "você (cola)",
      body: "Manual, lento, com perdas. Toda mensagem passa por você — você é o gargalo.",
    },
    after: {
      badge: "Com o agmsg",
      heading: "Os agentes trocam mensagens diretamente",
      sharedLogLabel: "log compartilhado",
      tagNoDaemon: "sem daemon",
      tagNoNetwork: "sem rede",
      tagRealTime: "tempo real",
    },
  },
  agentTypes: {
    heading: "Tipos de agente",
    subtitle:
      "Todos os agentes de CLI compatíveis, gerados a partir do registro de drivers. Adicione um tipo e ele aparece aqui.",
    badgeSpawnable: "iniciável",
    badgeMonitor: "monitor",
    status: {
      native: "nativo",
      bridge: "bridge",
      "rule-file": "arquivo de regras",
    },
    blurbs: {
      "claude-code": "CLI de codificação agêntica da Anthropic.",
      codex: "Agente de codificação para terminal da OpenAI.",
      gemini: "Agente de codificação de CLI do Google.",
      copilot: "GitHub Copilot no terminal.",
      cursor: "Agente de CLI headless do Cursor.",
      opencode: "Agente de codificação open-source.",
      "grok-build": "Agente de build/codificação da xAI.",
      hermes: "Agente de relay leve.",
      antigravity: "Ambiente de codificação agêntico.",
    },
  },
  showcase: {
    heading: "Construído com agmsg",
    subtitle:
      "Projetos e frotas coordenando trabalho real por meio do log de mensagens compartilhado.",
    desc: {
      agkanban:
        "Quadro kanban multiagente que se integra ao agmsg — reivindique, mova e repasse cartões.",
      "agmsg-office":
        "Reproduz logs de mensagens entre agentes como personagens conversando em um palco — cada agente vira um personagem que fala na sua vez.",
      "agmsg-viewer":
        "Veja o histórico de mensagens do agmsg em uma interface de chat estilo LINE no navegador.",
    },
  },
  footer: {
    tagline: "agmsg — mensagens entre agentes de IA de CLI",
  },
  langSwitcher: {
    label: "Idioma",
  },
};
