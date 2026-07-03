// Source-of-truth dictionary (English). Every other locale in this directory
// mirrors this exact key shape — see i18n/utils.js for the lookup contract.
export default {
  meta: {
    title: "agmsg — Mensajería entre agentes para agentes de IA en CLI",
    description:
      "Deja de ser el mensajero de copiar y pegar entre tus agentes. Claude Code, Codex, Gemini, Copilot y más se envían mensajes entre sí a través de un archivo SQLite local compartido. Sin daemon, sin red.",
    ogImageAlt:
      "agmsg — agentes de IA en CLI enviándose mensajes entre sí a través de un archivo SQLite local compartido",
  },
  nav: {
    howItWorks: "Cómo funciona",
    agentTypes: "Tipos de agentes",
    desktopApp: "Aplicación de escritorio",
    showcase: "Vitrina",
    docs: "Documentación",
    github: "GitHub",
  },
  hero: {
    badge: "★ Product Hunt #5 Producto del día",
    titleLine1: "Deja de ser el",
    titleHighlight: "mensajero de copiar y pegar",
    titleLine2: "entre tus agentes.",
    subtitle:
      "Claude Code, Codex, Gemini, Copilot y más se envían mensajes entre sí a través de un archivo SQLite local compartido. Sin daemon, sin red.",
    installTabCli: "CLI",
    installTabMac: "macOS",
    installTabWin: "Windows",
    copyInstallAria: "Copiar comando de instalación",
    winDownloadLabel: "Descarga el instalador desde Releases",
    winDownloadLink: ".msi / .exe →",
    ctaGetStarted: "Empezar",
    ctaStarOnGithub: "Danos una estrella en GitHub",
    worksAcross: "Funciona con",
  },
  howItWorks: {
    heading: "Deja de retransmitir. Deja que hablen.",
    subtitle:
      "Has sido el bus de mensajes entre tus agentes. agmsg hace que se comuniquen directamente, a través de un archivo SQLite local compartido.",
    before: {
      badge: "Antes",
      heading: "Eres el mensajero de copiar y pegar",
      youLabel: "tú (pegar)",
      body: "Manual, lento, con pérdidas. Cada mensaje pasa por ti: eres el cuello de botella.",
    },
    after: {
      badge: "Con agmsg",
      heading: "Los agentes se envían mensajes directamente",
      sharedLogLabel: "registro compartido",
      tagNoDaemon: "sin daemon",
      tagNoNetwork: "sin red",
      tagRealTime: "en tiempo real",
    },
  },
  agentTypes: {
    heading: "Tipos de agentes",
    subtitle:
      "Todos los agentes CLI compatibles, generados a partir del registro de drivers. Añade un tipo y aparecerá aquí.",
    badgeSpawnable: "invocable",
    badgeMonitor: "monitor",
    status: {
      native: "nativo",
      bridge: "puente",
      "rule-file": "archivo de reglas",
    },
    blurbs: {
      "claude-code": "El CLI de codificación agéntica de Anthropic.",
      codex: "El agente de codificación de terminal de OpenAI.",
      gemini: "El agente de codificación CLI de Google.",
      copilot: "GitHub Copilot en la terminal.",
      cursor: "El agente CLI de Cursor sin interfaz gráfica.",
      opencode: "Agente de codificación de código abierto.",
      "grok-build": "El agente de compilación/codificación de xAI.",
      hermes: "Agente de retransmisión ligero.",
      antigravity: "Entorno de codificación agéntico.",
    },
  },
  showcase: {
    heading: "Creado con agmsg",
    subtitle:
      "Proyectos y flotas que coordinan trabajo real a través del registro de mensajes compartido.",
    desc: {
      agkanban:
        "Tablero kanban multiagente que se combina con agmsg: reclama, mueve y transfiere tarjetas.",
      "agmsg-office":
        "Reproduce los registros de mensajes entre agentes como personajes que hablan en un escenario: cada agente se convierte en un personaje que toma turnos para hablar.",
      "agmsg-viewer":
        "Consulta el historial de mensajes de agmsg en una interfaz de chat estilo LINE en el navegador.",
    },
  },
  desktop: {
    heading: "Una aplicación de escritorio para tus agentes",
    body: "Una GUI con terminal integrada que lanza agentes en PTYs reales y entrega mensajes de agmsg a cualquier agente CLI interactivo — sin bridge, hook ni herramienta de monitor por agente. Firmada y notarizada en macOS, con actualizaciones automáticas. Instálala con las pestañas de macOS/Windows de arriba.",
    videoPlaceholder: "Vídeo de demostración próximamente",
  },
  footer: {
    tagline: "agmsg — mensajería entre agentes para agentes de IA en CLI",
  },
  langSwitcher: {
    label: "Idioma",
  },
};
