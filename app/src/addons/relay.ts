// The one place where an answer from the Rust broker becomes a message for an
// add-on's MessagePort (design 4.3). Rust returns plain JSON; bytes travel as
// base64 (`bytesBase64`). Add-ons must see exactly `{ bytes: ArrayBuffer, size,
// eof }` as in addon-kit/protocol.d.ts and never base64, so the conversion
// happens here, and only here, before `port.postMessage`.

export interface BrokerResponse {
  agmsg: 1;
  type: "response";
  ok: boolean;
  result?: Record<string, unknown>;
  error?: { code: string; message: string };
}

export interface PortMessage {
  message: Record<string, unknown>;
  /** Buffers to pass as the transfer list of `postMessage`. */
  transfer: ArrayBuffer[];
}

/** Standard base64 → a fresh ArrayBuffer. Throws on malformed input. */
export function base64ToArrayBuffer(b64: string): ArrayBuffer {
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(b64) || b64.length % 4 !== 0) {
    throw new Error("malformed base64");
  }
  const bin = atob(b64);
  const buf = new ArrayBuffer(bin.length);
  const view = new Uint8Array(buf);
  for (let i = 0; i < bin.length; i++) view[i] = bin.charCodeAt(i);
  return buf;
}

/**
 * Builds the message to post to the pane's port for request `id`.
 * An error or a malformed answer becomes an `{ok:false}` response, never a throw,
 * so a request never hangs.
 */
export function toPortMessage(id: number, resp: BrokerResponse): PortMessage {
  try {
    if (!resp || resp.agmsg !== 1 || resp.type !== "response") throw new Error("not a broker response");
    if (!resp.ok) {
      const e = resp.error ?? { code: "error", message: "request failed" };
      return { message: { agmsg: 1, type: "response", id, ok: false, error: { code: String(e.code), message: String(e.message) } }, transfer: [] };
    }
    const result = { ...(resp.result ?? {}) } as Record<string, unknown>;
    const transfer: ArrayBuffer[] = [];
    if (typeof result.bytesBase64 === "string") {
      const bytes = base64ToArrayBuffer(result.bytesBase64);
      delete result.bytesBase64;
      result.bytes = bytes;
      transfer.push(bytes);
    }
    return { message: { agmsg: 1, type: "response", id, ok: true, result }, transfer };
  } catch (e) {
    return {
      message: { agmsg: 1, type: "response", id, ok: false, error: { code: "error", message: `could not read the app's answer: ${(e as Error).message}` } },
      transfer: [],
    };
  }
}
