/** Resolve a relative link from the folder `dir`; null if it leaves the root. */
export function resolveRelative(dir: string, href: string): string | null {
  const clean = href.split("#")[0].split("?")[0];
  if (!clean || /^[a-z][a-z0-9+.-]*:/i.test(clean) || clean.startsWith("//") || clean.startsWith("/")) return null;
  const out: string[] = dir === "." || dir === "" ? [] : dir.split("/");
  for (const part of decodeURIComponentSafe(clean).split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (!out.length) return null;
      out.pop();
    } else out.push(part);
  }
  return out.length ? out.join("/") : ".";
}

function decodeURIComponentSafe(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    return s;
  }
}
