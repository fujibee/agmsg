import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { createLiveSource } from "./source";
import { toOpenView, type OpenedRequest, type OpenScanView } from "./openRequests";
import { runOpenRequestAction } from "./openRequestAction";
import { latestWins } from "./latestWins";

// S10 on the real rows. The rows are read from Rust when the tab opens and on
// every new message to the team, and again after each click. While add-ons are
// off nothing is asked. Rust decides what each row can do; a read that fails
// (e.g. the handled-request record cannot be read) is shown in place of the bar,
// with no Open. The click on Open asks Rust, which re-checks from the store and
// records it; it grants nothing: the pane that opens asks for its own permissions.

const source = createLiveSource((cmd, args) => invoke(cmd, args));

export type OpenRequests = {
  /** Null until the first read, or while add-ons are off. */
  view: OpenScanView | null;
  /** Rust's words when the rows could not be read: shown instead of the bar. */
  error: string | null;
  /** Rust's words when the last Open or Dismiss was refused. */
  actionError: { code: string; message: string } | null;
  /** Open (true) or dismiss (false) one request line by its id. */
  act: (requestId: string, opened: boolean) => void;
};

export function useOpenRequests(props: {
  /** Only in the app, with add-ons on. */
  enabled: boolean;
  team: string;
  onOpened: (opened: OpenedRequest) => void;
}): OpenRequests {
  const live = isTauri();
  const { team } = props;
  const enabled = props.enabled && live && team !== "";
  const [state, setState] = useState<{ view: OpenScanView | null; error: string | null }>({ view: null, error: null });
  const [actionError, setActionError] = useState<{ code: string; message: string } | null>(null);
  const tickets = useMemo(() => latestWins(), []);
  const onOpened = useRef(props.onOpened);
  onOpened.current = props.onOpened;
  // Bumped whenever the scope (mount, team, on/off) changes or ends. A click
  // answered in an older scope still took effect in Rust, but it must not open
  // a pane, set a message or re-read rows for a team that is no longer shown.
  const scope = useMemo(() => latestWins(), []);

  const refresh = useCallback(async () => {
    const current = tickets.next();
    const r = await source.openRequests(team);
    if (!current()) return;
    setState(r.ok ? { view: toOpenView(r.value), error: null } : { view: null, error: r.error.message });
  }, [team, tickets]);

  useEffect(() => {
    scope.cancel();
    setActionError(null);
    if (!enabled) {
      tickets.cancel();
      setState({ view: null, error: null });
      return;
    }
    void refresh();
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void listen<{ team: string }>("agmsg-message", (e) => {
      if (!disposed && e.payload.team === team) void refresh();
    }).then((u) => {
      if (disposed) u();
      else unlisten = u;
    });
    return () => {
      disposed = true;
      unlisten?.();
      tickets.cancel();
      scope.cancel();
    };
  }, [enabled, team, refresh, tickets, scope]);

  const act = useCallback(
    (requestId: string, opened: boolean) => {
      if (!enabled) return;
      const current = scope.snapshot();
      setActionError(null);
      void runOpenRequestAction(opened, {
        current,
        open: () => source.openRequestOpen(team, requestId),
        dismiss: () => source.openRequestDismiss(team, requestId),
        onOpened: (o) => onOpened.current(o),
        setError: setActionError,
        refresh,
      });
    },
    [enabled, team, refresh, scope],
  );

  return { view: state.view, error: state.error, actionError, act };
}
