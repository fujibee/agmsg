import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { createLiveSource } from "./source";
import { toCtrlView, type CtrlOpened, type CtrlScanView } from "./ctrl";
import { latestWins } from "./latestWins";
import type { BarItem } from "./requests";

// S10 on the real rows. The rows are read from Rust when the tab opens and on
// every new message to the team, and again after each click. While add-ons are
// off nothing is asked. Rust decides what each row can do; a read that fails
// (e.g. the handled-request record cannot be read) is shown in place of the bar,
// with no Open. The click on Open asks Rust, which re-checks from the store and
// records it; it grants nothing: the pane that opens asks for its own permissions.

const source = createLiveSource((cmd, args) => invoke(cmd, args));

export type CtrlRequests = {
  /** Null until the first read, or while add-ons are off. */
  view: CtrlScanView | null;
  /** Rust's words when the rows could not be read: shown instead of the bar. */
  error: string | null;
  /** Rust's words when the last Open or Dismiss was refused. */
  actionError: { code: string; message: string } | null;
  act: (item: BarItem, opened: boolean) => void;
};

export function useCtrlRequests(props: {
  /** Only in the app, with add-ons on. */
  enabled: boolean;
  team: string;
  onOpened: (opened: CtrlOpened, item: BarItem) => void;
}): CtrlRequests {
  const live = isTauri();
  const { team } = props;
  const enabled = props.enabled && live && team !== "";
  const [state, setState] = useState<{ view: CtrlScanView | null; error: string | null }>({ view: null, error: null });
  const [actionError, setActionError] = useState<{ code: string; message: string } | null>(null);
  const tickets = useMemo(() => latestWins(), []);
  const onOpened = useRef(props.onOpened);
  onOpened.current = props.onOpened;
  // The team shown now: a click answered after the user moved to another team still opened (Rust recorded it), but must not drop a pane into the wrong team's tab.
  const teamNow = useRef(team);
  teamNow.current = team;

  const refresh = useCallback(async () => {
    const current = tickets.next();
    const r = await source.ctrlRows(team);
    if (!current()) return;
    setState(r.ok ? { view: toCtrlView(r.value), error: null } : { view: null, error: r.error.message });
  }, [team, tickets]);

  useEffect(() => {
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
    };
  }, [enabled, team, refresh, tickets]);

  const act = useCallback(
    (item: BarItem, opened: boolean) => {
      if (!enabled) return;
      setActionError(null);
      void (async () => {
        if (opened) {
          const r = await source.ctrlOpen(team, item.requestId);
          if (!r.ok) setActionError(r.error);
          else if (teamNow.current === team) onOpened.current(r.value, item);
          else setActionError({ code: "team_changed", message: "" });
        } else {
          const r = await source.ctrlDismiss(team, item.requestId);
          if (!r.ok) setActionError(r.error);
        }
        await refresh();
      })();
    },
    [enabled, team, refresh],
  );

  return { view: state.view, error: state.error, actionError, act };
}
