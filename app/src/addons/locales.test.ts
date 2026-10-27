import { describe, expect, it } from "vitest";
import i18next from "i18next";
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
const PLURAL = /_(zero|one|two|few|many|other)$/;
const base = (k: string) => k.replace(PLURAL, "");
const placeholders = (s: string) => (s.match(/\{\{\w+\}\}/g) ?? []).sort().join();
const get = (o: unknown, path: string) => path.split(".").reduce<unknown>((a, k) => (a as Record<string, unknown>)[k], o) as string;

describe("addons strings", () => {
  const keys = flat(en.addons, "addons");
  const locales = { ja, de, es, fr, ko, "pt-BR": ptBR, "zh-CN": zhCN, "zh-TW": zhTW };
  for (const [name, loc] of Object.entries(locales)) {
    it(`${name} has every addons key with the same placeholders`, () => {
      const mine = flat(loc.addons, "addons");
      // Plural forms differ per language (ja has only _other, es/fr/pt-BR add _many): compare the base keys,
      // and require every language to have an _other form, which is what i18next falls back to.
      expect([...new Set(mine.map(base))].sort()).toEqual([...new Set(keys.map(base))].sort());
      for (const k of mine.filter((x) => PLURAL.test(x))) expect(mine, `${name} ${k}`).toContain(`${base(k)}_other`);
      for (const k of mine) expect(placeholders(get(loc, k)), `${name} ${k}`).toBe(placeholders(get(en, PLURAL.test(k) ? `${base(k)}_other` : k)));
    });
  }
});

describe("pane count plurals", () => {
  const resources = { en, ja, de, es, fr, ko, "pt-BR": ptBR, "zh-CN": zhCN, "zh-TW": zhTW };
  const say = async (lng: string, count: number) => {
    const i = i18next.createInstance();
    await i.init({ lng, resources: Object.fromEntries(Object.entries(resources).map(([k, v]) => [k, { translation: v }])), interpolation: { escapeValue: false } });
    return i.t("addons.confirm.source", { repo: "o/r", sha: "abc1234", count });
  };
  it("English says pane for one and panes for the rest, never (s)", async () => {
    expect(await say("en", 1)).toBe("from o/r · abc1234 · adds 1 pane");
    expect(await say("en", 2)).toBe("from o/r · abc1234 · adds 2 panes");
  });
  it("every language resolves a real sentence for 1, 2 and 1000000", async () => {
    for (const lng of Object.keys(resources)) {
      for (const n of [1, 2, 1000000]) {
        const text = await say(lng, n);
        expect(text, `${lng} ${n}`).toContain(String(n));
        expect(text, `${lng} ${n}`).not.toContain("addons.confirm");
        expect(text, `${lng} ${n}`).not.toContain("(s)");
      }
    }
  });
});
