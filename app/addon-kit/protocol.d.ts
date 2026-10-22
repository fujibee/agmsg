// Types for the app add-on protocol v1 (app <-> add-on, over the pane's MessagePort).

export interface Member {
  name: string;
  type: string;
}

export interface Message {
  id: string; // may be a UUID on synced teams; order by array position or created_at
  team: string;
  from: string;
  to: string;
  body: string;
  created_at: string; // ISO 8601
  truncated?: true; // body cut at 256 KB
}

export interface InitEvent {
  team: string;
  members: Member[];
  messages: Message[]; // at most 500, newest kept
}

export interface OpenArgs {
  path?: string;
  url?: string;
  base?: string;
}

export interface FsEntry {
  name: string;
  kind: "file" | "dir";
  size: number;
  mtime: string;
}

export type ErrorCode =
  | "not_declared"
  | "not_granted"
  | "outside_root"
  | "denied_path"
  | "unsupported_repo"
  | "too_large"
  | "not_found"
  | "bad_args"
  | "not_available";

/** fs.read: a byte range. Omitted = from the start. One call is capped at 10 MB. */
export interface FsReadRange {
  offset: number;
  length: number;
}

// ---- git.diff (permission git:read, plus files:read on the repo root) ----

/**
 * Proposal for git.diff, computed by the app in Rust (blob vs blob, blob vs
 * worktree file). Plain data: everything here is JSON-serializable.
 *
 * Revisions: a ref name, a SHA, "HEAD", or "merge-base:<ref>" (the merge base of
 * <ref> and HEAD). Without `base`, the base is "HEAD". Without `head`, the other
 * side is the working tree.
 */
export interface DiffRequest {
  base?: string;
  head?: string;
  /** Restrict to one file or folder, relative to the root. */
  path?: string;
  /** Unchanged lines around each change. Default 3. "all" = whole files. */
  context?: number | "all";
}

export type DiffStatus =
  | "added"
  | "modified"
  | "deleted"
  | "renamed"
  | "copied"
  | "typechange";

export interface DiffLine {
  type: "context" | "add" | "del";
  /** Without the line terminator. */
  text: string;
  /** Line number on the base side; null for an added line. */
  oldNo: number | null;
  /** Line number on the head side; null for a deleted line. */
  newNo: number | null;
  /** The file has no newline at the end on this line's side. */
  noEol?: boolean;
}

export interface DiffHunk {
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  /** The enclosing function or section, when git can tell (like @@ ... @@ text). */
  section?: string;
  lines: DiffLine[];
}

export interface DiffFile {
  /** Path on the head side (or the base side for a deleted file). */
  path: string;
  /** Path on the base side, when it differs (renamed or copied). */
  oldPath?: string;
  status: DiffStatus;
  /** Binary files carry no hunks. */
  binary: boolean;
  additions: number;
  deletions: number;
  /** Rename or copy similarity, 0..100. */
  similarity?: number;
  oldMode?: string;
  newMode?: string;
  /** Hunks were left out because the file is over the size limit. */
  tooLarge?: boolean;
  hunks: DiffHunk[];
}

export interface DiffResult {
  base: { rev: string; sha: string };
  /** `worktree: true` = compared with the working tree. */
  head: { rev?: string; sha?: string; worktree: boolean };
  files: DiffFile[];
  /** Totals over all files, including ones whose hunks were left out. */
  additions: number;
  deletions: number;
  /** The file list itself was cut at the broker's cap. */
  truncated?: boolean;
}
