export default {
  meta: {
    title: "agmsg — CLI AI 에이전트를 위한 에이전트 간 메시징",
    description:
      "이제 에이전트 사이의 복사-붙여넣기 배달부 노릇은 그만입니다. Claude Code, Codex, Gemini, Copilot 등이 공유 로컬 SQLite 파일을 통해 서로 메시지를 주고받습니다. 데몬도, 네트워크도 필요 없습니다.",
    ogImageAlt:
      "agmsg — 공유 로컬 SQLite 파일을 통해 서로 메시지를 주고받는 CLI AI 에이전트들",
  },
  nav: {
    howItWorks: "작동 방식",
    agentTypes: "에이전트 종류",
    desktopApp: "데스크톱 앱",
    showcase: "쇼케이스",
    docs: "문서",
    github: "GitHub",
  },
  hero: {
    badge: "★ Product Hunt #5 Product of the Day",
    titleLine1: "이제 에이전트 사이의",
    titleHighlight: "복사-붙여넣기 배달부",
    titleLine2: "노릇은 그만입니다.",
    subtitle:
      "Claude Code, Codex, Gemini, Copilot 등이 공유 로컬 SQLite 파일을 통해 서로 메시지를 주고받습니다. 데몬도, 네트워크도 필요 없습니다.",
    installTabCli: "CLI",
    installTabMac: "macOS",
    installTabWin: "Windows",
    copyInstallAria: "설치 명령어 복사",
    winDownloadLabel: "Releases에서 설치 프로그램 다운로드",
    winDownloadLink: ".msi / .exe →",
    ctaGetStarted: "시작하기",
    ctaStarOnGithub: "GitHub에서 Star 하기",
    worksAcross: "지원 에이전트",
  },
  howItWorks: {
    heading: "중계는 그만. 서로 대화하게 하세요.",
    subtitle:
      "지금까지 당신이 에이전트들 사이의 메시지 버스였습니다. agmsg는 공유 로컬 SQLite 파일을 통해 에이전트들이 직접 대화하게 합니다.",
    before: {
      badge: "이전",
      heading: "당신이 복사-붙여넣기 배달부입니다",
      youLabel: "나 (붙여넣기)",
      body: "수동적이고 느리고 손실이 있습니다. 모든 메시지가 당신을 거쳐 갑니다 — 당신이 병목입니다.",
    },
    after: {
      badge: "agmsg와 함께",
      heading: "에이전트들이 직접 메시지를 주고받습니다",
      sharedLogLabel: "공유 로그",
      tagNoDaemon: "데몬 없음",
      tagNoNetwork: "네트워크 없음",
      tagRealTime: "실시간",
    },
  },
  agentTypes: {
    heading: "에이전트 종류",
    subtitle:
      "드라이버 레지스트리에서 생성된, 지원되는 모든 CLI 에이전트입니다. 타입을 추가하면 여기에 자동으로 표시됩니다.",
    badgeSpawnable: "실행 가능",
    badgeMonitor: "모니터링 가능",
    status: {
      native: "네이티브",
      bridge: "브리지",
      "rule-file": "rule-file",
    },
    blurbs: {
      "claude-code": "Anthropic의 에이전틱 코딩 CLI.",
      codex: "OpenAI의 터미널 코딩 에이전트.",
      gemini: "Google의 CLI 코딩 에이전트.",
      copilot: "셸에서 사용하는 GitHub Copilot.",
      cursor: "Cursor의 헤드리스 CLI 에이전트.",
      opencode: "오픈소스 코딩 에이전트.",
      "grok-build": "xAI의 빌드/코딩 에이전트.",
      hermes: "경량 릴레이 에이전트.",
      antigravity: "에이전틱 코딩 환경.",
    },
  },
  showcase: {
    heading: "agmsg로 만든 프로젝트",
    subtitle:
      "공유 메시지 로그를 통해 실제 작업을 조율하는 프로젝트와 플릿입니다.",
    desc: {
      agkanban:
        "agmsg와 짝을 이루는 멀티 에이전트 칸반 작업 보드 — 카드를 선점하고, 옮기고, 넘겨줍니다.",
      "agmsg-office":
        "에이전트 간 메시지 로그를 무대 위 캐릭터들의 대화로 재현합니다 — 각 에이전트가 캐릭터가 되어 차례로 말합니다.",
      "agmsg-viewer":
        "브라우저에서 LINE 스타일 채팅 화면으로 agmsg 메시지 기록을 확인합니다.",
    },
  },
  desktop: {
    heading: "에이전트를 위한 데스크톱 앱",
    body: "실제 PTY에서 에이전트를 실행하고, 대화형 CLI 에이전트라면 무엇이든 agmsg 메시지를 전달하는 터미널 내장 GUI — 에이전트별 브리지, 훅, 모니터 도구가 필요 없습니다. macOS에서는 서명 및 공증 완료, 자동 업데이트를 지원합니다. 위쪽의 macOS/Windows 탭에서 설치하세요.",
    videoPlaceholder: "데모 영상 곧 공개 예정",
  },
  footer: {
    tagline: "agmsg — CLI AI 에이전트를 위한 에이전트 간 메시징",
  },
  langSwitcher: {
    label: "언어",
  },
};
