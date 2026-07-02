import en from "./en.js";
import ja from "./ja.js";
import zhCN from "./zh-CN.js";
import zhTW from "./zh-TW.js";
import ko from "./ko.js";
import es from "./es.js";
import fr from "./fr.js";
import de from "./de.js";
import ptBR from "./pt-BR.js";

export const defaultLang = "en";

// Display name shown in the footer language switcher — always in that
// language's own script, so a reader recognizes their language regardless of
// the page's current locale.
export const languages = {
  en: "English",
  ja: "日本語",
  "zh-CN": "简体中文",
  "zh-TW": "繁體中文",
  ko: "한국어",
  es: "Español",
  fr: "Français",
  de: "Deutsch",
  "pt-BR": "Português (Brasil)",
};

const dictionaries = {
  en,
  ja,
  "zh-CN": zhCN,
  "zh-TW": zhTW,
  ko,
  es,
  fr,
  de,
  "pt-BR": ptBR,
};

export function useTranslations(lang) {
  return dictionaries[lang] ?? dictionaries[defaultLang];
}

// Default locale is unprefixed ("/"); every other locale lives under "/<lang>/".
export function localizedPath(lang, path = "/") {
  return lang === defaultLang ? path : `/${lang}${path}`;
}
