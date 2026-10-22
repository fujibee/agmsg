export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  const units = ["KB", "MB", "GB"];
  let v = n / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v >= 100 ? v.toFixed(0) : v.toFixed(1)} ${units[i]}`;
}

export function toBytes(
  x: string | ArrayBuffer | Uint8Array | { text: string } | { bytes: ArrayBuffer | Uint8Array },
): Uint8Array {
  if (typeof x === "string") return new TextEncoder().encode(x);
  if (x instanceof Uint8Array) return x;
  if (x instanceof ArrayBuffer) return new Uint8Array(x);
  if ("text" in x) return new TextEncoder().encode(x.text);
  return toBytes(x.bytes);
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
