// Tests that check the stylesheet read it through a node built-in: vitest blanks .css modules (also with ?raw).
type Fs = { readFileSync(p: URL, e: string): string };
const fs = (globalThis as unknown as { process: { getBuiltinModule(n: string): Fs } }).process.getBuiltinModule("node:fs");

/** The text of a file next to the app's sources, e.g. readSource("App.css", import.meta.url) from a file in src/. */
export function readSource(rel: string, from: string): string {
  return fs.readFileSync(new URL(rel, from), "utf8");
}
