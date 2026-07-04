import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { TerminalPane } from "./TerminalPane";
import {
  AgentModal,
  AppUserModal,
  ConfirmModal,
  NewTeamModal,
  RenameModal,
  SettingsModal,
} from "./modals";
import "./App.css";

export type Member = { name: string; types: string[]; project: string };
type Message = {
  id: number;
  team: string;
  from: string;
  to: string;
  body: string;
  created_at: string;
};
type Pane = {
  id: string;
  label: string;
  cmd: string;
  args: string[];
  cwd?: string;
  /** True only when this pane's type self-delivers agmsg messages (manifest
   *  monitor=yes) — the app must NOT also inject there (double-delivery).
   *  False for actas-booted types with no monitor of their own (codex,
   *  grok-build, hermes, ...): the app's stdin-inject IS their only delivery. */
  native: boolean;
};
// A tab. Holds one or more panes, arranged per its `layout` (see paneRect) —
// a flat split for now, ahead of tmux-style nested layouts later.
type Window = {
  id: string;
  paneIds: string[];
  /** User-set tab name (Rename); falls back to the joined pane labels. */
  customLabel?: string;
  /** The team this tab was spawned under. Agents can't message across
   *  teams, so a window's tab set is scoped to one team — showing another
   *  team's tabs alongside it would imply cross-team messaging works when
   *  it doesn't. Windows for other teams stay mounted (PTYs alive) but
   *  hidden until that team is selected again. */
  team: string;
  /** How this tab's panes are arranged. "vertical" (default, what plain
   *  spawn produces): side-by-side full-height columns. "horizontal":
   *  stacked full-width rows. "tile": a grid, row count/sizes from
   *  tileRowSizes — see its comment for the rule. */
  layout: PaneLayout;
};
type PaneLayout = "vertical" | "horizontal" | "tile";
type Modal =
  | { kind: "team"; firstRun: boolean }
  | { kind: "agent" }
  | { kind: "appuser" }
  | { kind: "rename"; current: string }
  | { kind: "leave"; name: string }
  | { kind: "settings" }
  | { kind: "closeWindow"; windowId: string }
  | { kind: "closePane"; paneId: string }
  | null;

// The agmsg type that represents the human at the app (the bottom chat box owner).
export const APP_USER_TYPE = "agmsg-app";
// Team-room history page size — the initial load, and each scroll-up "load more".
const ROOM_PAGE_SIZE = 30;
// Persists which team was selected across restarts. Window/pane state is
// deliberately NOT persisted (yet) — just landing on the same team is
// enough for now; panes always start fresh each launch anyway (they're
// live PTYs, not something a restart could restore even if we tried).
const LAST_TEAM_KEY = "agmsg-app-last-team";
// Custom drag-and-drop MIME type for pane-swap drags (see PANE_DRAG_MIME
// usages below) — a made-up type, not text/plain, so a stray OS file drag
// or an unrelated drag elsewhere on the page never accidentally matches a
// pane-cell's drop zone.
const PANE_DRAG_MIME = "application/x-agmsg-pane";
// A spawnable agent type discovered from agmsg's type registry.
export type AgentType = { name: string; cli: string; options: string[] };

// Row sizes for the "tile" layout, front-loading the extra pane(s) onto the
// earlier (top) rows: n=1→[1], 2→[2], 3→[2,1], 4→[2,2], 5→[3,2], 6→[3,3],
// 7→[4,3], 8→[4,4], 9→[3,3,3]. Row count caps at 4 columns/row (using 2 rows
// once that's exceeded) and never drops below 2 rows once n≥3 — a single
// row of 3+ reads as "vertical" layout, not a tile grid.
function tileRowSizes(n: number): number[] {
  const rows = n <= 2 ? 1 : Math.max(2, Math.ceil(n / 4));
  const base = Math.floor(n / rows);
  const extra = n % rows;
  return Array.from({ length: rows }, (_, i) => base + (i < extra ? 1 : 0));
}

type PaneRect = { left: number; top: number; width: number; height: number };

// A pane's position/size (all percentages of the tab's stage area) for
// `layout`, given its index among `count` panes in the same window.
function paneRect(layout: PaneLayout, idx: number, count: number): PaneRect {
  if (layout === "horizontal") {
    return { left: 0, width: 100, top: (idx * 100) / count, height: 100 / count };
  }
  if (layout === "tile") {
    const rowSizes = tileRowSizes(count);
    let seen = 0;
    for (let row = 0; row < rowSizes.length; row++) {
      const rowSize = rowSizes[row];
      if (idx < seen + rowSize) {
        const col = idx - seen;
        return {
          left: (col * 100) / rowSize,
          width: 100 / rowSize,
          top: (row * 100) / rowSizes.length,
          height: 100 / rowSizes.length,
        };
      }
      seen += rowSize;
    }
  }
  // "vertical" (default): side-by-side full-height columns.
  return { left: (idx * 100) / count, width: 100 / count, top: 0, height: 100 };
}

export default function App() {
  const { t } = useTranslation();
  // Set when a startup call that the whole app depends on (loading teams)
  // fails outright — most commonly agmsg isn't installed at
  // ~/.agents/skills/agmsg. Without this the app would just render an empty
  // shell with no indication anything is wrong (the failure was previously
  // swallowed by a bare `.catch(console.error)`).
  const [startupError, setStartupError] = useState<string | null>(null);
  // First-run flow: if agmsg isn't detected at all, install the bundled
  // copy (see agmsg_install in agmsg.rs) before attempting to load teams.
  const [installingAgmsg, setInstallingAgmsg] = useState(false);
  // Set when an EXISTING agmsg install predates what this app build needs
  // (e.g. a v0.1.0 user whose CLI has no agmsg-app type at all) — a stale
  // install still passes agmsg_is_installed(), so this is a separate check.
  // Never updated automatically: only ever from the user clicking Update.
  const [coreOutdated, setCoreOutdated] = useState<{ installed: string | null; pinned: string } | null>(null);
  const [updatingCore, setUpdatingCore] = useState(false);
  // The version just updated to, shown as a confirmation banner — Update now
  // otherwise completes silently (the outdated banner just disappears),
  // which read as "did that actually work?" in testing.
  const [coreUpdateSucceeded, setCoreUpdateSucceeded] = useState<string | null>(null);
  const [teams, setTeams] = useState<string[]>([]);
  const [team, setTeam] = useState<string>("");
  const [members, setMembers] = useState<Member[]>([]);
  const [messages, setMessages] = useState<Message[]>([]);
  const [panes, setPanes] = useState<Pane[]>([]);
  const [windows, setWindows] = useState<Window[]>([]);
  const [active, setActive] = useState<string>("room");
  const [target, setTarget] = useState<string>("");
  const [draft, setDraft] = useState<string>("");
  const [modal, setModal] = useState<Modal>(null);
  const [newMenu, setNewMenu] = useState(false);
  const [cmdName, setCmdName] = useState("agmsg");
  const [spawnTypes, setSpawnTypes] = useState<AgentType[]>([]);
  const [sidebarWidth, setSidebarWidth] = useState(200);
  const [chatHeight, setChatHeight] = useState(160);
  // Toggled from the native "View > Show User Chat" menu item.
  const [showUserChat, setShowUserChat] = useState(true);
  // Team-room member filter: names the user has UN-checked (default: all shown).
  const [deselected, setDeselected] = useState<Set<string>>(new Set());
  // Team-room history paging: whether an older page exists, and whether one
  // is currently loading (guards against duplicate scroll-triggered fetches).
  const [hasMoreHistory, setHasMoreHistory] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(false);
  // Right-click context menu over a member row: { member, x, y } while open.
  const [memberMenu, setMemberMenu] = useState<{ member: Member; x: number; y: number } | null>(
    null,
  );
  // Right-click context menu over a pane's header: { paneId, windowId, x, y }.
  const [paneMenu, setPaneMenu] = useState<{
    paneId: string;
    windowId: string;
    x: number;
    y: number;
  } | null>(null);
  // Right-click context menu over a tab: { windowId, x, y }.
  const [windowMenu, setWindowMenu] = useState<{ windowId: string; x: number; y: number } | null>(
    null,
  );
  // Swap two panes' positions by name: click one pane's name to "pick it
  // up" (its id goes here), then click another pane's name in the same
  // window to swap. Click the same name again to cancel. Also doubles as
  // the HTML5 drag source id during a drag-and-drop swap (dragstart sets
  // it, dragend clears it) — click and drag share this one state and the
  // same "armed" highlight, since they're just two ways to pick the same
  // pane up.
  const [swapSource, setSwapSource] = useState<string | null>(null);
  // The pane currently under the cursor during a drag — highlighted as the
  // drop target. Separate from swapSource: that's "picked up", this is
  // "hovering over".
  const [dragOverPaneId, setDragOverPaneId] = useState<string | null>(null);
  // Same idea, but for tabs — dropping a pane header on a tab moves it into
  // that tab instead of swapping within the current one.
  const [dragOverWindowId, setDragOverWindowId] = useState<string | null>(null);
  // Dropping on the empty strip past the last tab moves the pane to a new
  // tab of its own — same as ctxMenu.pane.moveNewTab, just via drag.
  const [dragOverNewTab, setDragOverNewTab] = useState(false);
  // Which tab is currently showing an inline rename input, and its draft text.
  const [renamingWindowId, setRenamingWindowId] = useState<string | null>(null);
  const [renameDraft, setRenameDraft] = useState("");
  const renameDraftRef = useRef("");
  renameDraftRef.current = renameDraft;
  const seq = useRef(0);
  const feedRef = useRef<HTMLDivElement>(null);
  // Set right before prepending an older history page, so the scroll-to-
  // bottom effect below skips that render (loadOlderMessages restores the
  // scroll position itself instead).
  const isPrependingRef = useRef(false);
  // Guards Enter-to-submit inputs against IME composition. isComposing alone
  // isn't quite enough on WebKit: the Enter that confirms a Japanese/Chinese/
  // Korean IME candidate can arrive with isComposing already false, so we also
  // ignore Enter for a brief window right after compositionend.
  const imeComposingRef = useRef(false);
  const imeEndedAtRef = useRef(0);
  const imeCompositionProps = {
    onCompositionStart: () => {
      imeComposingRef.current = true;
    },
    onCompositionEnd: () => {
      imeComposingRef.current = false;
      imeEndedAtRef.current = Date.now();
    },
  };
  const isSubmitEnter = (e: React.KeyboardEvent) =>
    e.key === "Enter" &&
    !e.nativeEvent.isComposing &&
    !imeComposingRef.current &&
    Date.now() - imeEndedAtRef.current > 150;
  const chatRef = useRef<HTMLDivElement>(null);
  const composerInputRef = useRef<HTMLInputElement>(null);
  const panesRef = useRef<Pane[]>([]);
  panesRef.current = panes;
  const windowsRef = useRef<Window[]>([]);
  windowsRef.current = windows;

  // The app user = the member registered with the agmsg-app type (one per team).
  const appUserMember = members.find((m) => m.types.includes(APP_USER_TYPE));
  const appUser = appUserMember?.name ?? "";
  // The team's project dir (the app-user's) — new agents default into the same place.
  const teamProject = appUserMember?.project ?? "";
  // Everyone else is a spawnable/messageable agent.
  const others = members.filter((m) => !m.types.includes(APP_USER_TYPE));
  // The app user's own send/receive thread.
  const myThread = messages.filter((m) => m.from === appUser || m.to === appUser);

  // Team-room member filter: keep a message when either party is a checked
  // member. Names not in the roster (e.g. the app-user) ride on their counterpart.
  const otherNames = new Set(others.map((m) => m.name));
  const roomMessages = messages.filter(
    (m) =>
      (otherNames.has(m.from) && !deselected.has(m.from)) ||
      (otherNames.has(m.to) && !deselected.has(m.to)),
  );

  // Cozy grouping: collapse runs of consecutive messages with the same from→to
  // into one header + stacked bodies (Slack/Discord style), so short bursts stay
  // light while long messages still line up.
  const groups: { key: number; from: string; to: string; items: Message[] }[] = [];
  for (const m of roomMessages) {
    const last = groups[groups.length - 1];
    if (last && last.from === m.from && last.to === m.to) last.items.push(m);
    else groups.push({ key: m.id, from: m.from, to: m.to, items: [m] });
  }

  const toggleMember = (name: string) =>
    setDeselected((prev) => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });
  const selectAllMembers = () => setDeselected(new Set());
  const selectNoMembers = () => setDeselected(new Set(others.map((m) => m.name)));

  const loadTeams = useCallback(async () => {
    const t = await invoke<string[]>("agmsg_teams");
    setTeams(t);
    return t;
  }, []);

  const loadMembers = useCallback(async (t: string) => {
    const m = await invoke<Member[]>("agmsg_members", { team: t });
    setMembers(m);
    return m;
  }, []);

  // The agmsg slash-command name, for the `/<cmd> actas <name>` boot prompt.
  useEffect(() => {
    invoke<string>("agmsg_command_name").then(setCmdName).catch(() => {});
  }, []);

  // Native "View > Show User Chat" menu checkbox toggles the chat/composer panel.
  useEffect(() => {
    const p = listen<boolean>("toggle-user-chat", (e) => setShowUserChat(e.payload));
    return () => void p.then((u) => u());
  }, []);

  // Spawnable agent types (for the Add-agent type picker). spawnMember
  // re-fetches this itself right before spawning — see there for why.
  useEffect(() => {
    invoke<AgentType[]>("agmsg_spawnable_types").then(setSpawnTypes).catch(() => {});
  }, []);

  // First load: teams. If there are none, the first-run flow opens New Team.
  // If agmsg isn't installed at all, install the bundled copy first (no
  // network — see agmsg_install) and retry once; only a genuine failure
  // (bad DB, install itself failing, ...) surfaces the diagnostic banner —
  // otherwise the rest of the app would just render an unexplained empty shell.
  useEffect(() => {
    async function boot() {
      try {
        const installed = await invoke<boolean>("agmsg_is_installed");
        if (!installed) {
          setInstallingAgmsg(true);
          try {
            await invoke("agmsg_install");
          } catch (err) {
            console.error(err);
            setStartupError(t("startupError.installFailed", { error: String(err) }));
            return;
          } finally {
            setInstallingAgmsg(false);
          }
        }
        try {
          const status = await invoke<{ installed: string | null; pinned: string; outdated: boolean }>(
            "agmsg_core_version_status",
          );
          if (status.outdated) setCoreOutdated({ installed: status.installed, pinned: status.pinned });
        } catch (err) {
          console.error(err);
        }
        const loadedTeams = await loadTeams();
        if (loadedTeams.length === 0) setModal({ kind: "team", firstRun: true });
        else {
          const lastTeam = localStorage.getItem(LAST_TEAM_KEY);
          const fallback = lastTeam && loadedTeams.includes(lastTeam) ? lastTeam : loadedTeams[0];
          setTeam((cur) => cur || fallback);
        }
      } catch (err) {
        console.error(err);
        setStartupError(t("startupError.loadTeamsFailed", { error: String(err) }));
      }
    }
    boot();
  }, [loadTeams, t]);

  // Tabs are per-team (see the Window type), so switching teams also swaps
  // the whole visible tab set — land on the team room rather than leaving
  // `active` pointing at a now-hidden tab from the previous team (its PTY
  // keeps running; the tab just isn't shown here). A layout effect (not a
  // regular one) so this resolves before paint — otherwise the old team's
  // pane, still technically "active" for one frame, would flash visible.
  useLayoutEffect(() => {
    if (team) setActive("room");
  }, [team]);

  // Remember the selected team across restarts (see LAST_TEAM_KEY above).
  useEffect(() => {
    if (team) localStorage.setItem(LAST_TEAM_KEY, team);
  }, [team]);

  // On team change: load members + the most recent history page. Prompt to
  // add an app-user if missing.
  useEffect(() => {
    if (!team) return;
    setDeselected(new Set()); // reset the room filter when switching teams
    setMessages([]);
    setHasMoreHistory(true);
    invoke<Message[]>("agmsg_messages", { team, limit: ROOM_PAGE_SIZE })
      .then((msgs) => {
        setMessages(msgs);
        setHasMoreHistory(msgs.length >= ROOM_PAGE_SIZE);
      })
      .catch(console.error);
    loadMembers(team)
      .then((m) => {
        if (!m.some((x) => x.types.includes(APP_USER_TYPE))) {
          setModal((cur) => cur ?? { kind: "appuser" });
        }
      })
      .catch(console.error);
  }, [team, loadMembers]);

  // Live team-room updates; inject into a matching pane.
  useEffect(() => {
    const p = listen<Message>("agmsg-message", (e) => {
      if (e.payload.team !== team) return;
      setMessages((prev) => [...prev, e.payload]);
      // Only inject into NON-native panes; a native (actas-booted) agent runs
      // its own agmsg monitor and would otherwise receive the message twice.
      const pane = panesRef.current.find((pn) => pn.label === e.payload.to && !pn.native);
      if (pane) {
        // Inject a kickoff notice, not the raw message body verbatim. The
        // real agmsg Monitor (watch.sh) never types a message's contents
        // into an agent — it hands over a structured "<from> → <to> | <body>"
        // event and lets the agent decide what to do, typically by checking
        // its own inbox. Typing the raw body instead loses who it's from
        // and — worse — feeds arbitrary user text straight into a TUI's
        // input box, where line breaks/long text/special characters can
        // break the keystroke replay (that's what caused the "types but
        // doesn't submit" bug this replaces).
        //
        // A one-line preview of the body IS included (flattened + capped) —
        // knowing at a glance what the message is about, not just that one
        // arrived, is worth the small re-introduction of body content; the
        // flattening/cap keeps it out of "arbitrary text breaks the TUI"
        // territory since it can no longer contain newlines or run long.
        const flat = e.payload.body.replace(/\s+/g, " ").trim();
        const preview = flat.length > 80 ? `${flat.slice(0, 80)}…` : flat;
        const kickoff = `[agmsg] ${e.payload.from}: "${preview}" — run /${cmdName} to check it.`;
        void invoke("pty_inject", { id: pane.id, text: kickoff });
      }
    });
    return () => void p.then((u) => u());
  }, [team, cmdName]);

  // Load-more-on-scroll-up: fetch the page older than the currently-oldest
  // loaded message and prepend it, restoring the scroll position afterward
  // (a naive prepend would otherwise yank the view down by the new content's
  // height, since scrollTop stays fixed while scrollHeight grows above it).
  const loadOlderMessages = useCallback(async () => {
    if (loadingHistory || !hasMoreHistory || messages.length === 0) return;
    setLoadingHistory(true);
    const beforeId = messages[0].id;
    const el = feedRef.current;
    const prevScrollHeight = el?.scrollHeight ?? 0;
    try {
      const older = await invoke<Message[]>("agmsg_messages", {
        team,
        limit: ROOM_PAGE_SIZE,
        beforeId,
      });
      if (older.length > 0) {
        isPrependingRef.current = true;
        setMessages((prev) => [...older, ...prev]);
        requestAnimationFrame(() => {
          if (el) el.scrollTop += el.scrollHeight - prevScrollHeight;
        });
      }
      setHasMoreHistory(older.length >= ROOM_PAGE_SIZE);
    } catch (err) {
      console.error(err);
    } finally {
      setLoadingHistory(false);
    }
  }, [team, messages, loadingHistory, hasMoreHistory]);

  // useLayoutEffect (not useEffect): runs synchronously right after the DOM
  // updates and before the browser paints, so scrollHeight already reflects
  // the just-rendered messages — avoids a visible flash of the wrong scroll
  // position (e.g. top-of-history) before jumping to the bottom.
  useLayoutEffect(() => {
    if (isPrependingRef.current) {
      isPrependingRef.current = false;
      return;
    }
    const el = feedRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages, active]);
  useEffect(() => {
    chatRef.current?.scrollTo({ top: chatRef.current.scrollHeight });
  }, [myThread.length]);

  // Remove a pane from whichever window holds it. If that empties the window,
  // drop the window too and fall back to the team room if it was active.
  const detachPane = useCallback((paneId: string) => {
    const owner = windowsRef.current.find((w) => w.paneIds.includes(paneId));
    if (!owner) return;
    const remaining = owner.paneIds.filter((id) => id !== paneId);
    setWindows((prev) =>
      prev
        .map((w) => (w.id === owner.id ? { ...w, paneIds: remaining } : w))
        .filter((w) => w.paneIds.length > 0),
    );
    if (remaining.length === 0) {
      setActive((a) => (a === owner.id ? "room" : a));
    }
  }, []);

  const spawnMember = useCallback(
    // targetWindowId: spawn straight into an existing tab as an extra
    // side-by-side pane, instead of opening a new tab (the default).
    async (m: Member, targetWindowId?: string) => {
      // Don't spawn a second pane for a member that's already running — just
      // focus its window (one live agent per identity).
      const existing = panesRef.current.find((p) => p.label === m.name);
      if (existing) {
        const w = windowsRef.current.find((win) => win.paneIds.includes(existing.id));
        if (w) setActive(w.id);
        return;
      }
      // Re-read spawnable types fresh (not the state loaded at app start) so
      // a spawn-options file created/edited after launch takes effect right
      // away instead of needing an app restart.
      const types = await invoke<AgentType[]>("agmsg_spawnable_types").catch(() => spawnTypes);
      const freshCliFor = new Map(types.map((t) => [t.name, t.cli]));
      const freshOptionsFor = new Map(types.map((t) => [t.name, t.options]));
      setSpawnTypes(types);

      const type = m.types.find((t) => freshCliFor.has(t));
      const cli = type ? freshCliFor.get(type)! : undefined;
      const options = type ? (freshOptionsFor.get(type) ?? []) : [];
      // `native` = "this (type, project) actually self-delivers agmsg
      // messages" — asked from agmsg's own delivery.sh status (mode derived
      // from the project's real hooks file), NOT a static type.conf flag.
      // A static flag can't see per-project setup or advanced opt-in paths
      // (e.g. codex's app-server bridge "monitor" mode is disabled by
      // default per type.conf but can be turned on per-project). When it's
      // NOT self-delivering, the app's PTY stdin-inject universal monitor is
      // this pane's only way to receive agmsg messages.
      let monitors = false;
      if (type && m.project) {
        try {
          const mode = await invoke<string>("agmsg_delivery_mode", { agentType: type, project: m.project });
          monitors = mode === "monitor" || mode === "both";
        } catch (err) {
          console.error(err);
        }
      }
      const id = `${m.name}-${seq.current++}`;
      // Mirror agmsg spawn.sh: launch the CLI with any per-type spawn-options
      // flags, then `/<cmd> actas <name>` as the final arg — same relative
      // order spawn.sh splices them in — so the agent comes up as the real
      // member (can send as itself, and self-delivers if its type monitors).
      // Types with no spawnable CLI fall back to a shell.
      const pane: Pane = cli
        ? {
            id,
            label: m.name,
            cmd: cli,
            args: [...options, `/${cmdName} actas ${m.name}`],
            cwd: m.project || undefined,
            native: monitors,
          }
        : { id, label: m.name, cmd: "bash", args: [], cwd: m.project || undefined, native: false };
      setPanes((prev) => [...prev, pane]);
      if (targetWindowId) {
        setWindows((prev) =>
          prev.map((w) => (w.id === targetWindowId ? { ...w, paneIds: [...w.paneIds, id] } : w)),
        );
        setActive(targetWindowId);
      } else {
        const winId = `w-${seq.current++}`;
        setWindows((prev) => [...prev, { id: winId, paneIds: [id], team, layout: "vertical" }]);
        setActive(winId);
      }
    },
    [cmdName, spawnTypes, team],
  );

  // Close one pane (from its header's × or the context menu). If it was the
  // last pane in its window, the window/tab disappears too.
  const closeWindowPane = useCallback(
    (paneId: string) => {
      void invoke("pty_kill", { id: paneId });
      setPanes((prev) => prev.filter((p) => p.id !== paneId));
      detachPane(paneId);
    },
    [detachPane],
  );

  // Close a whole tab: kill every pane it holds.
  const closeWindow = useCallback((windowId: string) => {
    const w = windowsRef.current.find((x) => x.id === windowId);
    if (!w) return;
    for (const pid of w.paneIds) void invoke("pty_kill", { id: pid });
    setPanes((prev) => prev.filter((p) => !w.paneIds.includes(p.id)));
    setWindows((prev) => prev.filter((x) => x.id !== windowId));
    setActive((a) => (a === windowId ? "room" : a));
  }, []);

  // Move a pane into another tab, adding it to that tab's side-by-side split
  // (uncapped — N panes in a tab render as N equal columns). The pane's own
  // DOM node never unmounts (see the stage render below), so this is a pure
  // reassignment — the running process and its scrollback are untouched, same
  // as a tmux pane move.
  const movePaneToWindow = useCallback(
    (paneId: string, targetWindowId: string) => {
      const target = windowsRef.current.find((w) => w.id === targetWindowId);
      if (!target || target.paneIds.includes(paneId)) return;
      detachPane(paneId);
      setWindows((prev) =>
        prev.map((w) => (w.id === targetWindowId ? { ...w, paneIds: [...w.paneIds, paneId] } : w)),
      );
      setActive(targetWindowId);
    },
    [detachPane],
  );

  // Move a pane out into its own new tab (splits it off if it was sharing a
  // window). Also just a reassignment — no respawn.
  const moveToNewWindow = useCallback(
    (paneId: string) => {
      detachPane(paneId);
      const winId = `w-${seq.current++}`;
      setWindows((prev) => [...prev, { id: winId, paneIds: [paneId], team, layout: "vertical" }]);
      setActive(winId);
    },
    [detachPane, team],
  );

  // Swap two panes' positions within the same window (paneRect derives
  // position purely from index in paneIds, so this is all a layout swap
  // needs — no DOM remount, same as every other pane move in this file).
  const swapPanesInWindow = useCallback((windowId: string, paneA: string, paneB: string) => {
    setWindows((prev) =>
      prev.map((w) => {
        if (w.id !== windowId) return w;
        const ids = [...w.paneIds];
        const i = ids.indexOf(paneA);
        const j = ids.indexOf(paneB);
        if (i === -1 || j === -1) return w;
        [ids[i], ids[j]] = [ids[j], ids[i]];
        return { ...w, paneIds: ids };
      }),
    );
  }, []);

  const setWindowLayout = useCallback((windowId: string, layout: PaneLayout) => {
    setWindows((prev) => prev.map((w) => (w.id === windowId ? { ...w, layout } : w)));
  }, []);

  // A tab's label: the user's custom name if set, else its panes' names joined.
  const windowLabel = useCallback(
    (w: Window) =>
      w.customLabel ??
      w.paneIds
        .map((pid) => panes.find((p) => p.id === pid)?.label)
        .filter(Boolean)
        .join(" · "),
    [panes],
  );

  // Tabs are scoped to the current team (see the Window type) — other
  // teams' windows stay mounted with their PTYs alive, just not listed
  // here or offered as spawn/move targets.
  const teamWindows = useMemo(() => windows.filter((w) => w.team === team), [windows, team]);

  const startRenameWindow = useCallback(
    (windowId: string) => {
      const w = windowsRef.current.find((x) => x.id === windowId);
      if (!w) return;
      setRenameDraft(windowLabel(w));
      setRenamingWindowId(windowId);
    },
    [windowLabel],
  );

  const commitRenameWindow = useCallback((windowId: string) => {
    setWindows((prev) => {
      const trimmed = renameDraftRef.current.trim();
      return prev.map((w) => (w.id === windowId ? { ...w, customLabel: trimmed || undefined } : w));
    });
    setRenamingWindowId(null);
  }, []);

  const send = useCallback(async () => {
    if (!draft.trim() || !target || !appUser) return;
    try {
      await invoke("agmsg_send", { team, from: appUser, to: target, body: draft });
      setDraft("");
    } catch (err) {
      alert(t("composer.sendFailedAlert", { error: String(err) }));
    }
  }, [draft, target, team, appUser, t]);

  // --- modal handlers (all writes go through agmsg scripts via the backend) ---

  const onCreateTeam = useCallback(
    async (name: string, appUserName: string, project: string) => {
      // A single join.sh creates the team (if new) AND adds the app-user — no
      // empty-team intermediate, no extra agmsg script.
      await invoke("agmsg_join", {
        team: name,
        name: appUserName,
        agentType: APP_USER_TYPE,
        project,
      });
      await loadTeams();
      setTeam(name);
      setModal(null);
    },
    [loadTeams],
  );

  const onAddAppUser = useCallback(
    async (name: string, project: string) => {
      await invoke("agmsg_join", { team, name, agentType: APP_USER_TYPE, project });
      await loadMembers(team);
      setModal(null);
    },
    [team, loadMembers],
  );

  const onAddAgent = useCallback(
    async (name: string, type: string, project: string) => {
      await invoke("agmsg_join", { team, name, agentType: type, project });
      const m = await loadMembers(team);
      const added = m.find((x) => x.name === name);
      if (added) spawnMember(added);
      setModal(null);
    },
    [team, loadMembers, spawnMember],
  );

  const onRename = useCallback(
    async (current: string, next: string) => {
      await invoke("agmsg_rename", { team, oldName: current, newName: next });
      await loadMembers(team);
      setModal(null);
    },
    [team, loadMembers],
  );

  const onLeave = useCallback(
    async (name: string) => {
      const pane = panesRef.current.find((p) => p.label === name);
      if (pane) {
        await invoke("pty_kill", { id: pane.id });
        setPanes((prev) => prev.filter((p) => p.id !== pane.id));
        detachPane(pane.id);
      }
      await invoke("agmsg_leave", { team, name });
      await loadMembers(team);
    },
    [team, loadMembers, detachPane],
  );

  const browseDir = useCallback(async (current: string): Promise<string | null> => {
    const picked = await openDialog({ directory: true, defaultPath: current || undefined });
    return typeof picked === "string" ? picked : null;
  }, []);

  // Draggable dividers: track the drag on document so it continues over the
  // terminal canvas, and clamp so a pane can't be dragged away entirely.
  const startSidebarDrag = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      const startX = e.clientX;
      const startW = sidebarWidth;
      const onMove = (ev: MouseEvent) =>
        setSidebarWidth(Math.max(140, Math.min(520, startW + ev.clientX - startX)));
      const onUp = () => {
        document.removeEventListener("mousemove", onMove);
        document.removeEventListener("mouseup", onUp);
        document.body.classList.remove("resizing-col");
      };
      document.addEventListener("mousemove", onMove);
      document.addEventListener("mouseup", onUp);
      // Force the resize cursor everywhere for the whole drag, so it doesn't
      // flip back to the terminal's text cursor as the pointer passes over it.
      document.body.classList.add("resizing-col");
    },
    [sidebarWidth],
  );

  const startChatDrag = useCallback(
    (e: React.MouseEvent) => {
      e.preventDefault();
      const startY = e.clientY;
      const startH = chatHeight;
      const onMove = (ev: MouseEvent) =>
        setChatHeight(Math.max(72, Math.min(560, startH + startY - ev.clientY)));
      const onUp = () => {
        document.removeEventListener("mousemove", onMove);
        document.removeEventListener("mouseup", onUp);
        document.body.classList.remove("resizing-row");
      };
      document.addEventListener("mousemove", onMove);
      document.addEventListener("mouseup", onUp);
      document.body.classList.add("resizing-row");
    },
    [chatHeight],
  );

  return (
    <div
      className="app"
      onClick={() => {
        setNewMenu(false);
        setMemberMenu(null);
        setPaneMenu(null);
        setWindowMenu(null);
      }}
      onDragOverCapture={(e) => {
        // WebKit doesn't reliably show a "no-drop" cursor just from
        // dropEffect = "none" — it only trusts that value once something in
        // the chain has preventDefault()'d, otherwise it falls back to a
        // generic "copy" (+) cursor. So every dragover gets preventDefault()
        // + dropEffect = "none" here first, in the capture phase (root ->
        // target, runs before any target's own bubble-phase onDragOver
        // below) — a real drop target's handler still runs after and
        // overrides dropEffect back to "move". Since nothing here reads
        // getData or acts on drop, an invalid area silently accepting the
        // preventDefault is harmless: releasing there fires a drop event
        // with no handler attached, i.e. still a no-op.
        if (e.dataTransfer.types.includes(PANE_DRAG_MIME)) {
          e.preventDefault();
          e.dataTransfer.dropEffect = "none";
        }
      }}
    >
      {installingAgmsg && (
        <div className="startup-installing-banner">
          <span>{t("startupError.installing")}</span>
        </div>
      )}
      {coreOutdated && !updatingCore && (
        <div className="startup-outdated-banner">
          <span>
            {t("startupError.coreOutdated", {
              installed: coreOutdated.installed ?? t("startupError.versionUnknown"),
              pinned: coreOutdated.pinned,
            })}
          </span>
          <button
            onClick={async () => {
              const targetVersion = coreOutdated.pinned;
              setUpdatingCore(true);
              try {
                await invoke("agmsg_update_core");
                setCoreOutdated(null);
                setCoreUpdateSucceeded(targetVersion);
                await loadTeams();
              } catch (err) {
                console.error(err);
                setStartupError(t("startupError.updateFailed", { error: String(err) }));
              } finally {
                setUpdatingCore(false);
              }
            }}
          >
            {t("startupError.updateNow")}
          </button>
        </div>
      )}
      {updatingCore && (
        <div className="startup-installing-banner">
          <span>{t("startupError.updating")}</span>
        </div>
      )}
      {coreUpdateSucceeded && (
        <div className="startup-success-banner">
          <span>{t("startupError.updateSucceeded", { version: coreUpdateSucceeded })}</span>
          <button onClick={() => setCoreUpdateSucceeded(null)}>{t("startupError.dismiss")}</button>
        </div>
      )}
      {startupError && (
        <div className="startup-error-banner">
          <span>{startupError}</span>
          <button onClick={() => setStartupError(null)}>{t("startupError.dismiss")}</button>
        </div>
      )}
      <div className="body">
        <aside className="sidebar" style={{ width: sidebarWidth }}>
          <div className="sidebar-head" data-tauri-drag-region>
            <div className="brand-row">
              <img className="logo" src="/agmsg-logo.png" alt={t("sidebar.logoAlt")} />
              <div className="new-wrap" onClick={(e) => e.stopPropagation()}>
              <button className="new-btn" onClick={() => setNewMenu((v) => !v)}>
                {t("sidebar.newMenu.trigger")}
              </button>
              {newMenu && (
                <div className="new-menu">
                  <button
                    onClick={() => {
                      setNewMenu(false);
                      setModal({ kind: "team", firstRun: false });
                    }}
                  >
                    {t("sidebar.newMenu.team")}
                  </button>
                  <button
                    disabled={!team}
                    onClick={() => {
                      setNewMenu(false);
                      setModal({ kind: "agent" });
                      // Refresh in case spawn-options.yaml or a new type
                      // manifest showed up since app start.
                      invoke<AgentType[]>("agmsg_spawnable_types")
                        .then(setSpawnTypes)
                        .catch(() => {});
                    }}
                  >
                    {t("sidebar.newMenu.agent")}
                  </button>
                </div>
              )}
              </div>
            </div>
            <select value={team} onChange={(e) => setTeam(e.target.value)}>
              {teams.map((teamName) => (
                <option key={teamName} value={teamName}>
                  {teamName}
                </option>
              ))}
            </select>
          </div>
          <div className="sidebar-title">
            <span>{t("sidebar.title")}</span>
            {active === "room" && others.length > 0 && (
              <span className="filter-actions">
                <button onClick={selectAllMembers}>{t("sidebar.filter.all")}</button>
                <span>·</span>
                <button onClick={selectNoMembers}>{t("sidebar.filter.none")}</button>
              </span>
            )}
          </div>
          <ul className="members">
            {others.map((m) => (
              <li
                key={m.name}
                className="member-row"
                onContextMenu={(e) => {
                  e.preventDefault();
                  e.stopPropagation();
                  setMemberMenu({ member: m, x: e.clientX, y: e.clientY });
                }}
              >
                {active === "room" && (
                  <input
                    type="checkbox"
                    className="member-check"
                    title={t("sidebar.member.checkboxTitle")}
                    checked={!deselected.has(m.name)}
                    onChange={() => toggleMember(m.name)}
                    onClick={(e) => e.stopPropagation()}
                  />
                )}
                <button
                  className="member"
                  onClick={() => spawnMember(m)}
                  title={
                    panes.some((p) => p.label === m.name)
                      ? t("sidebar.member.titleRunning")
                      : t("sidebar.member.titleSpawn")
                  }
                >
                  <span className="member-name">
                    {m.name}
                    {panes.some((p) => p.label === m.name) && <span className="running-dot" />}
                  </span>
                  <span className="member-types">
                    {m.types.join(", ") || t("sidebar.member.noTypes")}
                  </span>
                </button>
              </li>
            ))}
            {others.length === 0 && (
              <li className="empty">{t("sidebar.member.emptyState")}</li>
            )}
          </ul>
          {appUser && (
            <div className="sidebar-user" title={t("sidebar.user.title", { team })}>
              <span className="avatar" />
              <div className="su-meta">
                <span className="su-name">{appUser}</span>
                <span className="su-team">{team}</span>
              </div>
              <button
                className="settings-btn"
                title={t("settings.title")}
                onClick={(e) => {
                  e.stopPropagation();
                  setModal({ kind: "settings" });
                }}
              >
                ⚙
              </button>
            </div>
          )}
        </aside>

        <div className="divider-v" onMouseDown={startSidebarDrag} />

        <main className="main">
          <nav className="tabs" data-tauri-drag-region>
            <span className={active === "room" ? "tab active" : "tab"}>
              <button className="tab-label" onClick={() => setActive("room")}>
                {t("tabs.roomLabel")}
              </button>
            </span>
            {teamWindows.map((w) => (
              <span
                key={w.id}
                className={[
                  active === w.id ? "tab active" : "tab",
                  dragOverWindowId === w.id && "drop-target",
                ]
                  .filter(Boolean)
                  .join(" ")}
                onContextMenu={(e) => {
                  e.preventDefault();
                  e.stopPropagation();
                  setWindowMenu({ windowId: w.id, x: e.clientX, y: e.clientY });
                }}
                onDragOver={(e) => {
                  if (!e.dataTransfer.types.includes(PANE_DRAG_MIME)) return;
                  e.preventDefault();
                  e.dataTransfer.dropEffect = "move";
                  setDragOverWindowId((cur) => (cur === w.id ? cur : w.id));
                }}
                onDragLeave={(e) => {
                  if (!e.currentTarget.contains(e.relatedTarget as Node)) {
                    setDragOverWindowId((cur) => (cur === w.id ? null : cur));
                  }
                }}
                onDrop={(e) => {
                  e.preventDefault();
                  setDragOverWindowId(null);
                  setSwapSource(null);
                  const sourceId = e.dataTransfer.getData(PANE_DRAG_MIME);
                  if (sourceId) movePaneToWindow(sourceId, w.id);
                }}
              >
                {renamingWindowId === w.id ? (
                  <input
                    className="tab-rename-input"
                    autoFocus
                    value={renameDraft}
                    onChange={(e) => setRenameDraft(e.target.value)}
                    onBlur={() => commitRenameWindow(w.id)}
                    onKeyDown={(e) => {
                      if (isSubmitEnter(e)) commitRenameWindow(w.id);
                      if (e.key === "Escape") setRenamingWindowId(null);
                    }}
                    {...imeCompositionProps}
                    onClick={(e) => e.stopPropagation()}
                  />
                ) : (
                  <button className="tab-label" onClick={() => setActive(w.id)}>
                    ▸ {windowLabel(w)}
                  </button>
                )}
                <button
                  className="tab-close"
                  onClick={(e) => {
                    e.stopPropagation();
                    setModal({ kind: "closeWindow", windowId: w.id });
                  }}
                >
                  ×
                </button>
              </span>
            ))}
            {/* Tabs are all clickable buttons, so they eat the drag region
                the <nav> itself claims — this dedicated strip is always
                empty and always draggable, regardless of tab count. */}
            <div
              className={dragOverNewTab ? "tabs-drag-spacer drop-target" : "tabs-drag-spacer"}
              data-tauri-drag-region
              onDragOver={(e) => {
                if (!e.dataTransfer.types.includes(PANE_DRAG_MIME)) return;
                e.preventDefault();
                e.dataTransfer.dropEffect = "move";
                setDragOverNewTab(true);
              }}
              onDragLeave={(e) => {
                if (!e.currentTarget.contains(e.relatedTarget as Node)) {
                  setDragOverNewTab(false);
                }
              }}
              onDrop={(e) => {
                e.preventDefault();
                setDragOverNewTab(false);
                setSwapSource(null);
                const sourceId = e.dataTransfer.getData(PANE_DRAG_MIME);
                if (sourceId) moveToNewWindow(sourceId);
              }}
            />
          </nav>

          <section className="stage">
            <div
              className="room"
              hidden={active !== "room"}
              ref={feedRef}
              onScroll={(e) => {
                if (e.currentTarget.scrollTop < 60) void loadOlderMessages();
              }}
            >
              {loadingHistory && <div className="room-loading">{t("room.loadingMore")}</div>}
              {groups.map((g) => (
                <div className="grp" key={g.key}>
                  <div className="grp-head">
                    <b className="mf">{g.from}</b>
                    <span className="arrow">→</span>
                    <b className="mt">{g.to}</b>
                    <span className="grp-time">{g.items[0].created_at.slice(11, 19)}</span>
                  </div>
                  {g.items.map((m) => (
                    <div className="grp-body" key={m.id}>
                      {m.body}
                    </div>
                  ))}
                </div>
              ))}
              {messages.length === 0 && <div className="empty">{t("room.emptyState")}</div>}
            </div>

            {/* Every pane is a permanent, flat child of .stage — its window only
                decides WHERE it's positioned (paneRect, from its layout),
                never whether it's mounted. That keeps each pane's DOM node
                (and TerminalPane's xterm + PTY listeners) alive across a
                Move-to or a layout change, so the running process and its
                scrollback survive — the same pane split tmux gives you, not
                a respawn. Inactive-window panes go visibility:hidden but
                stay laid out, so a resize doesn't leave them stale for next
                time. */}
            {panes.map((p) => {
              const win = windows.find((w) => w.paneIds.includes(p.id));
              if (!win) return null;
              const idx = win.paneIds.indexOf(p.id);
              const count = win.paneIds.length;
              const rect = paneRect(win.layout, idx, count);
              const isActiveWindow = active === win.id;
              const isDropTarget = dragOverPaneId === p.id && swapSource !== p.id;
              return (
                <div
                  key={p.id}
                  className={[
                    isActiveWindow ? "pane-cell" : "pane-cell inactive",
                    isDropTarget && "drop-target",
                  ]
                    .filter(Boolean)
                    .join(" ")}
                  style={{
                    left: `${rect.left}%`,
                    top: `${rect.top}%`,
                    width: `${rect.width}%`,
                    height: `${rect.height}%`,
                  }}
                  onDragOver={(e) => {
                    // Gate on dataTransfer.types, NOT React state: dragover
                    // fires on whatever element is under the cursor, whose
                    // closures were made at ITS OWN last render — swapSource
                    // there can be one render behind the dragstart that just
                    // set it elsewhere. types is native DataTransfer state,
                    // always current regardless of React's render timing.
                    // (getData() itself isn't readable until the drop event —
                    // that's a browser security restriction — types is.)
                    if (!e.dataTransfer.types.includes(PANE_DRAG_MIME)) return;
                    e.preventDefault(); // required to allow dropping
                    e.dataTransfer.dropEffect = "move";
                    setDragOverPaneId((cur) => (cur === p.id ? cur : p.id));
                  }}
                  onDragLeave={(e) => {
                    // Only clear if we're leaving this cell for something
                    // outside it — a child element's dragleave (e.g. moving
                    // from the header onto the terminal below) shouldn't
                    // flicker the highlight off.
                    if (!e.currentTarget.contains(e.relatedTarget as Node)) {
                      setDragOverPaneId((cur) => (cur === p.id ? null : cur));
                    }
                  }}
                  onDrop={(e) => {
                    e.preventDefault();
                    setDragOverPaneId(null);
                    setSwapSource(null);
                    const sourceId = e.dataTransfer.getData(PANE_DRAG_MIME);
                    if (sourceId && win.paneIds.includes(sourceId) && sourceId !== p.id) {
                      swapPanesInWindow(win.id, sourceId, p.id);
                    }
                  }}
                >
                  <div
                    className="pane-header"
                    onContextMenu={(e) => {
                      e.preventDefault();
                      e.stopPropagation();
                      setPaneMenu({ paneId: p.id, windowId: win.id, x: e.clientX, y: e.clientY });
                    }}
                  >
                    <button
                      className={
                        swapSource === p.id ? "pane-header-label swap-armed" : "pane-header-label"
                      }
                      title={t("pane.swapTitle")}
                      draggable
                      onDragStart={(e) => {
                        e.dataTransfer.effectAllowed = "move";
                        // A custom MIME type, not text/plain — so dragover
                        // elsewhere in the page (or a stray OS file drag)
                        // never matches PANE_DRAG_MIME and gets treated as
                        // a valid drop target by accident.
                        e.dataTransfer.setData(PANE_DRAG_MIME, p.id);
                        // The label's own box is flex-stretched to fill the
                        // header, so the browser's default drag snapshot
                        // would be the whole bar's width. Swap in a ghost
                        // sized to the text instead, then discard it —
                        // setDragImage snapshots synchronously here.
                        const ghost = document.createElement("div");
                        ghost.textContent = p.label;
                        ghost.className = "pane-drag-ghost";
                        document.body.appendChild(ghost);
                        e.dataTransfer.setDragImage(ghost, 10, 10);
                        setTimeout(() => ghost.remove(), 0);
                        setSwapSource(p.id);
                      }}
                      onDragEnd={() => {
                        setSwapSource(null);
                        setDragOverPaneId(null);
                        setDragOverWindowId(null);
                        setDragOverNewTab(false);
                      }}
                      onClick={(e) => {
                        e.stopPropagation();
                        if (swapSource === p.id) {
                          setSwapSource(null);
                        } else if (swapSource && win.paneIds.includes(swapSource)) {
                          swapPanesInWindow(win.id, swapSource, p.id);
                          setSwapSource(null);
                        } else {
                          setSwapSource(p.id);
                        }
                      }}
                    >
                      {p.label}
                    </button>
                    <span className={p.native ? "monitor-dot native" : "monitor-dot app"}>
                      <span className="monitor-tip">
                        {p.native
                          ? t("pane.monitorTip.native")
                          : t("pane.monitorTip.app")}
                      </span>
                    </span>
                    <button
                      className="pane-header-close"
                      onClick={() => setModal({ kind: "closePane", paneId: p.id })}
                      title={t("pane.closeTitle")}
                    >
                      ×
                    </button>
                  </div>
                  <TerminalPane id={p.id} cmd={p.cmd} args={p.args} cwd={p.cwd} />
                </div>
              );
            })}
          </section>

          {showUserChat && <div className="divider-h" onMouseDown={startChatDrag} />}

          {/* App-user chat: the human's own send/receive thread + composer.
              Hidden via View > Show User Chat (native menu checkbox). Clicking
              the history jumps focus to the composer input below — the
              history itself has nothing to focus (nothing to type into), so
              without this the border-on-focus feedback here was invisible in
              normal use. */}
          <div
            className="appuser-chat"
            ref={chatRef}
            style={{ height: chatHeight }}
            hidden={!showUserChat}
            onClick={() => composerInputRef.current?.focus()}
          >
            {myThread.map((m) => (
              <div className={m.from === appUser ? "chat-line out" : "chat-line in"} key={m.id}>
                <span className="chat-time">{m.created_at.slice(11, 19)}</span>
                <span className="chat-peer">
                  {m.from === appUser
                    ? t("chat.peer.to", { to: m.to })
                    : t("chat.peer.from", { from: m.from })}
                </span>
                <span className="chat-body">{m.body}</span>
              </div>
            ))}
            {appUser && myThread.length === 0 && (
              <div className="empty">{t("chat.emptyState.withUser", { appUser })}</div>
            )}
            {!appUser && team && (
              <div className="empty">
                {t("chat.emptyState.noUser")}
                <button className="link" onClick={() => setModal({ kind: "appuser" })}>
                  {t("chat.emptyState.addOne")}
                </button>
              </div>
            )}
          </div>

          <footer className="composer" hidden={!showUserChat}>
            {appUser ? (
              <>
                <span className="as">
                  {t("composer.asPrefix")} <b>{appUser}</b>
                </span>
                <select value={target} onChange={(e) => setTarget(e.target.value)}>
                  <option value="">{t("composer.targetPlaceholder")}</option>
                  {others.map((m) => (
                    <option key={m.name} value={m.name}>
                      {m.name}
                    </option>
                  ))}
                </select>
                <input
                  ref={composerInputRef}
                  value={draft}
                  placeholder={t("composer.messagePlaceholder")}
                  onChange={(e) => setDraft(e.target.value)}
                  onKeyDown={(e) => isSubmitEnter(e) && send()}
                  {...imeCompositionProps}
                />
                <button onClick={send} disabled={!draft.trim() || !target}>
                  {t("composer.sendButton")}
                </button>
              </>
            ) : (
              <span className="as">{t("composer.noAppUser")}</span>
            )}
          </footer>
        </main>
      </div>

      {modal?.kind === "team" && (
        <NewTeamModal
          firstRun={modal.firstRun}
          onCreate={onCreateTeam}
          onClose={modal.firstRun ? undefined : () => setModal(null)}
          browseDir={browseDir}
        />
      )}
      {modal?.kind === "appuser" && (
        <AppUserModal onAdd={onAddAppUser} onClose={() => setModal(null)} browseDir={browseDir} />
      )}
      {modal?.kind === "agent" && (
        <AgentModal
          onAdd={onAddAgent}
          onClose={() => setModal(null)}
          browseDir={browseDir}
          defaultProject={teamProject}
          types={spawnTypes.map((t) => t.name)}
        />
      )}
      {modal?.kind === "rename" && (
        <RenameModal current={modal.current} onRename={onRename} onClose={() => setModal(null)} />
      )}
      {modal?.kind === "leave" && (
        <ConfirmModal
          title={t("modal.leave.title", { name: modal.name })}
          body={t("modal.leave.body", { name: modal.name, team })}
          confirmLabel={t("modal.leave.confirmLabel")}
          danger
          onConfirm={() => onLeave(modal.name)}
          onClose={() => setModal(null)}
        />
      )}
      {modal?.kind === "settings" && <SettingsModal onClose={() => setModal(null)} />}
      {modal?.kind === "closeWindow" &&
        (() => {
          const win = windows.find((w) => w.id === modal.windowId);
          if (!win) return null;
          const names = win.paneIds
            .map((pid) => panes.find((p) => p.id === pid)?.label)
            .filter((n): n is string => Boolean(n));
          return (
            <ConfirmModal
              title={t("modal.closeWindow.title")}
              body={t("modal.closeWindow.body", { names: names.join(", ") })}
              confirmLabel={t("modal.closeWindow.confirmLabel")}
              danger
              onConfirm={() => closeWindow(modal.windowId)}
              onClose={() => setModal(null)}
            />
          );
        })()}
      {modal?.kind === "closePane" &&
        (() => {
          const pane = panes.find((p) => p.id === modal.paneId);
          if (!pane) return null;
          return (
            <ConfirmModal
              title={t("modal.closePane.title", { name: pane.label })}
              body={t("modal.closePane.body", { name: pane.label })}
              confirmLabel={t("modal.closePane.confirmLabel")}
              danger
              onConfirm={() => closeWindowPane(modal.paneId)}
              onClose={() => setModal(null)}
            />
          );
        })()}

      {memberMenu &&
        (() => {
          // One live agent per identity — same rule spawnMember/the running-dot
          // indicator already enforce. A running member can't be spawned again,
          // so don't offer a "Spawn to…" that would silently just focus it.
          const isRunning = panes.some((p) => p.label === memberMenu.member.name);
          return (
            <div
              className="ctx-menu"
              style={{ left: memberMenu.x, top: memberMenu.y }}
              onClick={(e) => e.stopPropagation()}
            >
              {!isRunning && (
                <div className="submenu-trigger">
                  <span className="submenu-label">{t("ctxMenu.member.spawnTo")}</span>
                  <div className="submenu">
                    <button
                      onClick={() => {
                        spawnMember(memberMenu.member);
                        setMemberMenu(null);
                      }}
                    >
                      {t("ctxMenu.member.spawnNewTab")}
                    </button>
                    {teamWindows.length > 0 && (
                      <span className="submenu-empty">{t("ctxMenu.member.existingTabsDivider")}</span>
                    )}
                    {teamWindows.map((w) => (
                      <button
                        key={w.id}
                        onClick={() => {
                          spawnMember(memberMenu.member, w.id);
                          setMemberMenu(null);
                        }}
                      >
                        {windowLabel(w)}
                      </button>
                    ))}
                  </div>
                </div>
              )}
              <button
                onClick={() => {
                  setModal({ kind: "rename", current: memberMenu.member.name });
                  setMemberMenu(null);
                }}
              >
                {t("ctxMenu.member.rename")}
              </button>
              <button
                className="danger"
                onClick={() => {
                  setModal({ kind: "leave", name: memberMenu.member.name });
                  setMemberMenu(null);
                }}
              >
                {t("ctxMenu.member.leave")}
              </button>
            </div>
          );
        })()}

      {paneMenu &&
        (() => {
          const sourceWindow = windows.find((w) => w.id === paneMenu.windowId);
          // Move targets are limited to the source pane's own team — moving
          // it into another team's tab set would mix a pane into a team it
          // can't actually message, the same confusion this whole change
          // is meant to avoid.
          const otherWindows = windows.filter(
            (w) => w.id !== paneMenu.windowId && w.team === sourceWindow?.team,
          );
          // Only offer "split off into a new tab" when this pane is currently
          // sharing its window — if it's already alone, a new tab would be a no-op.
          const canSplitOff = (sourceWindow?.paneIds.length ?? 1) > 1;
          // Sibling panes in the same tab — the same swap the header's
          // click/drag already does, exposed here too for symmetry with
          // "Move to ▸".
          const siblingPanes = (sourceWindow?.paneIds ?? [])
            .filter((pid) => pid !== paneMenu.paneId)
            .map((pid) => panes.find((p) => p.id === pid))
            .filter((p): p is Pane => p != null);
          return (
            <div
              className="ctx-menu"
              style={{ left: paneMenu.x, top: paneMenu.y }}
              onClick={(e) => e.stopPropagation()}
            >
              <button
                onClick={() => {
                  setModal({ kind: "closePane", paneId: paneMenu.paneId });
                  setPaneMenu(null);
                }}
              >
                {t("ctxMenu.pane.close")}
              </button>
              <div className="submenu-trigger">
                <span className="submenu-label">{t("ctxMenu.pane.moveTo")}</span>
                <div className="submenu">
                  {canSplitOff && (
                    <button
                      onClick={() => {
                        moveToNewWindow(paneMenu.paneId);
                        setPaneMenu(null);
                      }}
                    >
                      {t("ctxMenu.pane.moveNewTab")}
                    </button>
                  )}
                  {otherWindows.length === 0 && !canSplitOff && (
                    <span className="submenu-empty">{t("ctxMenu.pane.noOtherTabs")}</span>
                  )}
                  {otherWindows.map((w) => {
                    const label = windowLabel(w);
                    return (
                      <button
                        key={w.id}
                        onClick={() => {
                          movePaneToWindow(paneMenu.paneId, w.id);
                          setPaneMenu(null);
                        }}
                      >
                        {label}
                      </button>
                    );
                  })}
                </div>
              </div>
              <div className="submenu-trigger">
                <span className="submenu-label">{t("ctxMenu.pane.swapWith")}</span>
                <div className="submenu">
                  {siblingPanes.length === 0 && (
                    <span className="submenu-empty">{t("ctxMenu.pane.noOtherPanes")}</span>
                  )}
                  {siblingPanes.map((p) => (
                    <button
                      key={p.id}
                      onClick={() => {
                        swapPanesInWindow(paneMenu.windowId, paneMenu.paneId, p.id);
                        setPaneMenu(null);
                      }}
                    >
                      {p.label}
                    </button>
                  ))}
                </div>
              </div>
            </div>
          );
        })()}

      {windowMenu &&
        (() => {
          const win = windows.find((w) => w.id === windowMenu.windowId);
          const layouts: PaneLayout[] = ["vertical", "horizontal", "tile"];
          return (
            <div
              className="ctx-menu"
              style={{ left: windowMenu.x, top: windowMenu.y }}
              onClick={(e) => e.stopPropagation()}
            >
              <button
                onClick={() => {
                  startRenameWindow(windowMenu.windowId);
                  setWindowMenu(null);
                }}
              >
                {t("ctxMenu.window.rename")}
              </button>
              <div className="submenu-trigger">
                <span className="submenu-label">{t("ctxMenu.window.layout")}</span>
                <div className="submenu">
                  {layouts.map((l) => (
                    <button
                      key={l}
                      className={win?.layout === l ? "active" : undefined}
                      onClick={() => {
                        setWindowLayout(windowMenu.windowId, l);
                        setWindowMenu(null);
                      }}
                    >
                      {t(`ctxMenu.window.layout${l.charAt(0).toUpperCase()}${l.slice(1)}`)}
                    </button>
                  ))}
                </div>
              </div>
            </div>
          );
        })()}
    </div>
  );
}
