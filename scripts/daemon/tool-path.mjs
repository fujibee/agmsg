// The directories of the terminal CLIs agmsgd's channels drive (herdr,
// tmux, orca), as `agmsg daemon start` found them on the PATH of the shell
// that ran it. A resident manager starts agmsgd with its own minimal PATH
// (launchd: /usr/bin:/bin:/usr/sbin:/sbin; systemd --user: no ~/.local/bin),
// where none of those are found: terminal-nudge.sh then answers every seat
// placed in a herdr or tmux pane with "<cli> not on PATH" and the
// terminal-poke channel never delivers to it. Appending the recorded
// directories here, once at startup, gives every child agmsgd spawns the
// same view of those CLIs the user's own shell has.
//
// The record is one line of absolute directories joined by ":" (written by
// scripts/daemon.sh's _record_tool_path). Each entry is used only when it is
// an absolute path to an existing directory; a missing or unreadable file
// changes nothing. Appended, never prepended: the system's own directories
// keep precedence for everything they already provide.
import { readFileSync, statSync } from "node:fs";
import { join, isAbsolute, delimiter } from "node:path";

export const TOOL_PATH_FILE = "agmsgd-tool-path";

export function recordedToolDirs(installRoot) {
  let text;
  try {
    text = readFileSync(join(installRoot, "run", TOOL_PATH_FILE), "utf8");
  } catch {
    return [];
  }
  const dirs = [];
  for (const raw of (text.split(/\r?\n/)[0] ?? "").split(":")) {
    const dir = raw.trim();
    if (!dir || !isAbsolute(dir) || dirs.includes(dir)) continue;
    try {
      if (!statSync(dir).isDirectory()) continue;
    } catch {
      continue;
    }
    dirs.push(dir);
  }
  return dirs;
}

// Not on Windows: none of these CLIs run there, and a drive-letter path
// would not survive the ":"-joined record.
export function extendPathFromRecord(installRoot, env = process.env, platform = process.platform) {
  if (platform === "win32") return [];
  const current = (env.PATH ?? "").split(delimiter).filter(Boolean);
  const added = recordedToolDirs(installRoot).filter((dir) => !current.includes(dir));
  if (added.length) env.PATH = [...current, ...added].join(delimiter);
  return added;
}
