// The UI side of one add-on pane's port (design §4.2–§4.3). It only relays:
// every request goes to Rust with the pane instance and generation of THIS
// port (never anything the add-on put in the request), and Rust decides. A
// reload makes a new generation and a new port; the old port is closed and
// nothing posted for the old generation reaches the new one.

import { toPortMessage, type BrokerResponse } from "./relay";

export type PaneInstance = number;
export type Invoke = (cmd: string, args?: Record<string, unknown>) => Promise<unknown>;

export interface PortLike {
  onmessage: ((e: { data: unknown }) => void) | null;
  postMessage(message: unknown, transfer?: Transferable[]): void;
  close(): void;
}
export interface ChannelLike {
  port1: PortLike;
  port2: unknown;
}
export interface FrameWindowLike {
  postMessage(message: unknown, targetOrigin: string, transfer: Transferable[]): void;
}

/** `addon-push` event payload. */
export interface PushEvent {
  pane: PaneInstance;
  generation: number;
  event: unknown;
}

export interface PaneRelay {
  /** Call on EVERY iframe load event (first load and reload). */
  onFrameLoad(): Promise<void>;
  /** Call for each `addon-push` event. Dropped unless it is for this pane's current generation. */
  onPush(p: PushEvent): void;
  /** Closes the current port (revoke, remove, unmount). A later onFrameLoad starts a new generation. */
  closePort(): void;
  /** The generation the open port is bound to, or null. */
  generation(): number | null;
}

type Bound = { generation: number; port: PortLike };

const isRequest = (d: unknown): d is { agmsg: 1; type: "request"; id: number; op: string; args?: unknown } => {
  if (typeof d !== "object" || d === null) return false;
  const r = d as Record<string, unknown>;
  return r.agmsg === 1 && r.type === "request" && typeof r.id === "number" && Number.isFinite(r.id) && typeof r.op === "string";
};

function errorResponse(message: string): BrokerResponse {
  return { agmsg: 1, type: "response", ok: false, error: { code: "error", message } };
}

export function createPaneRelay(deps: {
  id: PaneInstance;
  invoke: Invoke;
  frameWindow: () => FrameWindowLike | null;
  /** True when the pane declares messages:read, so `init` is fed after the port is handed over. */
  wantsFeed: boolean;
  newChannel?: () => ChannelLike;
  /** Called when a broker op is refused, so the header can show "blocked: …" briefly. */
  onRefused?: (op: string, code: string) => void;
}): PaneRelay {
  const newChannel = deps.newChannel ?? (() => new MessageChannel() as unknown as ChannelLike);
  let bound: Bound | null = null;
  let loadSeq = 0;

  const closeBound = () => {
    if (!bound) return;
    bound.port.onmessage = null;
    bound.port.close();
    bound = null;
  };

  const handleRequest = async (mine: Bound, data: { id: number; op: string; args?: unknown }) => {
    let answer: BrokerResponse;
    try {
      // The identity is the pane and generation of this port, not the request's.
      answer = (await deps.invoke("addon_request", {
        id: deps.id,
        generation: mine.generation,
        op: data.op,
        args: data.args ?? {},
      })) as BrokerResponse;
    } catch (e) {
      answer = errorResponse(String(e));
    }
    if (bound !== mine) return; // the frame was reloaded or revoked meanwhile: drop the answer
    const { message, transfer } = toPortMessage(data.id, answer);
    if (message.ok === false) {
      const code = (message.error as { code?: string } | undefined)?.code ?? "error";
      deps.onRefused?.(data.op, code);
    }
    mine.port.postMessage(message, transfer);
  };

  return {
    async onFrameLoad() {
      const seq = ++loadSeq;
      closeBound();
      const generation = (await deps.invoke("addon_pane_loaded", { id: deps.id })) as number;
      if (seq !== loadSeq) return; // a newer load superseded this one
      const win = deps.frameWindow();
      if (!win) return;
      const channel = newChannel();
      const mine: Bound = { generation, port: channel.port1 };
      bound = mine;
      mine.port.onmessage = (e) => {
        if (bound !== mine || !isRequest(e.data)) return;
        void handleRequest(mine, e.data);
      };
      win.postMessage({ agmsg: 1, type: "port" }, "*", [channel.port2 as Transferable]);
      if (!deps.wantsFeed) return;
      try {
        const feed = (await deps.invoke("addon_feed_init", { id: deps.id, generation })) as { init: unknown; queued: unknown[] };
        if (bound !== mine) return;
        mine.port.postMessage(feed.init);
        for (const ev of feed.queued) mine.port.postMessage(ev);
      } catch {
        // No team allowed yet (or the frame was replaced): the grant card handles it; nothing is sent.
      }
    },
    onPush(p) {
      if (!bound || p.pane !== deps.id || p.generation !== bound.generation) return;
      bound.port.postMessage(p.event);
    },
    closePort: closeBound,
    generation: () => bound?.generation ?? null,
  };
}
