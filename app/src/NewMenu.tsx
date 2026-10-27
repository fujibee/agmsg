import { useEffect, useRef } from "react";
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

export function NewMenu(props: Props) {
  const { t, variant } = props;
  const wrap = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const menu = useRef<HTMLDivElement>(null);
  const entries = newMenuEntries(props);
  // The first enabled item takes focus when the menu opens, so "+ then Enter" chooses it (Shell, in the tab bar).
  useEffect(() => {
    if (!props.open) return;
    menu.current?.querySelector<HTMLButtonElement>("button:not(:disabled)")?.focus();
  }, [props.open]);
  // The tab strip scrolls (overflow-x), which would clip an absolutely placed popup: that one is fixed under its button.
  const rect = variant === "tabs" && props.open ? wrap.current?.getBoundingClientRect() : undefined;
  const style = rect ? { position: "fixed" as const, top: rect.bottom + 2, left: rect.left } : undefined;
  const onKeyDown = (e: React.KeyboardEvent) => {
    const items = [...(menu.current?.querySelectorAll<HTMLButtonElement>("button") ?? [])];
    const at = items.indexOf(document.activeElement as HTMLButtonElement);
    const move = (to: number) => {
      if (to >= 0) items[to]?.focus();
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
              <button key={e.key} role="menuitem" disabled={e.disabled} title={e.title} onClick={e.run}>
                {e.label}
              </button>
            ),
          )}
        </div>
      )}
    </div>
  );
}
