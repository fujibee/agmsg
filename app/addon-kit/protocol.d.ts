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

// git.* result shapes: to be added (diffview).
