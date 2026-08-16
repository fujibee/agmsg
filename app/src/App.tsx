import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import {
  Maximize2,
  Minimize2,
  Minus,
  PanelLeftClose,
  Plus,
  RectangleHorizontal,
  Settings,
  Users,
} from "lucide-react";
import { TerminalPane } from "./TerminalPane";
import { aggregateTeamStatus, applyStateChange, type PaneStatusMap, type RawState } from "./agentStatus";
import { AUTO_TIMEZONE, formatMessageTime, isValidTimeZone, resolveTimeZone } from "./time";
import {
  AgentModal,
  AppUserModal,
  ConfirmModal,
  MAX_TERMINAL_FONT_SIZE,
  MIN_TERMINAL_FONT_SIZE,
  NewTeamModal,
  RenameModal,
  SettingsModal,
} from "./modals";
import {
  applyAtPath,
  classifyDrop,
  clampRatio,
  collectDividers,
  computeRects,
  dividerDragKey,
  insertAsNewLeaf,
  insertBeside,
  leaves,
  presetTree,
  renameLeaf,
  sameZone,
  spliceOutLeaf,
  swapLeaves,
  transposeGrid,
  updateRatioAtPath,
  type DividerInfo,
  type DropSide,
  type PaneRect,
  type SplitNode,
} from "./paneTree";
import { PulseDot } from "./pulseSync";
import { resolveActiveTab } from "./tabMemory";
import "./App.css";

export type Member = { name: string; types: string[]; project: string };
type Message = {
  // Opaque. api.sh's contract: "Every id (message ids included) is a JSON
  // string, never a bare number." Event-log ids are UUIDs; only the legacy
  // table's were integers. Used as a React key and as the paging cursor,
  // neither of which needs it to be ordered or numeric.
  id: string;
  team: string;
  from: string;
  to: string;
  body: string;
  created_at: string;
};
export type Pane = {
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
  /** A free login shell (the "+" tab, or a tab's "Open shell" context menu
   *  item) — unattached to any agent. Drives the sidebar-click "spawn beside
   *  the shell instead of a new tab" behavior below: it has to be an
   *  explicit flag rather than inferred from `cmd`, since `cmd` is
   *  whatever login_shell resolved (zsh/bash/fish/...), not a fixed string. */
  shell?: boolean;
};
// A tab. Holds one or more panes, arranged as a binary split tree (see
// paneTree.ts) — draggable dividers and directional split/swap drag-drop
// (issue #317) both need real nested structure, which a flat list + layout
// enum couldn't represent (see the design doc on that issue for why).
export type Window = {
  id: string;
  root: SplitNode;
  /** User-set tab name (Rename); falls back to the joined pane labels. */
  customLabel?: string;
  /** The team this tab was spawned under. Agents can't message across
   *  teams, so a window's tab set is scoped to one team — showing another
   *  team's tabs alongside it would imply cross-team messaging works when
   *  it doesn't. Windows for other teams stay mounted (PTYs alive) but
   *  hidden until that team is selected again. */
  team: string;
};
// The three canonical arrangements offered from the right-click Layout
// submenu and the native View > Pane Layout menu. Picking one is a one-shot
// RESET (presetTree in paneTree.ts) — it discards whatever manual divider
// drags or split-drops produced and rebuilds a fresh tree matching the
// preset; it is NOT a persisted mode the window stays locked into.
type PaneLayout = "vertical" | "horizontal" | "tile";
// What Rust's login_shell resolved (see lib.rs) — the user's actual login
// shell binary plus the flags to make it behave like one (source profile,
// interactive prompt), for the free-shell "+" tab. `home` is the $HOME
// fallback used when the current team has no project dir configured.
export type LoginShellInfo = { cmd: string; args: string[]; home: string };

// Builds a free-shell Pane from Rust's resolved login shell — or null if
// it hasn't resolved (yet, or ever). Deliberately has NO "bash" guess-
// fallback: an earlier version defaulted to bash when `info` was still
// unresolved, which raced the mount-effect fetch (app just launched, user
// immediately hits "+") — broken on Windows (no bash), and not the user's
// actual login shell even on unix (review, PR #431). Pure so the
// no-fallback contract is unit-testable without mounting the app.
export function shellPaneFrom(info: LoginShellInfo | null, id: string, label: string, cwd: string | undefined): Pane | null {
  if (!info) return null;
  return { id, label, cmd: info.cmd, args: info.args, cwd, native: false, shell: true };
}

// Whether openShellTab's new window should still be committed after its
// getLoginShell await — false if the user switched teams while it was in
// flight. Committing anyway would silently add a window under the stale
// team (hidden — only the current team's windows render) while `active`
// pointed at it (#431).
export function shellTabStillValid(currentTeam: string, requestedTeam: string): boolean {
  return currentTeam === requestedTeam;
}

// Whether openShellInWindow's target tab is still a valid split target
// after its getLoginShell await — false if the user closed it (no window
// references it, and `active` would point at a nonexistent id), OR just
// switched teams while it was in flight: the target window can still exist
// but now belong to the team the user navigated away from, in which case
// splitting into it and setting `active` there produces the same
// hidden-active bug openShellTab's shellTabStillValid guards against — a
// window's `team` never changes after creation, so if the current team no
// longer matches `requestedTeam` the window can't be a live tab regardless
// of whether it's still present in `windows` (#431).
export function shellSplitStillValid(
  windows: ReadonlyArray<Pick<Window, "id" | "team">>,
  windowId: string,
  currentTeam: string,
  requestedTeam: string,
): boolean {
  if (currentTeam !== requestedTeam) return false;
  return windows.some((w) => w.id === windowId && w.team === requestedTeam);
}

// C0 control characters (\u0000-\u001f) and DEL (\u007f) — legal in a
// macOS/Linux filename, but this string is about to be written straight
// into a PTY as literal input. A newline in a filename would submit
// whatever's currently on the target prompt the instant the file is
// dropped; ESC-prefixed bytes are terminal control sequences, not text.
// The whole drop is rejected rather than stripping the offending bytes:
// stripping would silently turn the dropped path into a DIFFERENT, wrong
// path instead of the one actually dropped (review, PR #481).
const DROP_PATH_CONTROL_CHAR_RE = /[\u0000-\u001f\u007f]/;

export function hasUnsafeDropPath(paths: string[]): boolean {
  return paths.some((p) => DROP_PATH_CONTROL_CHAR_RE.test(p));
}

// Multiple dropped files become one space-separated line of bare paths, or
// null if any of them fails the control-character check above (the whole
// drop is rejected, not just the unsafe path — see its doc). Deliberately
// NOT shell-quoted: the target of a drop is almost always an agent CLI's
// own prompt line (the framing — "same as cc/codex"), not a literal
// shell command, and quoting broke path recognition there in live testing
// — Claude Code's own file-path heuristic doesn't match a quote-wrapped
// string, it just reads as plain text (Codex tolerated quotes fine, but
// the common case has to work for both).
export function joinDroppedPaths(paths: string[]): string | null {
  if (hasUnsafeDropPath(paths)) return null;
  return paths.join(" ");
}

// Which pane, if any, a dropped file should land in when it didn't land on
// any specific pane cell (dropped on the sidebar, tab bar, Team Room, ...)
// — the active tab's actually-focused pane if it has one, else its first
// pane, per the spec ("特定できない場合はactiveへ" — a follow-up
// live-testing feedback: prefer the focused pane specifically, not just
// whichever leaf happens to be first in the tree). A pane found directly
// under the cursor is always already in the active window (inactive
// windows' panes are display:none — see the stage render below — so
// elementFromPoint can never hit one), so this fallback only matters for
// the "missed every pane cell" case. lastFocusedPaneId is checked against
// this specific window's own leaves rather than trusted blindly: it's
// tracked globally across the whole app (TerminalPane's onFocusPane), so a
// stale value from a pane in some OTHER tab (never focused anything in the
// current one yet) must fall through to "first leaf", not point outside
// the active tab entirely.
export function resolveFileDropTarget(
  hitPaneId: string | null,
  windows: ReadonlyArray<Pick<Window, "id" | "root">>,
  activeWindowId: string,
  lastFocusedPaneId: string | null,
): string | null {
  if (hitPaneId) return hitPaneId;
  const activeWindow = windows.find((w) => w.id === activeWindowId);
  if (!activeWindow) return null;
  const activeLeaves = leaves(activeWindow.root);
  if (lastFocusedPaneId && activeLeaves.includes(lastFocusedPaneId)) return lastFocusedPaneId;
  return activeLeaves[0] ?? null;
}

// The pane cell (if any) at a given viewport point — shared by the internal
// pointer-drag hit-test and the external file-drop handler. Not unit-
// testable in isolation (elementFromPoint needs real layout, which jsdom
// doesn't compute); exercised via manual live testing instead.
function paneIdAtPoint(x: number, y: number): string | null {
  return document.elementFromPoint(x, y)?.closest<HTMLElement>("[data-pane-id]")?.dataset.paneId ?? null;
}
// A pane being dragged, and where within the target pane it's hovering —
// drives both the drop classification (paneTree's classifyDrop) and the
// half-occupied preview highlight (see dropPreview below). null while
// nothing is being dragged over a pane.
type DropPreview = { paneId: string; zone: ReturnType<typeof classifyDrop> };
type Modal =
  | { kind: "team"; firstRun: boolean }
  | { kind: "agent" }
  | { kind: "appuser"; auto: boolean }
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
// Persists the two View menu toggles below. See the seeding useEffect for
// why restoring these pushes INTO Rust (set_team_room_visible/
// set_user_chat_visible) rather than reading view_visibility unconditionally.
const SHOW_TEAM_ROOM_KEY = "agmsg-app-show-team-room";
const SHOW_USER_CHAT_KEY = "agmsg-app-show-user-chat";
// Persists the sidebar's icon-only-rail collapse toggle.
const SIDEBAR_COLLAPSED_KEY = "agmsg-app-sidebar-collapsed";
// Persists the terminal font size (Settings modal). xterm.js default is 15;
// this app has always hardcoded 12 (a bit denser), so that's the fallback.
const TERMINAL_FONT_SIZE_KEY = "agmsg-app-terminal-font-size";
const DEFAULT_TERMINAL_FONT_SIZE = 12;
// "Don't show this again" for the auto-triggered app-user prompt (see the
// team-change effect below) — adding an app-user is always reachable from
// the chat's "Add one" link, so a user who dismisses the auto-prompt once
// shouldn't be re-asked on every future team switch.
const SUPPRESS_APPUSER_PROMPT_KEY = "agmsg-app-suppress-appuser-prompt";
// Persists the Settings modal's timezone choice (see time.ts) — defaults to
// AUTO_TIMEZONE, which tracks the OS timezone live rather than freezing
// whatever was detected at first launch.
const TIMEZONE_KEY = "agmsg-app-timezone";
// Minimum pointer travel (px) before a pane-header pointerdown counts as a
// drag rather than a click — see startPaneDrag.
const DRAG_THRESHOLD_PX = 4;
// How long after a real pane-header drag ends its own onClick should still
// no-op for a same-element native click that follows — see
// dragJustFinishedRef's doc.
const CLICK_SUPPRESS_WINDOW_MS = 300;

// What startPaneDrag's finish() records — which pane the drag was FOR, not
// just when it ended. Scoping by pane matters: a global timestamp alone
// would suppress a deliberate click on some OTHER pane header too, just
// because it happens to land within the window of an unrelated pane's drag
// finishing (review, PR #481, 3rd round).
export type DragFinishInfo = { paneId: string; finishedAt: number } | null;

// Whether the pane-header's onClick should treat an incoming click as the
// tail end of a just-finished drag gesture (no-op) rather than a genuine
// new click on the button — true only for a click on the SAME pane the
// drag was for, within a short window. The caller (onClick) is expected to
// clear dragFinish (set it back to null) whenever this returns true —
// "consuming" it — so a genuinely separate second click on the same pane,
// even one that lands inside the same window, isn't ALSO wrongly
// suppressed; an unbounded "consume exactly one click" native listener had
// its own problems (see git history), but a per-pane bounded ref without
// consuming still over-suppresses. Pure so the review-requested regressions
// are unit-testable without simulating real pointer/click event sequences.
export function shouldSuppressClickAfterDrag(dragFinish: DragFinishInfo, paneId: string, now: number): boolean {
  return dragFinish !== null && dragFinish.paneId === paneId && now - dragFinish.finishedAt < CLICK_SUPPRESS_WINDOW_MS;
}
// A spawnable agent type discovered from agmsg's type registry.
export type AgentType = { name: string; cli: string; options: string[] };

// Whether the outdated-CLI banner should render. A pure function (rather
// than an inline JSX condition) purely so it's unit-testable — pinning down
// that "Update now" already in flight (updatingCore) and a session-only ×
// dismiss both independently suppress the banner, on top of the base
// coreOutdated !== null check.
export function shouldShowOutdatedBanner<T>(
  coreOutdated: T,
  updatingCore: boolean,
  dismissed: boolean,
): coreOutdated is NonNullable<T> {
  return coreOutdated != null && !updatingCore && !dismissed;
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
  // The outdated banner's own × dismiss — deliberately session-only, not
  // persisted (no localStorage key): a user who dismisses it once still
  // hasn't actually updated the CLI, so the warning should come back on the
  // next launch rather than staying silenced forever.
  const [coreOutdatedDismissed, setCoreOutdatedDismissed] = useState(false);
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
  const [paneStatus, setPaneStatus] = useState<PaneStatusMap>({});
  const [windows, setWindows] = useState<Window[]>([]);
  const [loginShell, setLoginShell] = useState<LoginShellInfo | null>(null);
  const [active, setActive] = useState<string>("room");
  // Remembers which tab was active on each team, so switching back to a
  // team you were already on lands where you left it instead of always
  // resetting to Team Room (see the team-change layout effect below).
  // Session-only (not persisted) — a ref, since it's write-on-leave/
  // read-on-enter bookkeeping that never needs to trigger a render itself.
  const lastActiveTabByTeam = useRef<Record<string, string>>({});
  const prevTeamRef = useRef<string>("");
  const [target, setTarget] = useState<string>("");
  const [draft, setDraft] = useState<string>("");
  const [modal, setModal] = useState<Modal>(null);
  const [newMenu, setNewMenu] = useState(false);
  const [cmdName, setCmdName] = useState("agmsg");
  const [spawnTypes, setSpawnTypes] = useState<AgentType[]>([]);
  const [sidebarWidth, setSidebarWidth] = useState(200);
  const [chatHeight, setChatHeight] = useState(160);
  // Terminal font size, adjustable from the Settings modal and persisted
  // across restarts (see TERMINAL_FONT_SIZE_KEY). Validated against the same
  // range the Settings <input> enforces — a stray/corrupted localStorage
  // value (NaN, Infinity, out of range) would otherwise reach xterm as-is
  // and persist itself right back on the next write.
  const [terminalFontSize, setTerminalFontSize] = useState(() => {
    const stored = Number(localStorage.getItem(TERMINAL_FONT_SIZE_KEY));
    return Number.isFinite(stored) && stored >= MIN_TERMINAL_FONT_SIZE && stored <= MAX_TERMINAL_FONT_SIZE
      ? stored
      : DEFAULT_TERMINAL_FONT_SIZE;
  });
  // Timezone used to display chat/team-room timestamps (see time.ts and
  // TIMEZONE_KEY) — "auto" (the default) tracks the OS timezone live. A
  // corrupted/no-longer-recognized stored zone falls back to "auto" here
  // too, so the Settings <select> always has a matching option instead of
  // rendering blank.
  const [timezone, setTimezone] = useState(() => {
    const stored = localStorage.getItem(TIMEZONE_KEY);
    if (!stored || stored === AUTO_TIMEZONE) return AUTO_TIMEZONE;
    return isValidTimeZone(stored) ? stored : AUTO_TIMEZONE;
  });
  // Collapses the team sidebar to an icon-only rail so panes get more width.
  // Persisted across restarts (see SIDEBAR_COLLAPSED_KEY) — spawning/
  // messaging a member isn't offered from the collapsed rail; expand to get
  // back to the full list.
  const [sidebarCollapsed, setSidebarCollapsed] = useState(
    () => localStorage.getItem(SIDEBAR_COLLAPSED_KEY) === "true",
  );
  // Popup the collapsed rail's team-icon button opens — team switching, the
  // one thing the full sidebar's team <select> offers that needs a menu
  // instead of a direct icon action at rail width. Settings is a direct
  // button in the rail (same as the full view's gear icon), no popup needed.
  const [railTeamMenu, setRailTeamMenu] = useState(false);
  // Toggled from the native "View > Show Team Room" menu item — when off,
  // the room tab itself disappears from the tab bar (not just its
  // content), matching Show User Chat's own toggle just below it.
  // Lazily restored from localStorage (see SHOW_TEAM_ROOM_KEY) rather than
  // always starting `true` and correcting via an effect — the mount-time
  // seeding effect below still exists, but only to push this already-
  // correct initial value INTO Rust, not to setState a second time (that
  // would race the persist effect just below it: a persist effect keyed on
  // [showTeamRoom] captures the value AS OF THE RENDER IT WAS DECLARED IN,
  // so if this state started `true` and got corrected by a later setState,
  // the initial-render persist effect would already have fired and written
  // the stale `true` back to localStorage before the correction landed).
  const [showTeamRoom, setShowTeamRoom] = useState(
    () => localStorage.getItem(SHOW_TEAM_ROOM_KEY) !== "false",
  );
  // Toggled from the native "View > Show User Chat" menu item. See
  // showTeamRoom just above for why this is lazily restored.
  const [showUserChat, setShowUserChat] = useState(
    () => localStorage.getItem(SHOW_USER_CHAT_KEY) !== "false",
  );
  // The app-user chat pane's 3 states (session-only, like sidebarCollapsed):
  // "normal" (today's layout), "minimized" (collapses the history away,
  // leaving just the composer row — the team room becomes the only log,
  // fixing the double-log fatigue real users reported), "maximized" (the
  // chat pane fills the whole content area, hiding the team room/agent
  // panes — a focused 1:1 view). Windows-style min/max header buttons
  // toggle these; clicking maximize while minimized (or vice versa) jumps
  // straight to the other state, same as real OS window controls.
  const [chatPaneState, setChatPaneState] = useState<"normal" | "minimized" | "maximized">("normal");
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
  // Right-click context menu over the Team Room tab itself: { x, y }. Just
  // one action (Hide Team Room) — no per-window data needed, unlike windowMenu.
  const [roomMenu, setRoomMenu] = useState<{ x: number; y: number } | null>(null);
  // Same idea, over the app-user chat pane's own header: { x, y }.
  const [chatMenu, setChatMenu] = useState<{ x: number; y: number } | null>(null);

  // Closes every context/dropdown menu (opening a second one while a
  // first is still open used to stack both — right-clicking a different
  // target, or clicking a different trigger button, never went through the
  // background click-away handler that normally closes these, since it's
  // a completely separate element being interacted with). Every
  // menu-opening handler below calls this first.
  const closeAllMenus = useCallback(() => {
    setNewMenu(false);
    setMemberMenu(null);
    setPaneMenu(null);
    setWindowMenu(null);
    setRoomMenu(null);
    setChatMenu(null);
    setRailTeamMenu(false);
  }, []);
  // The two menus opened by clicking a trigger button (rather than
  // right-clicking somewhere) toggle themselves off on a second click of
  // their OWN button — closeAllMenus alone would fight that (it'd close
  // then the plain !v toggle would immediately reopen it), so these check
  // "is it already open" first and only close-all-others when opening fresh.
  const toggleNewMenu = useCallback(() => {
    if (newMenu) setNewMenu(false);
    else {
      closeAllMenus();
      setNewMenu(true);
    }
  }, [newMenu, closeAllMenus]);
  const toggleRailTeamMenu = useCallback(() => {
    if (railTeamMenu) setRailTeamMenu(false);
    else {
      closeAllMenus();
      setRailTeamMenu(true);
    }
  }, [railTeamMenu, closeAllMenus]);
  // Swap two panes' positions by name: click one pane's name to "pick it
  // up" (its id goes here), then click another pane's name in the same
  // window to swap. Click the same name again to cancel. Also doubles as
  // the pointer-drag source id during a drag-and-drop swap (startPaneDrag
  // sets it once the gesture crosses the drag threshold, clears it on
  // finish/cancel) — click and drag share this one state and the same
  // "armed" highlight, since they're just two ways to pick the same pane up.
  const [swapSource, setSwapSource] = useState<string | null>(null);
  // The pane currently under the cursor during a drag, and which of
  // paneTree's 16 drop zones it's over — drives both the drop's outcome
  // (swap vs. directional split-replace, see classifyDrop) and the preview
  // highlight showing which half will be occupied. Separate from
  // swapSource: that's "picked up", this is "hovering over".
  const [dropPreview, setDropPreview] = useState<DropPreview | null>(null);
  // Same idea, but for tabs — dropping a pane header on a tab moves it into
  // that tab instead of swapping within the current one.
  const [dragOverWindowId, setDragOverWindowId] = useState<string | null>(null);
  // Dropping on the empty strip past the last tab moves the pane to a new
  // tab of its own — same as ctxMenu.pane.moveNewTab, just via drag.
  const [dragOverNewTab, setDragOverNewTab] = useState(false);
  // Live cursor position while a pane-header pointer-drag is past the
  // threshold (see startPaneDrag) — null until then, and again once the
  // gesture ends. Only source of truth for the floating name chip that
  // replaces the old HTML5 setDragImage ghost (pointer-event drags have no
  // native drag-image snapshot of their own).
  const [dragPointer, setDragPointer] = useState<{ x: number; y: number } | null>(null);
  // Which pane, if any, an in-flight EXTERNAL file drag (from Finder/
  // Explorer, via Tauri's onDragDropEvent — see the mount effect below) is
  // currently hovering — reuses the same .pane-cell.drop-target highlight
  // language as the internal drag-drop preview above, so "this pane will
  // receive it" reads consistently regardless of what's being dragged.
  const [externalDropPaneId, setExternalDropPaneId] = useState<string | null>(null);
  // Most recently focused pane, across the whole app (TerminalPane's
  // onFocusPane) — the external-file-drop fallback target when a drop
  // misses every pane cell (prefer the active tab's actual focused
  // pane over just its first one). A plain ref, not state — nothing renders
  // off this, it's only read inside the drag-drop effect below, so tracking
  // it as state would just be a re-render on every pane focus change for no
  // visible benefit. Whether it's usable depends on whether it's still in
  // the CURRENT active window — resolveFileDropTarget checks that, not this
  // ref directly.
  const lastFocusedPaneIdRef = useRef<string | null>(null);
  const handleFocusPane = useCallback((id: string) => {
    lastFocusedPaneIdRef.current = id;
  }, []);
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
  // The stale-context guard openShellTab/openShellInWindow re-check after
  // their getLoginShell await (see below) — a real gap now that login_shell
  // resolution can take real time, during which the user can switch teams
  // or close the target tab (#431).
  const teamRef = useRef<string>("");
  teamRef.current = team;
  // The current tab/window id, for the external-file-drop handler (mount-
  // once effect, refs so it doesn't need to resubscribe on every tab
  // switch) to fall back to when a dropped file doesn't land on any
  // specific pane cell — see resolveFileDropTarget below.
  const activeRef = useRef<string>("room");
  activeRef.current = active;
  // Force-cancels an in-flight pane-header pointer-drag (startPaneDrag
  // below) if this component ever unmounts mid-gesture — App itself never
  // does in practice (root component, lives for the whole session), but the
  // event listeners it registers live on `document`/`window`, outside
  // React's own teardown, so nothing else would ever clear them
  // (review, PR #481).
  const activePaneDragCancelRef = useRef<(() => void) | null>(null);
  useEffect(() => {
    return () => activePaneDragCancelRef.current?.();
  }, []);
  // Which pane a real pane-header drag last finished for, and when
  // (committed OR cancelled — Escape/blur/pointercancel can still end with
  // the pointer back over the source button, which fires a native click
  // there same as any other same-element press/release pair). The dragged
  // pane's own onClick below checks this (shouldSuppressClickAfterDrag) and
  // no-ops + clears it if it matches, so that click doesn't ALSO re-run the
  // swap-arm toggle right after finish() already handled the gesture as a
  // drag. Scoped per-pane and consumed on use, not a global unbounded
  // "consume the next click" listener or a bare timestamp — both over-
  // suppress in different ways (see shouldSuppressClickAfterDrag's own doc
  // and git history; review, PR #481, rounds 2 and 3).
  const dragJustFinishedRef = useRef<DragFinishInfo>(null);
  const applyAgentState = useCallback((paneId: string, state: RawState) => {
    setPaneStatus((current) => applyStateChange(current, paneId, state));
  }, []);

  // Cell size in CSS px. The ref is for snapping a divider drag to whole
  // terminal rows/cols — read once at drag-start, doesn't need a re-render
  // on every fit. The state twin drives the gap BETWEEN panes below (it
  // should be a full terminal cell per axis, herdr-style, not an arbitrary
  // fixed px value) — that one has to be real React state since it feeds
  // rendered CSS. Every pane uses the same fixed font today, so any one of
  // them reporting is representative of them all.
  const cellSizeRef = useRef<{ w: number; h: number } | null>(null);
  const [cellSize, setCellSize] = useState<{ w: number; h: number } | null>(null);
  const handleCellSize = useCallback((w: number, h: number) => {
    cellSizeRef.current = { w, h };
    setCellSize((prev) => (prev && prev.w === w && prev.h === h ? prev : { w, h }));
  }, []);

  // Which divider (by dividerDragKey, below) is currently being dragged —
  // state, not a captured DOM element, so the highlight survives a
  // grid-segment transpose remounting the divider mid-drag (review,
  // PR #390).
  const [draggingDividerKey, setDraggingDividerKey] = useState<string | null>(null);

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
  const groups: { key: string; from: string; to: string; items: Message[] }[] = [];
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

  // What to spawn for the free-shell "+" tab — the user's actual login
  // shell (respecting $SHELL), not a hardcoded one. Resolved once in Rust
  // (lib.rs's login_shell) since the webview has no reliable way to read
  // $SHELL itself (unset for a Finder-launched process — see
  // import_login_shell_path's doc comment). Just a warm-cache prefetch —
  // getLoginShell (below) is what open-shell call sites actually await, so
  // a click landing before this resolves still gets the real shell instead
  // of racing to a fallback.
  useEffect(() => {
    invoke<LoginShellInfo>("login_shell")
      .then(setLoginShell)
      .catch((err) => {
        console.error(err);
      });
  }, []);

  // Resolves login_shell, awaiting Rust if the mount-effect prefetch above
  // hasn't landed yet (real race: app just launched, user immediately hits
  // "+" or "Open shell"). Returns null on failure — callers must NOT
  // fall back to a guessed shell (e.g. "bash"): broken on Windows, and not
  // the user's actual login shell even on unix (review, PR #431).
  const getLoginShell = useCallback(async (): Promise<LoginShellInfo | null> => {
    if (loginShell) return loginShell;
    try {
      const info = await invoke<LoginShellInfo>("login_shell");
      setLoginShell(info);
      return info;
    } catch (err) {
      console.error(err);
      setStartupError(t("startupError.loginShellFailed", { error: String(err) }));
      return null;
    }
  }, [loginShell, t]);

  // showTeamRoom/showUserChat are already correctly seeded from localStorage
  // by their useState initializers above — this effect's only job is to
  // PUSH that initial value into Rust (set_team_room_visible/
  // set_user_chat_visible, which also resyncs the native menu checkbox), so
  // Rust doesn't sit at its own process-default `true` while the frontend
  // shows something else. No setState here: doing so would re-introduce the
  // write-then-correct race this replaced (a persist effect below, keyed on
  // showTeamRoom/showUserChat, would capture the stale initial-render value
  // and write it back to localStorage before a corrective setState's
  // re-render could fix it).
  //
  // Falls back to Rust's own view_visibility only when localStorage has
  // nothing stored yet (true first run) — this also covers a webview
  // remount that doesn't restart the Rust process (Vite HMR during
  // `tauri dev`), where Rust may hold a value localStorage hasn't caught
  // up to yet.
  useEffect(() => {
    const storedTeamRoom = localStorage.getItem(SHOW_TEAM_ROOM_KEY);
    const storedUserChat = localStorage.getItem(SHOW_USER_CHAT_KEY);
    if (storedTeamRoom !== null) void invoke("set_team_room_visible", { visible: storedTeamRoom === "true" });
    if (storedUserChat !== null) void invoke("set_user_chat_visible", { visible: storedUserChat === "true" });
    if (storedTeamRoom === null || storedUserChat === null) {
      invoke<{ team_room: boolean; user_chat: boolean }>("view_visibility")
        .then((v) => {
          if (storedTeamRoom === null) setShowTeamRoom(v.team_room);
          if (storedUserChat === null) setShowUserChat(v.user_chat);
        })
        .catch(() => {});
    }
  }, []);

  // Native "View > Show Team Room" menu checkbox toggles the room tab itself.
  useEffect(() => {
    const p = listen<boolean>("toggle-team-room", (e) => setShowTeamRoom(e.payload));
    return () => void p.then((u) => u());
  }, []);

  // Native "View > Show User Chat" menu checkbox toggles the chat/composer panel.
  useEffect(() => {
    const p = listen<boolean>("toggle-user-chat", (e) => setShowUserChat(e.payload));
    return () => void p.then((u) => u());
  }, []);

  // Persist the two View toggles and the sidebar collapse state across
  // restarts (see their _KEY constants above).
  useEffect(() => {
    localStorage.setItem(SHOW_TEAM_ROOM_KEY, String(showTeamRoom));
  }, [showTeamRoom]);
  useEffect(() => {
    localStorage.setItem(SHOW_USER_CHAT_KEY, String(showUserChat));
  }, [showUserChat]);
  useEffect(() => {
    localStorage.setItem(SIDEBAR_COLLAPSED_KEY, String(sidebarCollapsed));
  }, [sidebarCollapsed]);
  useEffect(() => {
    localStorage.setItem(TERMINAL_FONT_SIZE_KEY, String(terminalFontSize));
  }, [terminalFontSize]);
  useEffect(() => {
    localStorage.setItem(TIMEZONE_KEY, timezone);
  }, [timezone]);
  // Resolved once per render for both message-time display sites below.
  const effectiveTimeZone = resolveTimeZone(timezone);

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
  // the whole visible tab set — restore whichever tab was active the last
  // time this team was selected (lastActiveTabByTeam), rather than leaving
  // `active` pointing at a now-hidden tab from the previous team (its PTY
  // keeps running; the tab just isn't shown here). Falls back to Team Room
  // (or the team's first window, if Team Room is currently hidden — see
  // resolveActiveTab) for a team visited for the first time this session,
  // or if the remembered tab is no longer usable. A layout effect (not a
  // regular one) so this resolves before paint — otherwise the old team's
  // pane, still technically "active" for one frame, would flash visible.
  useLayoutEffect(() => {
    if (!team) return;
    // `active`/`windows`/`showTeamRoom` are read via closure, not deps —
    // this should only re-run when `team` itself changes, using whatever
    // they're currently set to at that moment (the outgoing team's real
    // last-active tab, the freshest window list, and the current Team Room
    // visibility to validate the incoming team's remembered tab against). A
    // mid-visit showTeamRoom toggle is handled separately (see the "if Show
    // Team Room gets switched off" effect below).
    if (prevTeamRef.current) lastActiveTabByTeam.current[prevTeamRef.current] = active;
    const remembered = lastActiveTabByTeam.current[team];
    const openWindowIds = windows.filter((w) => w.team === team).map((w) => w.id);
    setActive(resolveActiveTab(remembered, showTeamRoom, openWindowIds));
    prevTeamRef.current = team;
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
        if (
          !m.some((x) => x.types.includes(APP_USER_TYPE)) &&
          localStorage.getItem(SUPPRESS_APPUSER_PROMPT_KEY) !== "true"
        ) {
          setModal((cur) => cur ?? { kind: "appuser", auto: true });
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

  useEffect(() => {
    const stateListener = listen<{ id: string; state: RawState }>("agent-state", (event) => {
      applyAgentState(event.payload.id, event.payload.state);
    });
    return () => void stateListener.then((unlisten) => unlisten());
  }, [applyAgentState]);

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
  // Splice-only — it never re-homes the pane into some other window (that's
  // moveToNewWindow/movePaneToWindow's job) — which is exactly what
  // splitPaneBeside's cross-window path relies on: detach here, then insert
  // into the target tree in a SEPARATE setWindows call, with no risk of the
  // paneId briefly (or permanently) existing as a leaf in two windows at once.
  const detachPane = useCallback((paneId: string) => {
    const owner = windowsRef.current.find((w) => leaves(w.root).includes(paneId));
    if (!owner) return;
    const nextRoot = spliceOutLeaf(owner.root, paneId);
    if (nextRoot === null) {
      setWindows((prev) => prev.filter((w) => w.id !== owner.id));
      setActive((a) => (a === owner.id ? "room" : a));
    } else {
      setWindows((prev) => prev.map((w) => (w.id === owner.id ? { ...w, root: nextRoot } : w)));
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
        const w = windowsRef.current.find((win) => leaves(win.root).includes(existing.id));
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
          prev.map((w) => (w.id === targetWindowId ? { ...w, root: insertAsNewLeaf(w.root, id) } : w)),
        );
        setActive(targetWindowId);
      } else {
        const winId = `w-${seq.current++}`;
        setWindows((prev) => [...prev, { id: winId, root: { kind: "leaf", paneId: id }, team }]);
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

  useEffect(() => {
    const p = listen<{ id: string }>("pty-exit", (e) => {
      setPaneStatus((current) => {
        if (!(e.payload.id in current)) return current;
        const next = { ...current };
        delete next[e.payload.id];
        return next;
      });
      // A free-shell pane has no "still running, look at the error" state
      // worth preserving the way an agent's crash banner does
      // (TerminalPane's own pty-exit listener writes that inline) — its own
      // exit/Ctrl-D is a deliberate "done here", so the pane (and its
      // tab, if it was the last one) just goes away instead of sitting on a
      // dead prompt. Agent panes are untouched — this only fires for panes
      // flagged `shell`.
      if (panesRef.current.find((pane) => pane.id === e.payload.id)?.shell) {
        closeWindowPane(e.payload.id);
      }
    });
    return () => void p.then((unlisten) => unlisten());
  }, [closeWindowPane]);

  // Dragging a file from Finder/Explorer onto the app used to hand off to
  // the webview's own default drop navigation — for an image, that meant
  // the whole window replaced its content with the image and the app was
  // stuck (reported in use). Tauri's dragDropEnabled (tauri.conf.json,
  // flipped on for this feature) intercepts the OS-level drop entirely and
  // routes it through this native event instead, which is also what makes
  // the fix and the feature the same change: with nothing left to hand off
  // to, the webview never gets a chance to navigate.
  //
  // Mount-once (refs, not state, for the live team/windows/active lookups)
  // — matches the teamRef/windowsRef/activeRef pattern used elsewhere for
  // the same reason: resubscribing a Tauri listener on every tab switch
  // would be wasteful and isn't needed since the callback always reads
  // current refs at drop time.
  useEffect(() => {
    let cancelled = false;
    let unlisten: (() => void) | undefined;
    (async () => {
      const isWindows = navigator.userAgent.toLowerCase().includes("windows");
      const u = await getCurrentWebview().onDragDropEvent((event) => {
        if (event.payload.type === "leave") {
          setExternalDropPaneId(null);
          return;
        }
        // 'enter' and 'over' both carry position. Despite the JS type
        // being PhysicalPosition on every platform, wry's own macOS
        // backend (wkwebview/drag_drop.rs) actually reports AppKit view
        // POINTS — i.e. already logical/CSS-equivalent — mislabeled, not
        // scaled; tauri-runtime-wry passes those straight through with no
        // conversion (confirmed by reading both sources directly). Windows
        // (webview2/drag_drop.rs, via Win32 ScreenToClient) reports real
        // device pixels, which DOES need the devicePixelRatio divide. Using
        // .toLogical() unconditionally halved every coordinate on a 2x
        // Retina Mac, which was consistently landing in/near the top-left
        // pane regardless of actual drop position (reported in use).
        const { x, y } = isWindows
          ? event.payload.position.toLogical(window.devicePixelRatio)
          : event.payload.position;
        const hitPaneId = paneIdAtPoint(x, y);
        if (event.payload.type !== "drop") {
          setExternalDropPaneId(hitPaneId);
          return;
        }
        setExternalDropPaneId(null);
        const text = joinDroppedPaths(event.payload.paths);
        if (text === null) return; // control chars in a path — reject the whole drop, write nothing
        const targetPaneId = resolveFileDropTarget(
          hitPaneId,
          windowsRef.current,
          activeRef.current,
          lastFocusedPaneIdRef.current,
        );
        if (!targetPaneId) return;
        void invoke("pty_write", { id: targetPaneId, data: text });
      });
      if (cancelled) {
        u();
        return;
      }
      unlisten = u;
    })();
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, []);

  // Close a whole tab: kill every pane it holds.
  const closeWindow = useCallback((windowId: string) => {
    const w = windowsRef.current.find((x) => x.id === windowId);
    if (!w) return;
    const paneIds = leaves(w.root);
    for (const pid of paneIds) void invoke("pty_kill", { id: pid });
    setPanes((prev) => prev.filter((p) => !paneIds.includes(p.id)));
    setWindows((prev) => prev.filter((x) => x.id !== windowId));
    setActive((a) => (a === windowId ? "room" : a));
  }, []);

  // Move a pane into another tab, adding it to that tab's side-by-side split
  // (uncapped — N panes in a tab render as N equal columns, see
  // insertAsNewLeaf). The pane's own DOM node never unmounts (see the stage
  // render below), so this is a pure reassignment — the running process and
  // its scrollback are untouched, same as a tmux pane move.
  const movePaneToWindow = useCallback(
    (paneId: string, targetWindowId: string) => {
      const target = windowsRef.current.find((w) => w.id === targetWindowId);
      if (!target || leaves(target.root).includes(paneId)) return;
      detachPane(paneId);
      setWindows((prev) =>
        prev.map((w) => (w.id === targetWindowId ? { ...w, root: insertAsNewLeaf(w.root, paneId) } : w)),
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
      setWindows((prev) => [...prev, { id: winId, root: { kind: "leaf", paneId }, team }]);
      setActive(winId);
    },
    [detachPane, team],
  );

  // A plain login shell pane, unattached to any agent (vim'ing a file,
  // poking around — not agmsg's business). Awaits getLoginShell (see the
  // mount-effect section above) rather than reading `loginShell` state
  // directly — null means it's genuinely unresolved/unresolvable, at which
  // point shellPaneFrom itself refuses to guess a fallback shell (review, PR
  // #431); getLoginShell has already surfaced startupError in that case, so
  // callers just bail out with no pane. cwd defaults to the current team's
  // project dir (teamProject) rather than wherever the shell would
  // otherwise start — re-cd'ing from $HOME every time is tedious —
  // falling back to $HOME only when no project dir is configured. Shared by
  // openShellTab (new tab) and openShellInWindow (split into an existing
  // tab) below; both only ever act on the current team's tabs (windowMenu
  // can only target a teamWindows entry), so teamProject is always the
  // right project for either call site.
  const buildShellPane = useCallback(async (): Promise<Pane | null> => {
    const info = await getLoginShell();
    return shellPaneFrom(info, `shell-${seq.current++}`, t("tabs.shellLabel"), teamProject || info?.home || undefined);
  }, [getLoginShell, t, teamProject]);

  // The "+" tab at the end of the tab bar. Same new-Pane-plus-new-Window
  // shape as spawnMember's no-targetWindowId branch and moveToNewWindow
  // above. buildShellPane's getLoginShell await is a real gap now (not just
  // a microtask) — the user can switch teams while it's in flight, which
  // would otherwise add the new window under the STALE `team` closed over
  // at click time (hidden, since only the current team's windows render)
  // while `active` still points at it (#431). Bail out rather than
  // create an orphaned, invisible tab if the team moved on.
  const openShellTab = useCallback(async () => {
    const requestedTeam = team;
    const pane = await buildShellPane();
    if (!pane || !shellTabStillValid(teamRef.current, requestedTeam)) return;
    setPanes((prev) => [...prev, pane]);
    const winId = `w-${seq.current++}`;
    setWindows((prev) => [...prev, { id: winId, root: { kind: "leaf", paneId: pane.id }, team: requestedTeam }]);
    setActive(winId);
  }, [buildShellPane, team]);

  // A tab's "Open shell" context-menu item — splits a shell pane in beside
  // whatever's already in that tab. The symmetric counterpart of spawning an
  // agent beside an open shell pane (see windowHasShellPane/spawnMember
  // below): either direction, shell and agent end up split in the same tab.
  // Same stale-context concern as openShellTab, in two shapes: the target
  // tab can be closed while getLoginShell's await is in flight (orphaned
  // pane, `active` pointing at a dead id), or the team can just switch
  // while the window itself stays open — it's now a hidden tab under the
  // team the user navigated away from, so splitting into it and activating
  // it reproduces the same hidden-active bug (#431).
  const openShellInWindow = useCallback(
    async (windowId: string) => {
      const requestedTeam = team;
      const pane = await buildShellPane();
      if (!pane || !shellSplitStillValid(windowsRef.current, windowId, teamRef.current, requestedTeam)) return;
      setPanes((prev) => [...prev, pane]);
      setWindows((prev) =>
        prev.map((w) => (w.id === windowId ? { ...w, root: insertAsNewLeaf(w.root, pane.id) } : w)),
      );
      setActive(windowId);
    },
    [buildShellPane, team],
  );

  // True when `windowId`'s tab currently has a free-shell pane in it — the
  // signal spawnMember's sidebar-click site uses to decide "spawn this agent
  // beside the shell in the same tab" (design B) instead of the
  // default "open a new tab".
  const windowHasShellPane = useCallback((windowId: string) => {
    const w = windowsRef.current.find((w) => w.id === windowId);
    if (!w) return false;
    const ids = leaves(w.root);
    return panesRef.current.some((p) => ids.includes(p.id) && p.shell);
  }, []);

  // Swap two panes' positions within the same window (tree shape unchanged
  // — no DOM remount, same as every other pane move in this file).
  const swapPanesInWindow = useCallback((windowId: string, paneA: string, paneB: string) => {
    setWindows((prev) =>
      prev.map((w) => (w.id === windowId ? { ...w, root: swapLeaves(w.root, paneA, paneB) } : w)),
    );
  }, []);

  // Swap two panes across DIFFERENT windows — the "drop near the center of
  // another window's pane" case from the directional drag-drop rule
  // (classifyDrop's swap zones). Two independent renameLeaf calls, one per
  // tree (see paneTree.ts's renameLeaf doc): each tree keeps its shape, just
  // the paneId at that leaf changes. Delegates to swapPanesInWindow when
  // both panes turn out to already be in the same window.
  const swapPanesAcrossWindows = useCallback(
    (paneA: string, windowIdB: string, paneB: string) => {
      const windowA = windowsRef.current.find((w) => leaves(w.root).includes(paneA));
      if (!windowA) return;
      if (windowA.id === windowIdB) {
        swapPanesInWindow(windowIdB, paneA, paneB);
        return;
      }
      setWindows((prev) =>
        prev.map((w) => {
          if (w.id === windowA.id) return { ...w, root: renameLeaf(w.root, paneA, paneB) };
          if (w.id === windowIdB) return { ...w, root: renameLeaf(w.root, paneB, paneA) };
          return w;
        }),
      );
    },
    [swapPanesInWindow],
  );

  // Directional split-drop (classifyDrop's split zones): `sourcePaneId`
  // becomes a new sibling of `targetPaneId` on `side`, splitting that leaf.
  // Same-window: insertBeside handles splicing sourcePaneId out of its
  // current spot in that same tree itself (see its own doc — this is
  // exactly the "newPaneId already present" path). Cross-window: detach it
  // from its own window's tree first (same detach the right-click Move-to
  // path already uses), then insertBeside finds it absent and inserts
  // directly.
  const splitPaneBeside = useCallback(
    (sourcePaneId: string, targetWindowId: string, targetPaneId: string, side: DropSide) => {
      const sourceWindow = windowsRef.current.find((w) => leaves(w.root).includes(sourcePaneId));
      if (sourceWindow && sourceWindow.id !== targetWindowId) {
        detachPane(sourcePaneId);
      }
      setWindows((prev) =>
        prev.map((w) =>
          w.id === targetWindowId ? { ...w, root: insertBeside(w.root, targetPaneId, side, sourcePaneId) } : w,
        ),
      );
      setActive(targetWindowId);
    },
    [detachPane],
  );

  // Where a pane-header pointer-drag currently resolves to: a tab (move into
  // that tab), the empty strip past the last tab (move to a brand-new tab),
  // or another pane cell (swap or directional split, per classifyDrop) —
  // one lookup shared by every pointermove tick during startPaneDrag below.
  // Elements carry data-window-id/data-pane-id specifically so this can
  // identify a target without relying on React event delegation (there's no
  // "real" event routed to the hovered element anymore — see startPaneDrag's
  // own doc for why).
  type PaneDragHit =
    | { kind: "tab"; windowId: string }
    | { kind: "newTab" }
    | { kind: "pane"; paneId: string; zone: ReturnType<typeof classifyDrop> };
  const hitTestPaneDrag = useCallback((x: number, y: number, excludePaneId: string): PaneDragHit | null => {
    const el = document.elementFromPoint(x, y);
    if (!el) return null;
    const tabEl = el.closest<HTMLElement>("[data-window-id]");
    if (tabEl) return { kind: "tab", windowId: tabEl.dataset.windowId! };
    if (el.closest(".tabs-drag-spacer")) return { kind: "newTab" };
    const paneEl = el.closest<HTMLElement>("[data-pane-id]");
    if (paneEl && paneEl.dataset.paneId && paneEl.dataset.paneId !== excludePaneId) {
      const box = paneEl.getBoundingClientRect();
      const zone = classifyDrop((x - box.left) / box.width, (y - box.top) / box.height);
      return { kind: "pane", paneId: paneEl.dataset.paneId, zone };
    }
    return null;
  }, []);

  // Picks up a pane header for a drag-reorder gesture — the pointer-event
  // replacement for the old HTML5 draggable/dragstart/dragover/drop system
  // (removed: Tauri's dragDropEnabled, needed for real absolute paths on
  // external file drops, disables the webview's native HTML5 drag-and-drop
  // entirely — the two are mutually exclusive by Tauri's own design, not a
  // bug). Deliberately does NOT call preventDefault or touch any state
  // until the pointer has actually moved past DRAG_THRESHOLD_PX: below that,
  // this is a plain click, and the existing onClick handler on the same
  // button (unchanged) fires normally once pointerup lands back on it.
  //
  // Lifecycle robustness (review, PR #481 — the first version only
  // listened for pointermove/pointerup/Escape):
  // - setPointerCapture on the source button, released on cleanup: without
  //   it, the pointer leaving the OS window before release means pointerup
  //   never reaches `document` at all, leaking swapSource/preview/chip and
  //   the listeners themselves forever (a stuck "ghost" drag).
  // - pointerId is captured at start and checked on every subsequent event
  //   — a second pointer's events (another touch/pen input) must never
  //   drive or finish someone else's gesture.
  // - pointercancel and window blur (app loses focus mid-drag — e.g. an OS
  //   dialog, Cmd-Tab) both force finish(false), same as Escape.
  // - a real drag can still end with the pointer back over the SOURCE
  //   button (drag out and back, or Escape-cancel then release there) —
  //   that DOES fire a native click on it same as any other press/release
  //   pair landing on the same element, which would otherwise also run
  //   onClick's swap-arm toggle right after finish() already handled the
  //   gesture as a drag. dragJustFinishedRef (declared above, checked by
  //   the pane-header's own onClick) is a per-pane, short bounded window
  //   rather than an unbounded "consume the next click" listener — see its
  //   own doc for why (review, PR #481, 2nd round: a drag that ends via
  //   blur/pointercancel/unmount with the pointer released outside the app
  //   never gets a matching click to consume at all, so a pending listener
  //   would sit on the button forever and wrongly swallow the next,
  //   unrelated real click).
  // - activePaneDragCancelRef (declared above) lets unmount force a cancel;
  //   real listeners still live on document/window, outside React's tree.
  //   Also force-cancels any still-active PRIOR gesture at the start of a
  //   new one — multi-pointer input could otherwise overwrite the ref
  //   without ever tearing down the first gesture's listeners.
  const startPaneDrag = useCallback(
    (e: React.PointerEvent<HTMLButtonElement>, paneId: string) => {
      activePaneDragCancelRef.current?.();
      const pointerId = e.pointerId;
      const target = e.currentTarget;
      const startX = e.clientX;
      const startY = e.clientY;
      let dragging = false;
      let lastHit: PaneDragHit | null = null;

      const applyHit = (hit: PaneDragHit | null) => {
        lastHit = hit;
        setDragOverWindowId(hit?.kind === "tab" ? hit.windowId : null);
        setDragOverNewTab(hit?.kind === "newTab");
        setDropPreview((cur) => {
          if (hit?.kind !== "pane") return null;
          if (cur?.paneId === hit.paneId && sameZone(cur.zone, hit.zone)) return cur;
          return { paneId: hit.paneId, zone: hit.zone };
        });
      };

      const onMove = (ev: PointerEvent) => {
        if (ev.pointerId !== pointerId) return;
        if (!dragging) {
          if (Math.hypot(ev.clientX - startX, ev.clientY - startY) < DRAG_THRESHOLD_PX) return;
          dragging = true;
          setSwapSource(paneId);
        }
        setDragPointer({ x: ev.clientX, y: ev.clientY });
        applyHit(hitTestPaneDrag(ev.clientX, ev.clientY, paneId));
      };

      const cleanup = () => {
        document.removeEventListener("pointermove", onMove);
        document.removeEventListener("pointerup", onUp);
        document.removeEventListener("pointercancel", onCancel);
        document.removeEventListener("keydown", onKeyDown);
        window.removeEventListener("blur", onBlur);
        try {
          target.releasePointerCapture(pointerId);
        } catch {
          // already released (e.g. pointercancel released it first) — fine
        }
        activePaneDragCancelRef.current = null;
      };

      // commit=false is Escape/blur/pointercancel: tear down without acting
      // on lastHit.
      const finish = (commit: boolean) => {
        cleanup();
        if (!dragging) return; // was a click — let the native click event handle it
        dragJustFinishedRef.current = { paneId, finishedAt: Date.now() };
        const hit = lastHit; // stable narrowed binding — lastHit is a mutable closure var
        if (commit && hit) {
          if (hit.kind === "tab") movePaneToWindow(paneId, hit.windowId);
          else if (hit.kind === "newTab") moveToNewWindow(paneId);
          else {
            const targetWindow = windowsRef.current.find((w) => leaves(w.root).includes(hit.paneId));
            if (targetWindow) {
              if (hit.zone.kind === "swap") swapPanesAcrossWindows(paneId, targetWindow.id, hit.paneId);
              else splitPaneBeside(paneId, targetWindow.id, hit.paneId, hit.zone.side);
            }
          }
        }
        setSwapSource(null);
        setDropPreview(null);
        setDragOverWindowId(null);
        setDragOverNewTab(false);
        setDragPointer(null);
      };
      const onUp = (ev: PointerEvent) => {
        if (ev.pointerId !== pointerId) return;
        finish(true);
      };
      const onCancel = (ev: PointerEvent) => {
        if (ev.pointerId !== pointerId) return;
        finish(false);
      };
      const onKeyDown = (ev: KeyboardEvent) => {
        if (ev.key === "Escape") finish(false);
      };
      const onBlur = () => finish(false);

      document.addEventListener("pointermove", onMove);
      document.addEventListener("pointerup", onUp);
      document.addEventListener("pointercancel", onCancel);
      document.addEventListener("keydown", onKeyDown);
      window.addEventListener("blur", onBlur);
      try {
        target.setPointerCapture(pointerId);
      } catch {
        // best-effort — document-level listeners above are the real
        // delivery mechanism, capture just improves off-window reliability
      }
      activePaneDragCancelRef.current = () => finish(false);
    },
    [hitTestPaneDrag, movePaneToWindow, moveToNewWindow, swapPanesAcrossWindows, splitPaneBeside],
  );

  const setWindowLayout = useCallback((windowId: string, layout: PaneLayout) => {
    setWindows((prev) =>
      prev.map((w) => (w.id === windowId ? { ...w, root: presetTree(layout, leaves(w.root)) } : w)),
    );
  }, []);

  // Native "View > Pane Layout" menu items duplicate the right-click-tab
  // context menu's Layout submenu (see the windowMenu render below) — same
  // effect, just also reachable without a right-click. Applies to whichever
  // tab is currently active; a no-op on the team room, which has no panes.
  useEffect(() => {
    const p = listen<PaneLayout>("set-pane-layout", (e) => {
      if (active !== "room") setWindowLayout(active, e.payload);
    });
    return () => void p.then((u) => u());
  }, [active, setWindowLayout]);

  // A tab's label: the user's custom name if set, else its panes' names joined.
  const windowLabel = useCallback(
    (w: Window) =>
      w.customLabel ??
      leaves(w.root)
        .map((pid) => panes.find((p) => p.id === pid)?.label)
        .filter(Boolean)
        .join(" · "),
    [panes],
  );

  // Tabs are scoped to the current team (see the Window type) — other
  // teams' windows stay mounted with their PTYs alive, just not listed
  // here or offered as spawn/move targets.
  const teamWindows = useMemo(() => windows.filter((w) => w.team === team), [windows, team]);
  const teamStatusByName = useMemo(() => {
    return Object.fromEntries(
      teams.map((teamName) => {
        const paneIds = windows
          .filter((window) => window.team === teamName)
          .flatMap((window) => leaves(window.root));
        const statuses = paneIds.map((paneId) => paneStatus[paneId] ?? { state: "unknown" as const });
        return [teamName, aggregateTeamStatus(statuses)];
      }),
    );
  }, [teams, windows, paneStatus]);

  // If Show Team Room gets switched off while it's the active tab, land on
  // whichever pane tab exists instead — the room tab itself is about to
  // disappear from the bar, so "active" can't keep pointing at it. If there
  // are no pane tabs either, there's genuinely nothing to switch to yet;
  // the stage below shows a hint in that case rather than a blank area.
  useEffect(() => {
    if (!showTeamRoom && active === "room" && teamWindows.length > 0) {
      setActive(teamWindows[0].id);
    }
  }, [showTeamRoom, active, teamWindows]);

  // Every window's leaf rects, computed once per render rather than per-pane
  // (computeRects walks the whole tree) — looked up by window id, then pane
  // id, in the panes.map below and again for each window's dividers.
  const rectsByWindow = useMemo(() => {
    const m = new Map<string, Map<string, PaneRect>>();
    for (const w of windows) m.set(w.id, computeRects(w.root));
    return m;
  }, [windows]);

  // Dividers only for the currently active window — they're pure UI chrome
  // with no state of their own beyond the tree's ratios, unlike panes (which
  // stay mounted while inactive to keep their PTY alive), so there's no
  // reason to render an invisible window's dividers too.
  const activeDividers = useMemo(() => {
    const w = windows.find((win) => win.id === active);
    return w ? collectDividers(w.root) : [];
  }, [windows, active]);

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
      // 180, not 140 — narrower than that wraps the brand-row's + New
      // button and the sidebar-title row's All/None filter links onto a
      // second line, which reads as broken rather than compact. Full collapse
      // (the rail toggle) is the way to
      // go narrower than a usable full sidebar now anyway.
      const onMove = (ev: MouseEvent) =>
        setSidebarWidth(Math.max(180, Math.min(520, startW + ev.clientX - startX)));
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

  // Chat pane min/max: clicking one while the OTHER state is active jumps
  // straight there (minimize while maximized goes directly to minimized,
  // not back through normal first) — same as real OS window controls.
  const toggleChatMinimized = useCallback(() => {
    setChatPaneState((s) => (s === "minimized" ? "normal" : "minimized"));
  }, []);
  const toggleChatMaximized = useCallback(() => {
    setChatPaneState((s) => (s === "maximized" ? "normal" : "maximized"));
  }, []);

  // Draggable pane dividers (issue #317). Same document-level drag-tracking
  // pattern as startSidebarDrag/startChatDrag above, but the ratio being
  // dragged belongs to one specific split node rather than a single flat
  // width/height. For a "single" divider that's just divider.path directly
  // — updateRatioAtPath's own doc explains why reusing this path across the
  // whole gesture is safe (a ratio edit never changes the tree's shape).
  //
  // For a "grid-segment" divider (issue #317 part 3 — an aligned grid's
  // per-column/per-row seam, see transposeGrid), the node to drag doesn't
  // exist yet: grabbing it first LAZILY transposes the aligned grid at
  // divider.basePath into the orthogonal arrangement, which is what turns
  // this one segment into its own independent node at
  // [...basePath, ...segmentPath] — transposeGrid's own doc explains why
  // this is safe (visually a no-op, so divider.bounds — captured from
  // BEFORE the transpose — is already correct for the drag math below).
  const startPaneDividerDrag = useCallback((e: React.MouseEvent, windowId: string, divider: DividerInfo) => {
    e.preventDefault();
    const stage = (e.currentTarget as HTMLElement).closest(".stage") as HTMLElement | null;
    if (!stage) return;
    if (divider.kind === "grid-segment") {
      setWindows((prev) =>
        prev.map((w) =>
          w.id === windowId ? { ...w, root: applyAtPath(w.root, divider.basePath, transposeGrid) } : w,
        ),
      );
    }
    const dragPath = divider.kind === "grid-segment" ? [...divider.basePath, ...divider.segmentPath] : divider.path;
    // Captured once at drag-start, not re-measured per mousemove — if the OS
    // window itself is resized mid-drag (rare, and only for the duration of
    // this one gesture), the math below would be against a stale box. Not
    // worth guarding: the next drag on the same divider recaptures it fresh.
    const stageBox = stage.getBoundingClientRect();
    const parentPx = {
      left: stageBox.left + (divider.bounds.left / 100) * stageBox.width,
      top: stageBox.top + (divider.bounds.top / 100) * stageBox.height,
      width: (divider.bounds.width / 100) * stageBox.width,
      height: (divider.bounds.height / 100) * stageBox.height,
    };
    const axis = divider.axis;
    // Minimum pane size in px, converted to a ratio bound against THIS
    // divider's own parent size (paneTree's clampRatio) rather than a flat
    // percent — a flat percent clamp still compounds under nesting (see its
    // own doc).
    const MIN_PANE_PX = 120;
    const cursorClass = axis === "col" ? "resizing-col" : "resizing-row";
    // prefers the divider snapping to whole terminal cells over a
    // free pixel drag (herdr-inspired, though herdr itself had nothing
    // reusable here — this is agmsg's own design). Every pane shares the
    // same fixed font, so one representative cell size (captured by any
    // TerminalPane's fit) is enough regardless of which panes flank this
    // specific divider.
    const cellPx = axis === "col" ? cellSizeRef.current?.w : cellSizeRef.current?.h;
    const onMove = (ev: MouseEvent) => {
      const totalPx = axis === "col" ? parentPx.width : parentPx.height;
      const raw = axis === "col" ? (ev.clientX - parentPx.left) / totalPx : (ev.clientY - parentPx.top) / totalPx;
      const snapped = cellPx ? (Math.round((raw * totalPx) / cellPx) * cellPx) / totalPx : raw;
      const ratio = clampRatio(snapped, MIN_PANE_PX, totalPx);
      setWindows((prev) =>
        prev.map((w) => (w.id === windowId ? { ...w, root: updateRatioAtPath(w.root, dragPath, ratio) } : w)),
      );
    };
    const onUp = () => {
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
      document.body.classList.remove(cursorClass);
      setDraggingDividerKey(null);
    };
    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
    // dragPath.join(".") is this divider's identity on BOTH sides of the
    // grid-segment transpose queued above (see dividerDragKey's doc) — key
    // off that, not a captured DOM element, so the highlight survives even
    // if this transpose swaps in a differently-shaped divider set.
    setDraggingDividerKey(dragPath.join(".") || "root");
    document.body.classList.add(cursorClass);
  }, []);

  return (
    <div className="app" onClick={closeAllMenus}>
      {dragPointer && swapSource && (
        // Follows the cursor during a pane-header pointer-drag — the visible
        // replacement for the old HTML5 setDragImage ghost (which relied on
        // native drag-image snapshotting pointer events don't have).
        // pointer-events: none (App.css) so document.elementFromPoint in
        // hitTestPaneDrag sees through it to the real target underneath.
        <div className="pane-drag-chip" style={{ left: dragPointer.x + 10, top: dragPointer.y + 10 }}>
          {panes.find((p) => p.id === swapSource)?.label}
        </div>
      )}
      {installingAgmsg && (
        <div className="startup-installing-banner">
          <span>{t("startupError.installing")}</span>
        </div>
      )}
      {shouldShowOutdatedBanner(coreOutdated, updatingCore, coreOutdatedDismissed) && (
        <div className="startup-outdated-banner">
          <span>
            {t("startupError.coreOutdated", {
              installed: coreOutdated.installed ?? t("startupError.versionUnknown"),
              pinned: coreOutdated.pinned,
            })}
          </span>
          <div className="startup-outdated-banner-actions">
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
            <button
              className="startup-outdated-banner-dismiss"
              onClick={() => setCoreOutdatedDismissed(true)}
              title={t("startupError.dismiss")}
              aria-label={t("startupError.dismiss")}
            >
              ×
            </button>
          </div>
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
        <aside
          className={sidebarCollapsed ? "sidebar collapsed" : "sidebar"}
          style={{ width: sidebarCollapsed ? undefined : sidebarWidth }}
        >
          {/* Collapse toggle — level with the traffic lights, expanded state
              only (it looked fine there, "closing is perfect"). At
              44px wide the collapsed sidebar sits entirely under the
              traffic-light cluster, so ANY button in this same slim strip
              would overlap them there — collapsed state expands via the
              agmsg mark itself instead (below), not a dedicated button. */}
          {!sidebarCollapsed && (
            <div className="sidebar-toggle-row" data-tauri-drag-region>
              <button
                className="sidebar-collapse-toggle"
                title={t("sidebar.collapse")}
                onClick={() => setSidebarCollapsed(true)}
              >
                <PanelLeftClose size={16} />
              </button>
            </div>
          )}
          {sidebarCollapsed ? (
            // Icon-only rail (by design): the agmsg mark (click to
            // expand) → + (new team/agent, same menu as full view) → team
            // icon (click opens a team-switch popup, replacing the
            // <select>) → spacer → the app-user avatar + a settings button
            // at the bottom. No running-dot / member list — spawning/
            // messaging isn't offered from here at all. Icons are lucide
            // (prefer a real icon set over ad-hoc unicode
            // glyphs/hand-drawn SVGs).
            <div className="sidebar-collapsed-rail">
              <button
                className="rail-logo-mark-btn"
                title={t("sidebar.expand")}
                onClick={() => setSidebarCollapsed(false)}
              >
                <img className="rail-logo-mark" src="/agmsg-mark.png" alt={t("sidebar.logoAlt")} />
              </button>

              <div className="new-wrap" onClick={(e) => e.stopPropagation()}>
                <button className="rail-icon-btn" title={t("sidebar.newMenu.trigger")} onClick={toggleNewMenu}>
                  +
                </button>
                {newMenu && (
                  <div className="new-menu rail-popup">
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

              {team && (
                <div className="rail-menu-wrap" onClick={(e) => e.stopPropagation()}>
                  <button className="rail-icon-btn" title={team} onClick={toggleRailTeamMenu}>
                    <Users size={16} />
                  </button>
                  {railTeamMenu && (
                    <div className="ctx-menu rail-popup">
                      {teams.map((teamName) => (
                        <button
                          key={teamName}
                          className={teamName === team ? "active" : undefined}
                          onClick={() => {
                            setTeam(teamName);
                            setRailTeamMenu(false);
                          }}
                        >
                          {teamName}
                        </button>
                      ))}
                    </div>
                  )}
                </div>
              )}

              <div className="team-status-rail collapsed-team-status" aria-label="Open pane status">
                {teams.map((teamName) => {
                  const status = teamStatusByName[teamName] ?? "unknown";
                  return (
                    <button
                      key={teamName}
                      className={teamName === team ? "team-status-row active" : "team-status-row"}
                      title={`${teamName}: ${status} (open panes)`}
                      onClick={() => setTeam(teamName)}
                    >
                      <span className={`team-status-dot status-${status}`} />
                    </button>
                  );
                })}
              </div>

              <div className="rail-spacer" />

              {appUser && (
                <button
                  className="rail-avatar-btn"
                  title={t("sidebar.expand")}
                  onClick={() => setSidebarCollapsed(false)}
                >
                  <span className="avatar" title={t("sidebar.user.title", { team })} />
                </button>
              )}
              <button
                className="rail-icon-btn"
                title={t("settings.title")}
                onClick={(e) => {
                  e.stopPropagation();
                  setModal({ kind: "settings" });
                }}
              >
                <Settings size={16} />
              </button>
            </div>
          ) : (
            <>
              <div className="sidebar-head" data-tauri-drag-region>
                <div className="brand-row">
                  <img className="logo" src="/agmsg-logo.png" alt={t("sidebar.logoAlt")} />
                </div>
              </div>
              <div className="sidebar-title">
                <span className="sidebar-title-label">
                  {t("sidebar.team.title")}
                  <button
                    className="section-add-btn"
                    title={t("sidebar.team.new")}
                    onClick={() => setModal({ kind: "team", firstRun: false })}
                  >
                    +
                  </button>
                </span>
              </div>
              <div className="team-status-rail" aria-label="Open pane status">
                {teams.map((teamName) => {
                  const status = teamStatusByName[teamName] ?? "unknown";
                  return (
                    <button
                      key={teamName}
                      className={teamName === team ? "team-status-row active" : "team-status-row"}
                      title={`${teamName}: ${status} (open panes)`}
                      onClick={() => setTeam(teamName)}
                    >
                      <span className="team-status-slot">
                        <span className={`team-status-dot status-${status}`} />
                      </span>
                      <span className="team-status-name">{teamName}</span>
                    </button>
                  );
                })}
              </div>
              <div className="sidebar-title">
                <span className="sidebar-title-label">
                  {t("sidebar.title")}
                  <button
                    className="section-add-btn"
                    title={t("sidebar.newAgent")}
                    disabled={!team}
                    onClick={() => {
                      setModal({ kind: "agent" });
                      // Refresh in case spawn-options.yaml or a new type
                      // manifest showed up since app start.
                      invoke<AgentType[]>("agmsg_spawnable_types")
                        .then(setSpawnTypes)
                        .catch(() => {});
                    }}
                  >
                    +
                  </button>
                </span>
                {active === "room" && others.length > 0 && (
                  <span className="filter-actions">
                    <button onClick={selectAllMembers}>{t("sidebar.filter.all")}</button>
                    <span>·</span>
                    <button onClick={selectNoMembers}>{t("sidebar.filter.none")}</button>
                  </span>
                )}
              </div>
              <ul className="members">
                {others.map((m) => {
                  const pane = panes.find(
                    (candidate) =>
                      candidate.label === m.name &&
                      windows.some(
                        (window) =>
                          window.team === team && leaves(window.root).includes(candidate.id),
                      ),
                  );
                  const status = pane ? (paneStatus[pane.id]?.state ?? "unknown") : null;
                  return (
                    <li
                      key={m.name}
                      className="member-row"
                      onContextMenu={(e) => {
                        e.preventDefault();
                        e.stopPropagation();
                        closeAllMenus();
                        setMemberMenu({ member: m, x: e.clientX, y: e.clientY });
                      }}
                    >
                      {active === "room" ? (
                        <input
                          type="checkbox"
                          className="member-check"
                          title={t("sidebar.member.checkboxTitle")}
                          checked={!deselected.has(m.name)}
                          onChange={() => toggleMember(m.name)}
                          onClick={(e) => e.stopPropagation()}
                        />
                      ) : (
                        <span className="member-check-slot">
                          {status && (
                            <PulseDot
                              periodMs={1200}
                              active={status === "working"}
                              className={`agent-status-dot status-${status}`}
                              title={status}
                            />
                          )}
                        </span>
                      )}
                      <button
                        className="member"
                        onClick={() => spawnMember(m, windowHasShellPane(active) ? active : undefined)}
                        title={
                          pane
                            ? t("sidebar.member.titleRunning")
                            : t("sidebar.member.titleSpawn")
                        }
                      >
                        <span className="member-name">{m.name}</span>
                        <span className="member-types">
                          {m.types.join(", ") || t("sidebar.member.noTypes")}
                        </span>
                      </button>
                    </li>
                  );
                })}
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
                    <Settings size={15} />
                  </button>
                </div>
              )}
            </>
          )}
        </aside>

        {!sidebarCollapsed && <div className="divider-v" onMouseDown={startSidebarDrag} />}

        <main className="main">
          <nav className="tabs" data-tauri-drag-region hidden={showUserChat && chatPaneState === "maximized"}>
            {showTeamRoom && (
              <span
                className={active === "room" ? "tab active" : "tab"}
                onContextMenu={(e) => {
                  e.preventDefault();
                  e.stopPropagation();
                  closeAllMenus();
                  setRoomMenu({ x: e.clientX, y: e.clientY });
                }}
              >
                <button className="tab-label" onClick={() => setActive("room")}>
                  {t("tabs.roomLabel")}
                </button>
              </span>
            )}
            {teamWindows.map((w) => (
              <span
                key={w.id}
                data-window-id={w.id}
                className={[
                  active === w.id ? "tab active" : "tab",
                  dragOverWindowId === w.id && "drop-target",
                ]
                  .filter(Boolean)
                  .join(" ")}
                onContextMenu={(e) => {
                  e.preventDefault();
                  e.stopPropagation();
                  closeAllMenus();
                  setWindowMenu({ windowId: w.id, x: e.clientX, y: e.clientY });
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
            <button
              className="tab-new-shell"
              title={t("tabs.newShell")}
              aria-label={t("tabs.newShell")}
              onClick={openShellTab}
            >
              <Plus size={13} />
            </button>
            {/* Tabs are all clickable buttons, so they eat the drag region
                the <nav> itself claims — this dedicated strip is always
                empty and always draggable, regardless of tab count. */}
            <div
              className={dragOverNewTab ? "tabs-drag-spacer drop-target" : "tabs-drag-spacer"}
              data-tauri-drag-region
            />
          </nav>

          <section className="stage" hidden={showUserChat && chatPaneState === "maximized"}>
            <div
              className="room"
              hidden={active !== "room" || !showTeamRoom}
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
                    <span className="grp-time">{formatMessageTime(g.items[0].created_at, effectiveTimeZone)}</span>
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

            {/* Show Team Room is off AND no pane tabs exist yet — the stage
                would otherwise be entirely blank (no room, nothing else to
                switch "active" to). */}
            {!showTeamRoom && teamWindows.length === 0 && (
              <div className="stage-empty-hint">{t("stage.emptyHint")}</div>
            )}

            {/* Every pane is a permanent, flat child of .stage — its window only
                decides WHERE it's positioned (computeRects, from its split
                tree), never whether it's mounted. That keeps each pane's DOM
                node (and TerminalPane's xterm + PTY listeners) alive across a
                Move-to or a layout change, so the running process and its
                scrollback survive — the same pane split tmux gives you, not
                a respawn. Inactive-window panes go visibility:hidden but
                stay laid out, so a resize doesn't leave them stale for next
                time. */}
            {panes.map((p) => {
              const win = windows.find((w) => leaves(w.root).includes(p.id));
              if (!win) return null;
              const rect = rectsByWindow.get(win.id)?.get(p.id);
              if (!rect) return null;
              const isActiveWindow = active === win.id;
              const preview = dropPreview?.paneId === p.id && swapSource !== p.id ? dropPreview.zone : null;
              return (
                <div
                  key={p.id}
                  data-pane-id={p.id}
                  className={[
                    isActiveWindow ? "pane-cell" : "pane-cell inactive",
                    (preview?.kind === "swap" || externalDropPaneId === p.id) && "drop-target",
                  ]
                    .filter(Boolean)
                    .join(" ")}
                  style={{
                    left: `${rect.left}%`,
                    top: `${rect.top}%`,
                    width: `${rect.width}%`,
                    height: `${rect.height}%`,
                    // The gap between two adjacent panes is each side's own
                    // padding added together, so half a cell per side makes
                    // a full terminal cell of gap at the shared seam
                    // (the gap should read as "one cell", not
                    // an arbitrary fixed px value — falls back to the old
                    // fixed padding before any pane has fit and reported
                    // its real cell size).
                    paddingLeft: cellSize ? cellSize.w / 2 : undefined,
                    paddingRight: cellSize ? cellSize.w / 2 : undefined,
                    paddingTop: cellSize ? cellSize.h / 2 : undefined,
                    paddingBottom: cellSize ? cellSize.h / 2 : undefined,
                  }}
                >
                  {preview?.kind === "split" && (
                    <div className={`pane-split-preview preview-${preview.side}`} />
                  )}
                  <div
                    className="pane-header"
                    onContextMenu={(e) => {
                      e.preventDefault();
                      e.stopPropagation();
                      closeAllMenus();
                      setPaneMenu({ paneId: p.id, windowId: win.id, x: e.clientX, y: e.clientY });
                    }}
                  >
                    <button
                      className={
                        swapSource === p.id ? "pane-header-label swap-armed" : "pane-header-label"
                      }
                      title={t("pane.swapTitle")}
                      onPointerDown={(e) => {
                        if (e.button !== 0) return; // left button only, same as native drag
                        startPaneDrag(e, p.id);
                      }}
                      onClick={(e) => {
                        e.stopPropagation();
                        // A real drag that just ended (committed or
                        // cancelled) can still fire this same-element
                        // native click if the pointer ended up back over
                        // THIS pane's own button — see dragJustFinishedRef's
                        // doc. Not this gesture's click to act on; consume
                        // it (clear the ref) so a genuinely separate second
                        // click on this same pane isn't ALSO suppressed.
                        if (shouldSuppressClickAfterDrag(dragJustFinishedRef.current, p.id, Date.now())) {
                          dragJustFinishedRef.current = null;
                          return;
                        }
                        if (swapSource === p.id) {
                          setSwapSource(null);
                        } else if (swapSource && leaves(win.root).includes(swapSource)) {
                          swapPanesInWindow(win.id, swapSource, p.id);
                          setSwapSource(null);
                        } else {
                          setSwapSource(p.id);
                        }
                      }}
                    >
                      {p.label}
                    </button>
                    <PulseDot
                      periodMs={2200}
                      className={p.native ? "monitor-dot native" : "monitor-dot app"}
                    >
                      <span className="monitor-tip">
                        {p.native
                          ? t("pane.monitorTip.native")
                          : t("pane.monitorTip.app")}
                      </span>
                    </PulseDot>
                    <button
                      className="pane-header-close"
                      onClick={() => setModal({ kind: "closePane", paneId: p.id })}
                      title={t("pane.closeTitle")}
                    >
                      ×
                    </button>
                  </div>
                  <TerminalPane
                    id={p.id}
                    cmd={p.cmd}
                    args={p.args}
                    cwd={p.cwd}
                    fontSize={terminalFontSize}
                    active={isActiveWindow}
                    onAgentState={applyAgentState}
                    onCellSize={handleCellSize}
                    onFocusPane={handleFocusPane}
                  />
                </div>
              );
            })}

            {active !== "room" &&
              activeDividers.map((d) => {
                const isDragging = draggingDividerKey !== null && dividerDragKey(d) === draggingDividerKey;
                return (
                  <div
                    key={
                      d.kind === "single"
                        ? `single:${d.path.join(".") || "root"}`
                        : `grid:${d.basePath.join(".") || "root"}:${d.segmentPath.join(".")}`
                    }
                    className={[
                      d.axis === "col" ? "pane-divider-v" : "pane-divider-h",
                      isDragging && "pane-divider-dragging",
                    ]
                      .filter(Boolean)
                      .join(" ")}
                    style={{
                      left: `${d.rect.left}%`,
                      top: `${d.rect.top}%`,
                      width: `${d.rect.width}%`,
                      height: `${d.rect.height}%`,
                    }}
                    onMouseDown={(e) => startPaneDividerDrag(e, active, d)}
                  />
                );
              })}
          </section>

          {showUserChat && chatPaneState === "normal" && (
            <div className="divider-h" onMouseDown={startChatDrag} />
          )}

          {/* App-user chat: the human's own send/receive thread + composer.
              Hidden via View > Show User Chat (native menu checkbox).
              min/max header buttons toggle chatPaneState between normal,
              minimized (history collapsed away — just the composer row,
              fixing the "my own messages show twice" fatigue real users
              reported once the room already shows everything), and
              maximized (fills the whole content area, hiding the team
              room/agent panes — a focused 1:1 view). Clicking the history
              jumps focus to the composer input below — the history itself
              has nothing to focus (nothing to type into), so without this
              the border-on-focus feedback here was invisible in normal use. */}
          <div
            className={`appuser-chat-wrap state-${chatPaneState}`}
            style={chatPaneState === "normal" ? { height: chatHeight } : undefined}
            hidden={!showUserChat}
          >
            <div
              className="appuser-chat-header"
              data-tauri-drag-region
              onContextMenu={(e) => {
                e.preventDefault();
                e.stopPropagation();
                closeAllMenus();
                setChatMenu({ x: e.clientX, y: e.clientY });
              }}
            >
              <span className="appuser-chat-title">{t("chat.title")}</span>
              <div className="appuser-chat-controls">
                <button
                  className="chat-ctrl-btn"
                  title={chatPaneState === "minimized" ? t("chat.restore") : t("chat.minimize")}
                  onClick={toggleChatMinimized}
                >
                  {chatPaneState === "minimized" ? <RectangleHorizontal size={14} /> : <Minus size={14} />}
                </button>
                <button
                  className="chat-ctrl-btn"
                  title={chatPaneState === "maximized" ? t("chat.restore") : t("chat.maximize")}
                  onClick={toggleChatMaximized}
                >
                  {chatPaneState === "maximized" ? <Minimize2 size={14} /> : <Maximize2 size={14} />}
                </button>
              </div>
            </div>

            {chatPaneState !== "minimized" && (
              <div className="appuser-chat" ref={chatRef} onClick={() => composerInputRef.current?.focus()}>
                {myThread.map((m) => (
                  <div className={m.from === appUser ? "chat-line out" : "chat-line in"} key={m.id}>
                    <span className="chat-time">{formatMessageTime(m.created_at, effectiveTimeZone)}</span>
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
                    <button className="link" onClick={() => setModal({ kind: "appuser", auto: false })}>
                      {t("chat.emptyState.addOne")}
                    </button>
                  </div>
                )}
              </div>
            )}

            <footer className="composer">
              {appUser ? (
                <>
                  <span className="as">
                    {/* Word order around the name varies by language (English
                        "as X" puts it after; Japanese "X として" puts it
                        before) — asLabel is the whole template with a literal
                        "{{appUser}}" placeholder, split here so only the name
                        itself renders bold, wherever the translation puts it. */}
                    {(() => {
                      const [before, after] = t("composer.asLabel").split("{{appUser}}");
                      return (
                        <>
                          {before}
                          <b>{appUser}</b>
                          {after}
                        </>
                      );
                    })()}
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
          </div>
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
        <AppUserModal
          onAdd={onAddAppUser}
          onClose={() => {
            // Dismissing the auto-prompt (vs. the "Add one" link's manual
            // open) means the user doesn't want to add one right now — an
            // app-user is always reachable from the chat link, so don't
            // re-ask on every future team switch (see SUPPRESS_APPUSER_PROMPT_KEY).
            if (modal.auto) localStorage.setItem(SUPPRESS_APPUSER_PROMPT_KEY, "true");
            setModal(null);
          }}
          browseDir={browseDir}
        />
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
      {modal?.kind === "settings" && (
        <SettingsModal
          onClose={() => setModal(null)}
          terminalFontSize={terminalFontSize}
          onTerminalFontSizeChange={setTerminalFontSize}
          timezone={timezone}
          onTimezoneChange={setTimezone}
        />
      )}
      {modal?.kind === "closeWindow" &&
        (() => {
          const win = windows.find((w) => w.id === modal.windowId);
          if (!win) return null;
          const names = leaves(win.root)
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
          const sourceLeaves = sourceWindow ? leaves(sourceWindow.root) : [];
          // Only offer "split off into a new tab" when this pane is currently
          // sharing its window — if it's already alone, a new tab would be a no-op.
          const canSplitOff = sourceLeaves.length > 1;
          // Sibling panes in the same tab — the same swap the header's
          // click/drag already does, exposed here too for symmetry with
          // "Move to ▸".
          const siblingPanes = sourceLeaves
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

      {roomMenu && (
        <div className="ctx-menu" style={{ left: roomMenu.x, top: roomMenu.y }} onClick={(e) => e.stopPropagation()}>
          <button
            onClick={() => {
              setShowTeamRoom(false);
              setRoomMenu(null);
              // Keeps the native View > Show Team Room checkbox in sync —
              // it's not the surface that changed this, so Rust's own copy
              // of the toggle state would otherwise go stale.
              void invoke("set_team_room_visible", { visible: false });
            }}
          >
            {t("ctxMenu.room.hide")}
          </button>
        </div>
      )}

      {chatMenu && (
        <div className="ctx-menu" style={{ left: chatMenu.x, top: chatMenu.y }} onClick={(e) => e.stopPropagation()}>
          <button
            onClick={() => {
              setShowUserChat(false);
              setChatMenu(null);
              // Keeps the native View > Show User Chat checkbox in sync —
              // it's not the surface that changed this, so Rust's own copy
              // of the toggle state would otherwise go stale.
              void invoke("set_user_chat_visible", { visible: false });
            }}
          >
            {t("ctxMenu.chat.hide")}
          </button>
        </div>
      )}

      {windowMenu &&
        (() => {
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
              <button
                onClick={() => {
                  openShellInWindow(windowMenu.windowId);
                  setWindowMenu(null);
                }}
              >
                {t("ctxMenu.window.openShell")}
              </button>
              <div className="submenu-trigger">
                <span className="submenu-label">{t("ctxMenu.window.layout")}</span>
                <div className="submenu">
                  {/* No "active" highlight here (unlike before): a preset is a
                      one-shot reset, not a persisted mode (issue #317) — the
                      tab's actual arrangement can be any shape after manual
                      divider drags or split-drops, so no single preset button
                      is "the current one" to mark. */}
                  {layouts.map((l) => (
                    <button
                      key={l}
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
