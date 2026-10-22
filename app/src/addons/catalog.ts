import { useCallback, useEffect, useState } from "react";
import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { mockEngine, mockSnapshot } from "./mock";
import { createLiveSource } from "./source";
import type { EngineState, InstalledAddon } from "./types";

// What the screens read of the add-on engine: the list of add-ons and whether
// add-ons are on. In the app it comes from Rust (addon_list, addon_gate_status,
// refreshed on the `addon-gate` event); in a plain browser (vite dev, no Tauri)
// it is the mock data, and `live` says which.

export type Catalog = {
  live: boolean;
  /** False until the first answer from Rust arrives (always true without Tauri). */
  ready: boolean;
  addons: InstalledAddon[];
  engine: EngineState;
  /** Ask Rust again (after the gate changes or something is installed or removed). */
  reload: () => void;
};

const live = isTauri();
const source = createLiveSource((cmd, args) => invoke(cmd, args));

export function useAddonCatalog(): Catalog {
  const [state, setState] = useState<{ ready: boolean; addons: InstalledAddon[]; engine: EngineState }>(
    live ? { ready: false, addons: [], engine: { ok: false, reasons: [] } } : { ready: true, addons: mockSnapshot.addons, engine: mockEngine },
  );
  const reload = useCallback(() => {
    if (!live) return;
    void (async () => {
      const engine = await source.engine();
      let addons: InstalledAddon[] = [];
      try {
        addons = await source.list();
      } catch {
        // The engine state already carries why add-ons are off; an empty list is the honest answer then.
      }
      setState({ ready: true, addons, engine });
    })();
  }, []);
  useEffect(() => {
    if (!live) return;
    reload();
    const un = listen("addon-gate", reload);
    return () => void un.then((f) => f());
  }, [reload]);
  return { live, ready: state.ready, addons: state.addons, engine: state.engine, reload };
}
