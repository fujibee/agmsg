import type { EnvNotice } from "./source";

// The line on a folder the person just allowed when it holds a `.env` file. A
// pane that declares network cannot read such a file (Rust decides that on every
// read); this only says so. Nothing is said when none was found: the look is
// bounded, so silence is not a promise.
export function envNoticeKey(n: EnvNotice): "addons.env.found" | "addons.env.foundNetwork" | null {
  if (!n.found) return null;
  return n.network ? "addons.env.foundNetwork" : "addons.env.found";
}
