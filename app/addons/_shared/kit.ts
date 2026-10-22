// The one place the views touch agmsg-addon.js. Vite resolves "agmsg-addon-kit"
// to app/addon-kit/agmsg-addon.js (see makeConfig in vite.shared.ts).
import { connect } from "agmsg-addon-kit";
import type { DiffRequest, DiffResult, FsEntry, FsList, FsReadRange, FsReadResult, OpenArgs } from "../../addon-kit/protocol";

export interface AddonApp {
  readonly inApp: boolean;
  readonly sample: boolean;
  openArgs(): Promise<OpenArgs>;
  fs: {
    stat(path: string): Promise<FsEntry>;
    list(path?: string): Promise<FsList>;
    read(path: string, range?: FsReadRange): Promise<FsReadResult>;
  };
  git: { diff(req?: DiffRequest): Promise<DiffResult> };
}

export const app = connect({ errorOverlay: true }) as AddonApp;

export function errorText(e: unknown): string {
  if (e && typeof e === "object") {
    const { code, message } = e as { code?: string; message?: string };
    if (message) return code ? `${message} (${code})` : message;
  }
  return String(e);
}

export function errorCode(e: unknown): string {
  return e && typeof e === "object" ? String((e as { code?: string }).code || "") : "";
}
