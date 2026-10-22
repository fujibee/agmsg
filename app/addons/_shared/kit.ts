// The one place the views touch agmsg-addon.js. Vite resolves "agmsg-addon-kit"
// to app/addon-kit/agmsg-addon.js (see makeConfig in vite.shared.ts).
import { connect } from "agmsg-addon-kit";
import type { DiffRequest, DiffResult, FsEntry, FsReadRange, OpenArgs } from "../../addon-kit/protocol";

/** What fs.read hands back; the broker may send text or bytes. */
export type ReadResult = string | ArrayBuffer | Uint8Array | { text: string } | { bytes: ArrayBuffer | Uint8Array };

export interface AddonApp {
  readonly inApp: boolean;
  readonly sample: boolean;
  openArgs(): Promise<OpenArgs>;
  fs: {
    stat(path: string): Promise<FsEntry>;
    list(path?: string): Promise<FsEntry[]>;
    read(path: string, range?: FsReadRange): Promise<ReadResult>;
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
