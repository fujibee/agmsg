export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  const units = ["KB", "MB", "GB"];
  let v = n / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v >= 100 ? v.toFixed(0) : v.toFixed(1)} ${units[i]}`;
}

export function toBytes(r: { text: string } | { bytes: ArrayBuffer }): Uint8Array {
  return "text" in r ? new TextEncoder().encode(r.text) : new Uint8Array(r.bytes);
}

export function joinPath(dir: string, name: string): string {
  return dir === "." || dir === "" ? name : `${dir}/${name}`;
}

export function baseName(p: string): string {
  const i = p.lastIndexOf("/");
  return i < 0 ? p : p.slice(i + 1);
}

export function dirName(p: string): string {
  const i = p.lastIndexOf("/");
  return i < 0 ? "." : p.slice(0, i);
}

/**
 * What to call the folder a pane was opened on. A path given at open time wins; when the
 * folder was chosen in the app's own dialog no path is passed, so the granted root's own
 * name (what fs.stat(".") returns) is used. `fallback` is for a root with no name.
 */
export function rootLabel(openPath: string | undefined, rootName: string | undefined, fallback: string): string {
  if (openPath) return openPath;
  return rootName || fallback;
}
