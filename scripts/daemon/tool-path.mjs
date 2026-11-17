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
import { readFileSync, statSync, writeFileSync, renameSync } from "node:fs";
import { join, isAbsolute, delimiter } from "node:path";

export const TOOL_PATH_FILE = "agmsgd-tool-path";

// { dirs, line, error }: `line` is the record's first line as read (what
// .applied records), `error` a reason when the record exists but could not
// be read -- a missing record is not an error (nothing was recorded yet).
export function readToolPathRecord(installRoot) {
  let text;
  try {
    text = readFileSync(join(installRoot, "run", TOOL_PATH_FILE), "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") return { dirs: [], line: "", error: "" };
    return { dirs: [], line: "", error: `${error?.code ?? "error"}: ${error?.message ?? error}` };
  }
  const line = (text.split(/\r?\n/)[0] ?? "").trim();
  const dirs = [];
  for (const raw of line.split(":")) {
    const dir = raw.trim();
    if (!dir || !isAbsolute(dir) || dirs.includes(dir)) continue;
    try {
      if (!statSync(dir).isDirectory()) continue;
    } catch {
      continue;
    }
    dirs.push(dir);
  }
  return { dirs, line, error: "" };
}

export function recordedToolDirs(installRoot) {
  return readToolPathRecord(installRoot).dirs;
}

// Not on Windows: none of these CLIs run there, and a drive-letter path
// would not survive the ":"-joined record. Returns { added, error }; the
// record line actually read is written to run/agmsgd-tool-path.applied so
// `agmsg daemon start` can tell a running agmsgd that has not picked up a
// newer record (and say to restart it). A failure to read the record or to
// write .applied is returned as `error` for the caller to log; neither
// stops agmsgd.
export function extendPathFromRecord(installRoot, env = process.env, platform = process.platform) {
  if (platform === "win32") return { added: [], error: "" };
  const record = readToolPathRecord(installRoot);
  const current = (env.PATH ?? "").split(delimiter).filter(Boolean);
  const added = record.dirs.filter((dir) => !current.includes(dir));
  if (added.length) env.PATH = [...current, ...added].join(delimiter);
  let error = record.error ? `could not read run/${TOOL_PATH_FILE} (${record.error})` : "";
  if (!record.error) {
    const applied = join(installRoot, "run", `${TOOL_PATH_FILE}.applied`);
    try {
      writeFileSync(`${applied}.${process.pid}`, `${record.line}\n`);
      renameSync(`${applied}.${process.pid}`, applied);
    } catch (writeError) {
      error = `could not write run/${TOOL_PATH_FILE}.applied (${writeError?.code ?? writeError?.message ?? writeError})`;
    }
  }
  return { added, error };
}
