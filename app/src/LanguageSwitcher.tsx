import { useTranslation } from "react-i18next";
import { SUPPORTED_LANGUAGES, type LanguageCode } from "./i18n";

/** A plain <select> language picker — lives in the sidebar head next to the
 *  team picker. Changing it updates i18next's active language immediately
 *  and persists the choice (see detection.caches in i18n/index.ts). */
export function LanguageSwitcher() {
  const { i18n, t } = useTranslation();
  return (
    <select
      className="language-switcher"
      value={i18n.resolvedLanguage}
      onChange={(e) => void i18n.changeLanguage(e.target.value)}
      title={t("language.label")}
    >
      {Object.entries(SUPPORTED_LANGUAGES).map(([code, label]) => (
        <option key={code} value={code}>
          {label}
        </option>
      ))}
    </select>
  );
}

// Re-exported for callers that only need the type, avoiding a second import
// of ./i18n in files that don't otherwise touch it.
export type { LanguageCode };
