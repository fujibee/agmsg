import { useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { createPaneRelay, type PaneRelay, type PushEvent } from "./paneRelay";

// The iframe of a live add-on pane. `url` is what addon_pane_add returned
// (http://127.0.0.1:<port>/<token>/); the sandbox is allow-scripts only, never
// allow-same-origin. Every load event, first or reload, starts a new generation
// through the relay; a change of scope (team or root granted, swapped or
// revoked) is a reload: bump `reloadKey` and the frame, port and generation are
// all replaced.

export const ADDON_FRAME_SANDBOX = "allow-scripts";

export function AddonFrame(props: {
  paneInstance: number;
  url: string;
  title: string;
  declaresMessages: boolean;
  reloadKey: number;
  onRefused?: (op: string, code: string) => void;
}) {
  const ref = useRef<HTMLIFrameElement>(null);
  const relayRef = useRef<PaneRelay | null>(null);
  const { paneInstance, declaresMessages, onRefused } = props;

  useEffect(() => {
    const relay = createPaneRelay({
      id: paneInstance,
      invoke: (cmd, args) => invoke(cmd, args),
      frameWindow: () => ref.current?.contentWindow ?? null,
      wantsFeed: declaresMessages,
      onRefused,
    });
    relayRef.current = relay;
    let unlisten: (() => void) | null = null;
    let disposed = false;
    void listen<PushEvent>("addon-push", (e) => relay.onPush(e.payload)).then((u) => {
      if (disposed) u();
      else unlisten = u;
    });
    return () => {
      disposed = true;
      unlisten?.();
      relay.closePort();
      relayRef.current = null;
    };
  }, [paneInstance, declaresMessages, onRefused]);

  return (
    <iframe
      key={props.reloadKey}
      ref={ref}
      className="addon-frame"
      title={props.title}
      src={props.url}
      sandbox={ADDON_FRAME_SANDBOX}
      onLoad={() => void relayRef.current?.onFrameLoad()}
    />
  );
}
