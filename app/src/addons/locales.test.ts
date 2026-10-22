import { describe, expect, it } from "vitest";
import en from "../i18n/locales/en.json";
import ja from "../i18n/locales/ja.json";
import de from "../i18n/locales/de.json";
import es from "../i18n/locales/es.json";
import fr from "../i18n/locales/fr.json";
import ko from "../i18n/locales/ko.json";
import ptBR from "../i18n/locales/pt-BR.json";
import zhCN from "../i18n/locales/zh-CN.json";
import zhTW from "../i18n/locales/zh-TW.json";

const flat = (o: unknown, p = ""): string[] =>
  typeof o === "object" && o ? Object.entries(o).flatMap(([k, v]) => flat(v, p ? `${p}.${k}` : k)) : [p];
const placeholders = (s: string) => (s.match(/\{\{\w+\}\}/g) ?? []).sort().join();
const get = (o: unknown, path: string) => path.split(".").reduce<unknown>((a, k) => (a as Record<string, unknown>)[k], o) as string;

describe("addons strings", () => {
  const keys = flat(en.addons, "addons");
  const locales = { ja, de, es, fr, ko, "pt-BR": ptBR, "zh-CN": zhCN, "zh-TW": zhTW };
  for (const [name, loc] of Object.entries(locales)) {
    it(`${name} has every addons key with the same placeholders`, () => {
      expect(flat(loc.addons, "addons").sort()).toEqual([...keys].sort());
      for (const k of keys) expect(placeholders(get(loc, k)), `${name} ${k}`).toBe(placeholders(get(en, k)));
    });
  }
});
