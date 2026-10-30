import { useSyncExternalStore } from "react";

// Settings → Add-ons → "Open requests from seats": show them in the bar, or
// don't read them at all. A per-viewer convenience, so it lives in localStorage
// (the page renders correctly without it: the default is show) and is shared
// between the Settings tab and the bar through one change event.
//
// When storage cannot be written, the latest choice still holds until reload:
// an unsaved choice wins over whatever is stored, and a write that succeeds
// clears it.

export type OpenRequestsSetting = "show" | "off";

type Store = Pick<Storage, "getItem" | "setItem">;

const KEY = "agmsg.addons.openRequests";

export function createOpenRequestsSetting(storage: () => Store | null, notify: () => void) {
  let unsaved: OpenRequestsSetting | null = null;
  const stored = (): OpenRequestsSetting => {
    try {
      return storage()?.getItem(KEY) === "off" ? "off" : "show";
    } catch {
      return "show";
    }
  };
  return {
    read(): OpenRequestsSetting {
      return unsaved ?? stored();
    },
    write(v: OpenRequestsSetting): void {
      try {
        const s = storage();
        if (!s) throw new Error("no storage");
        s.setItem(KEY, v);
        unsaved = null;
      } catch {
        unsaved = v;
      }
      notify();
    },
  };
}

const EVENT = "agmsg-open-requests-setting";
const setting = createOpenRequestsSetting(
  () => {
    try {
      return window.localStorage;
    } catch {
      return null;
    }
  },
  () => window.dispatchEvent(new Event(EVENT)),
);

function subscribe(cb: () => void): () => void {
  window.addEventListener(EVENT, cb);
  window.addEventListener("storage", cb);
  return () => {
    window.removeEventListener(EVENT, cb);
    window.removeEventListener("storage", cb);
  };
}

export function useOpenRequestsSetting(): [OpenRequestsSetting, (v: OpenRequestsSetting) => void] {
  const value = useSyncExternalStore(subscribe, setting.read, () => "show" as OpenRequestsSetting);
  return [value, setting.write];
}
