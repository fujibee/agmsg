import i18n from "i18next";
import { initReactI18next } from "react-i18next";
import LanguageDetector from "i18next-browser-languagedetector";
import { invoke } from "@tauri-apps/api/core";

import en from "./locales/en.json";
import ja from "./locales/ja.json";
import zhCN from "./locales/zh-CN.json";
import zhTW from "./locales/zh-TW.json";
import ko from "./locales/ko.json";
import es from "./locales/es.json";
import fr from "./locales/fr.json";
import de from "./locales/de.json";
import ptBR from "./locales/pt-BR.json";

// Codes match BCP 47 subtags used by the OS locale the app runs under (macOS
// "Preferred languages", Windows display language) so LanguageDetector's
// navigator lookup matches without extra mapping.
export const SUPPORTED_LANGUAGES = {
  en: "English",
  ja: "日本語",
  "zh-CN": "简体中文",
  "zh-TW": "繁體中文",
  ko: "한국어",
  es: "Español",
  fr: "Français",
  de: "Deutsch",
  "pt-BR": "Português (Brasil)",
} as const;

export type LanguageCode = keyof typeof SUPPORTED_LANGUAGES;

// The native menu (About/Edit/View/Window, update-check dialogs) lives in
// Rust, outside react-i18next's reach — push the resolved language there so
// it doesn't silently stay on the OS locale while the rest of the UI
// follows this switcher. Best-effort: fails harmlessly outside Tauri (e.g.
// `vite build` / non-Tauri contexts) or before the Rust side is up yet.
function syncMenuLanguage(lang: string) {
  void invoke("set_menu_language", { lang }).catch(() => {});
}

void i18n
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    resources: {
      en: { translation: en },
      ja: { translation: ja },
      "zh-CN": { translation: zhCN },
      "zh-TW": { translation: zhTW },
      ko: { translation: ko },
      es: { translation: es },
      fr: { translation: fr },
      de: { translation: de },
      "pt-BR": { translation: ptBR },
    },
    fallbackLng: "en",
    supportedLngs: Object.keys(SUPPORTED_LANGUAGES),
    // Persist the user's explicit choice; otherwise fall back to the OS/
    // browser locale on first launch.
    detection: {
      order: ["localStorage", "navigator"],
      caches: ["localStorage"],
      lookupLocalStorage: "agmsg-app-language",
    },
    interpolation: { escapeValue: false }, // React already escapes
  })
  .then(() => syncMenuLanguage(i18n.resolvedLanguage ?? "en"));

i18n.on("languageChanged", (lang) => syncMenuLanguage(lang));

export default i18n;
