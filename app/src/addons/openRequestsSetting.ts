import { useSyncExternalStore } from "react";

// Settings → Add-ons → "Open requests from seats": show them in the bar, or
// don't read them at all. A per-viewer convenience, so it lives in localStorage
// (the page renders correctly without it: the default is show) and is shared
// between the Settings tab and the bar through one change event.

export type OpenRequestsSetting = "show" | "off";

const KEY = "agmsg.addons.openRequests";
const EVENT = "agmsg-open-requests-setting";

export function readOpenRequestsSetting(): OpenRequestsSetting {
  try {
    return localStorage.getItem(KEY) === "off" ? "off" : "show";
  } catch {
    return "show";
  }
}

export function writeOpenRequestsSetting(v: OpenRequestsSetting): void {
  try {
    localStorage.setItem(KEY, v);
  } catch {
    // storage blocked: the choice holds until reload through the event below
    memory = v;
  }
  window.dispatchEvent(new Event(EVENT));
}

let memory: OpenRequestsSetting | null = null;
const current = (): OpenRequestsSetting => {
  const stored = readOpenRequestsSetting();
  return memory !== null && stored === "show" ? memory : stored;
};

function subscribe(cb: () => void): () => void {
  window.addEventListener(EVENT, cb);
  window.addEventListener("storage", cb);
  return () => {
    window.removeEventListener(EVENT, cb);
    window.removeEventListener("storage", cb);
  };
}

export function useOpenRequestsSetting(): [OpenRequestsSetting, (v: OpenRequestsSetting) => void] {
  const value = useSyncExternalStore(subscribe, current, () => "show" as OpenRequestsSetting);
  return [value, writeOpenRequestsSetting];
}
