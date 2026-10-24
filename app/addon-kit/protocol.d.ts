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
  /**
   * diffview: "changes since the merge base with <base>". A branch or ref name is
   * compared as merge-base:<base>; a full 40-hex SHA is a direct comparison. (The
   * base field inside the view keeps the explicit forms: HEAD, a branch, a SHA or
   * merge-base:<branch>.)
   */
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

/** fs.list result. `truncated` is true when the folder has more than the broker's cap of entries. */
export interface FsList {
  entries: FsEntry[];
  truncated: boolean;
}

/**
 * fs.read result. Valid UTF-8 without a NUL byte comes back as `text`, anything
 * else as `bytes`. `size` is the file's size in bytes; `eof` is true when this
 * range reached the end of the file.
 */
export type FsReadResult =
  | { text: string; size: number; eof: boolean }
  | { bytes: ArrayBuffer; size: number; eof: boolean };

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

// ---- git.status / git.log / git.show ----------------------------------------

/** One changed file of git.status: the work tree compared with HEAD, untracked files included (as added). */
export interface GitStatusEntry {
  path: string;
  status: DiffStatus;
  /** Set for an exact rename. */
  oldPath?: string;
}

export interface GitStatus {
  files: GitStatusEntry[];
}

export interface GitLogRequest {
  /** Default HEAD. A ref name, a SHA or merge-base:<ref>. */
  rev?: string;
  /** Only commits that touched this file or folder. */
  path?: string;
  /** Default 50, at most 500. */
  limit?: number;
}

export interface GitCommit {
  sha: string;
  parents: string[];
  /** Name only: no e-mail address. */
  author: string;
  /** ISO 8601. */
  date: string;
  /** First line of the message. */
  subject: string;
}

export interface GitLog {
  commits: GitCommit[];
}

/** git.show(rev, path): a file at a revision. Same shape as fs.read, always the whole file (at most 10 MB). */
export type GitShowResult = FsReadResult;
