import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Plus } from "lucide-react";
import type { AddonPaneRef, EngineState, InstalledAddon } from "./addons/types";

// The two "new" menus, one component. The tab bar's + opens a menu of what can fill a pane: Shell first,
// then File view…, Diff view…, every enabled installed or developer add-on pane, and Install add-ons….
// The collapsed rail's + only adds a team or an agent. Keyboard: arrows move, Enter chooses, Escape closes.

export type NewMenuVariant = "rail" | "tabs";

type Props = {
  variant: NewMenuVariant;
  t: (key: string, o?: Record<string, unknown>) => string;
  open: boolean;
  onToggle: () => void;
  onClose: () => void;
  team: string | null;
  addonEngine: EngineState;
  addons: InstalledAddon[];
  onTeam: () => void;
  onAgent: () => void;
  onShell: () => void;
  onOpenAddon: (ref: AddonPaneRef) => void;
  onInstall: () => void;
};

/** Every enabled installed or developer pane, for the menu (the built-in panes are listed on their own). */
export function addonMenuPanes(addons: InstalledAddon[]) {
  return addons.filter((a) => !a.builtin && a.enabled).flatMap((a) => a.panes.map((p) => ({ a, p })));
}

export type MenuEntry = { key: string; label: string; disabled: boolean; title?: string; separator?: boolean; run: () => void };

/** What a menu lists, in order. Each `run` closes the menu first, then does its action. */
export function newMenuEntries(props: Omit<Props, "open" | "onToggle">): MenuEntry[] {
  const { t, addonEngine } = props;
  const go = (fn: () => void) => () => {
    props.onClose();
    fn();
  };
  if (props.variant === "rail") {
    return [
      { key: "team", label: t("sidebar.newMenu.team"), disabled: false, run: go(props.onTeam) },
      { key: "agent", label: t("sidebar.newMenu.agent"), disabled: !props.team, run: go(props.onAgent) },
    ];
  }
  const off = !props.team || !addonEngine.ok;
  const why = addonEngine.ok ? undefined : addonEngine.reasons.join("; ");
  const pane = (key: string, label: string, ref: AddonPaneRef): MenuEntry => ({ key, label, disabled: off, title: why, run: go(() => props.onOpenAddon(ref)) });
  return [
    { key: "shell", label: t("tabs.shellLabel"), disabled: false, run: go(props.onShell) },
    { key: "sep", label: "", disabled: true, separator: true, run: () => {} },
    pane("fileview", t("addons.menu.fileViewEntry"), { addonId: "builtin:fileview", paneName: "fileview", title: t("addons.menu.fileView") }),
    pane("diffview", t("addons.menu.diffViewEntry"), { addonId: "builtin:diffview", paneName: "diffview", title: t("addons.menu.diffView") }),
    ...addonMenuPanes(props.addons).map(({ a, p }) => pane(`${a.id}/${p.name}`, t("addons.menu.addonPane", { title: p.title }), { addonId: a.id, paneName: p.name, title: p.title })),
    { key: "install", label: t("addons.menu.install"), disabled: false, run: go(props.onInstall) },
  ];
}

/** The next enabled item for an arrow key, wrapping around; -1 when nothing can take focus. */
export function nextIndex(enabled: boolean[], from: number, step: 1 | -1): number {
  const n = enabled.length;
  for (let i = 1; i <= n; i++) {
    const j = (((from + step * i) % n) + n) % n;
    if (enabled[j]) return j;
  }
  return -1;
}

const EDGE = 8; // the gap kept to the window edge
const MIN_HEIGHT = 120;

/**
 * Where the fixed popup goes: under its button, pulled left so it stays inside the window, and no taller than the
 * space below it (the menu scrolls inside that height, so the last entry stays reachable however many panes there are).
 */
export function placeMenu(anchor: { left: number; bottom: number }, width: number, viewport: { w: number; h: number }) {
  const left = Math.max(EDGE, Math.min(anchor.left, viewport.w - width - EDGE));
  const top = anchor.bottom + 2;
  return { left, top, maxHeight: Math.max(MIN_HEIGHT, viewport.h - top - EDGE) };
}

export function NewMenu(props: Props) {
  const { t, variant } = props;
  const wrap = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const entries = newMenuEntries(props);
  // The first enabled item takes focus when the menu opens, so "+ then Enter" chooses it (Shell, in the tab bar).
  useEffect(() => {
    if (!props.open) return;
    const first = menu.current?.querySelector<HTMLButtonElement>("button:not(:disabled)");
    first?.focus({ preventScroll: true });
    setActive(first?.dataset.key ?? null); // set directly: a focus event does not fire while the window itself is not focused
  }, [props.open]);
  const [active, setActive] = useState<string | null>(null);
  const [pos, setPos] = useState<{ left: number; top: number; maxHeight: number } | null>(null);
  // The tab strip scrolls (overflow-x), which would clip an absolutely placed popup: that one is fixed under its
  // button, placed once when it opens (clamped to the window), and closed when the strip scrolls or the window
  // changes, so it never stays behind in the old place.
  useLayoutEffect(() => {
    if (variant !== "tabs" || !props.open) return setPos(null);
    const r = wrap.current?.getBoundingClientRect();
    const w = menu.current?.offsetWidth ?? 220;
    if (r) setPos(placeMenu(r, w, { w: window.innerWidth, h: window.innerHeight }));
  }, [variant, props.open]);
  const { onClose } = props;
  useEffect(() => {
    if (!props.open || variant !== "tabs") return;
    const close = () => onClose();
    const onScroll = (e: Event) => {
      if (!menu.current?.contains(e.target as Node)) onClose(); // the menu's own scrolling does not close it
    };
    window.addEventListener("resize", close);
    window.addEventListener("blur", close);
    window.addEventListener("scroll", onScroll, true);
    return () => {
      window.removeEventListener("resize", close);
      window.removeEventListener("blur", close);
      window.removeEventListener("scroll", onScroll, true);
    };
  }, [props.open, variant, onClose]);
  useEffect(() => {
    if (!props.open) setActive(null);
  }, [props.open]);
  const style = pos ? { position: "fixed" as const, top: pos.top, left: pos.left, maxHeight: pos.maxHeight, overflowY: "auto" as const } : undefined;
  const onKeyDown = (e: React.KeyboardEvent) => {
    const items = [...(menu.current?.querySelectorAll<HTMLButtonElement>("button") ?? [])];
    const at = items.indexOf(document.activeElement as HTMLButtonElement);
    const move = (to: number) => {
      if (to < 0) return;
      items[to]?.focus({ preventScroll: true });
      // focus() alone would not bring a row below the fold into view; the menu's own scrolling does not close it
      items[to]?.scrollIntoView({ block: "nearest", inline: "nearest" });
      setActive(items[to]?.dataset.key ?? null);
    };
    if (e.key === "ArrowDown") move(nextIndex(items.map((b) => !b.disabled), at, 1));
    else if (e.key === "ArrowUp") move(nextIndex(items.map((b) => !b.disabled), at < 0 ? 0 : at, -1));
    else if (e.key === "Home") move(nextIndex(items.map((b) => !b.disabled), -1, 1));
    else if (e.key === "End") move(nextIndex(items.map((b) => !b.disabled), 0, -1));
    else if (e.key === "Escape") {
      props.onClose();
      trigger.current?.focus();
    } else return;
    e.preventDefault();
    e.stopPropagation();
  };
  return (
    <div className={`new-wrap new-wrap-${variant}`} ref={wrap} onClick={(e) => e.stopPropagation()}>
      {variant === "rail" ? (
        <button ref={trigger} className="rail-icon-btn" title={t("sidebar.newMenu.trigger")} aria-haspopup="menu" aria-expanded={props.open} onClick={props.onToggle}>
          +
        </button>
      ) : (
        <button ref={trigger} className="tab-new-shell" title={t("tabs.newMenu")} aria-label={t("tabs.newMenu")} aria-haspopup="menu" aria-expanded={props.open} onClick={props.onToggle}>
          <Plus size={13} />
        </button>
      )}
      {props.open && (
        <div ref={menu} className={`new-menu new-menu-${variant}${variant === "rail" ? " rail-popup" : ""}`} role="menu" style={style} onKeyDown={onKeyDown}>
          {entries.map((e) =>
            e.separator ? (
              <div key={e.key} className="new-menu-sep" role="separator" />
            ) : (
              <button key={e.key} role="menuitem" data-key={e.key} className={active === e.key ? "is-active" : undefined} disabled={e.disabled} title={e.title} onClick={e.run} onFocus={() => setActive(e.key)} onMouseEnter={(ev) => {
                  if (e.disabled) return;
                  ev.currentTarget.focus({ preventScroll: true });
                  setActive(e.key);
                }}>
                {e.label}
              </button>
            ),
          )}
        </div>
      )}
    </div>
  );
}
