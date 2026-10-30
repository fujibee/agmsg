import { useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { PaneRelay, PushEvent } from "./paneRelay";
import { startFrameRelay } from "./frameRelay";

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
  onFeedFailed?: (code: string, message: string) => void;
  /** The frame's document finished loading (every load, first or reload). Only for a "loading" cover; the relay is not involved. */
  onLoaded?: () => void;
}) {
  const ref = useRef<HTMLIFrameElement>(null);
  const relayRef = useRef<PaneRelay | null>(null);
  const { paneInstance, declaresMessages } = props;
  // The callback lives in a ref: a new identity must not rebuild the relay (a rebuilt relay gets no port without a new load).
  const onRefusedRef = useRef(props.onRefused);
  onRefusedRef.current = props.onRefused;
  const onFeedFailedRef = useRef(props.onFeedFailed);
  onFeedFailedRef.current = props.onFeedFailed;

  useEffect(() => {
    const { relay, dispose } = startFrameRelay({
      paneInstance,
      wantsFeed: declaresMessages,
      invoke: (cmd, args) => invoke(cmd, args),
      listen: (event, handler) => listen<PushEvent>(event, handler),
      frameWindow: () => ref.current?.contentWindow ?? null,
      onRefused: () => onRefusedRef.current,
      onFeedFailed: () => onFeedFailedRef.current,
    });
    relayRef.current = relay;
    return () => {
      dispose();
      relayRef.current = null;
    };
  }, [paneInstance, declaresMessages]);

  return (
    <iframe
      key={props.reloadKey}
      ref={ref}
      className="addon-frame"
      title={props.title}
      src={props.url}
      sandbox={ADDON_FRAME_SANDBOX}
      onLoad={() => {
        void relayRef.current?.onFrameLoad();
        props.onLoaded?.();
      }}
    />
  );
}
