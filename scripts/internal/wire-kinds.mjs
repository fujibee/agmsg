#!/usr/bin/env node
import process from "node:process";
import { fileURLToPath } from "node:url";
import { realpathSync } from "node:fs";

// Single source of truth for the roster-mutation "kind" values this client
// version accepts on the wire. Every acceptance check across the sync,
// roster, and storage layers imports from here, so a new kind is added in
// exactly one place instead of the several call sites that used to carry
// their own copy of the same literal list.
export const ROSTER_KINDS = Object.freeze([
  "member_joined", "member_left", "member_renamed", "key_rotated",
]);

// key_rotated is always routed through the roster driver and key activation
// before it would reach one of the filters that separate a storage-applied
// roster mutation from a plain message, so those filters use this subset.
export const STORAGE_ROSTER_KINDS = Object.freeze(
  ROSTER_KINDS.filter((kind) => kind !== "key_rotated"),
);

// CLI form for the bash storage driver, which cannot `import` this module
// directly: `node wire-kinds.mjs roster-kinds` prints the accepted kinds,
// space-separated, so a shell case/list check can share this one definition
// instead of carrying its own literal. Guarded by the same "am I the module
// that was actually run" check remote-sync.mjs uses at its own entry point:
// this file is also imported as a library by four other scripts, and an
// unguarded top-level side effect would fire on the coincidence of ANY of
// their own argv[2] ever reading "roster-kinds", not only a real CLI call.
if (process.argv[1] &&
    realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]) &&
    process.argv[2] === "roster-kinds") {
  process.stdout.write(ROSTER_KINDS.join(" "));
}
