import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { AddonFrame } from "./AddonFrame";
import { AddonPane } from "./AddonPane";
import type { FailureAction } from "./FailureCard";
import type { GrantChoice } from "./GrantCard";
import { grantChips } from "./model";
import { createOpGuard } from "./opGuard";
import { listenPaneFailed, type PaneFailedEvent } from "./paneFailed";
import { pickSavedRoot, pickSavedTeam } from "./savedGrants";
import { mockGrantNeeds, mockSnapshot } from "./mock";
import { createLiveSource, parseNetwork, toCommandError, type AddedPane } from "./source";
import type { AddonPaneRef, GrantChip, GrantNeed, InstalledAddon, PaneState } from "./types";

const source = createLiveSource((cmd, args) => invoke(cmd, args));

// One add-on pane in a tab. In the app it runs the real thing: addon_pane_add,
// the grant cards (Rust holds and decides every grant), then the sandboxed
// frame. Without Tauri (vite dev) it runs on mock state instead.
export function AddonPaneHost(props: {
  pane: AddonPaneRef;
  team: string;
  live: boolean;
  addons: InstalledAddon[];
  onClose: () => void;
  onOpenSettings: () => void;
}) {
  return props.live ? <LiveAddonPane {...props} /> : <MockAddonPane pane={props.pane} onClose={props.onClose} />;
}

type Step = "team" | "folder";

function LiveAddonPane(props: {
  pane: AddonPaneRef;
  team: string;
  addons: InstalledAddon[];
  onClose: () => void;
  onOpenSettings: () => void;
}) {
  const { t } = useTranslation();
  const tt = t as never;
  const { pane } = props;
  const addon = props.addons.find((a) => a.id === pane.addonId);
  const decl = addon?.panes.find((p) => p.name === pane.paneName);
  const isDev = pane.addonId.startsWith("dev:");
  const [added, setAdded] = useState<AddedPane | null>(null);
  const [state, setState] = useState<PaneState>({ kind: "frame" });
  const [steps, setSteps] = useState<Step[]>([]);
  const [folder, setFolder] = useState<string | null>(pane.openArgs?.path ?? null);
  const [chips, setChips] = useState<GrantChip[]>([]);
  const [blocked, setBlocked] = useState<string | undefined>();
  const [attempt, setAttempt] = useState(0);
  const [reloadKey, setReloadKey] = useState(0);
  const [pending, setPending] = useState(false);
  // One grant call or folder dialog at a time; invalidated when the pane is reopened or goes away.
  const guard = useRef(createOpGuard());
  const addonsRef = useRef(props.addons);
  const teamRef = useRef(props.team);
  teamRef.current = props.team;
  addonsRef.current = props.addons;

  // Open the pane (again on every retry); the pane is removed when this goes away.
  useEffect(() => {
    let cancelled = false;
    let openedId: number | null = null;
    guard.current.invalidate();
    setPending(false);
    setAdded(null);
    setSteps([]);
    setState({ kind: "frame" });
    setChips([]);
    setBlocked(undefined);
    const known = addonsRef.current.find((a) => a.id === pane.addonId);
    if (known && known.digestOk === false) {
      setState({ kind: "failure", failure: { code: "digest_mismatch" } });
      return;
    }
    source
      .addPane({ addonId: pane.addonId, pane: pane.paneName, openArgs: pane.openArgs ?? {} })
      .then(async (a) => {
        if (cancelled) {
          void source.removePane(a.id).catch(() => {});
          return;
        }
        openedId = a.id;
        const next: Step[] = [];
        if (a.permissions.includes("messages:read")) next.push("team");
        if (a.permissions.includes("files:read") || a.permissions.includes("git:read")) next.push("folder");
        // Replay what the user chose to remember; Rust checks each one again as if new. Not for developer copies.
        const replayed: GrantChip[] = [];
        if (!pane.addonId.startsWith("dev:")) {
          const saved = await source.savedGrants(pane.addonId, pane.paneName);
          if (cancelled) return;
          if (saved.ok) {
            const team = next.includes("team") ? pickSavedTeam(saved.value, teamRef.current) : undefined;
            if (team !== undefined && (await source.grantTeam(a.id, team)).ok) {
              replayed.push({ key: `team:${team}`, label: team });
              next.splice(next.indexOf("team"), 1);
            }
            const root = next.includes("folder") ? pickSavedRoot(saved.value, pane.openArgs?.path) : undefined;
            if (root !== undefined) {
              const g = await source.grantRoot(a.id, root);
              if (g.ok) {
                replayed.push({ key: `root:${g.realPath}`, label: g.realPath });
                next.splice(next.indexOf("folder"), 1);
              }
            }
          }
          if (cancelled) return;
        }
        setChips(replayed);
        setAdded(a);
        setSteps(next);
      })
      .catch((e) => {
        if (!cancelled) setState({ kind: "failure", failure: { code: "open_failed", message: toCommandError(e).message } });
      });
    return () => {
      cancelled = true;
      guard.current.invalidate();
      if (openedId !== null) void source.removePane(openedId).catch(() => {});
    };
  }, [pane.addonId, pane.paneName, pane.openArgs, attempt]);

  // Rust closes a pane whose files changed after it opened and says so; show its reason with Reload / Remove.
  useEffect(() => {
    if (!added) return;
    return listenPaneFailed(
      (event, handler) => listen<PaneFailedEvent>(event, handler),
      added.id,
      (reason) => setState({ kind: "failure", failure: { code: "pane_closed", reason } }),
    );
  }, [added]);

  const chooseFolder = async () => {
    const r = await guard.current.run(() => openDialog({ directory: true, multiple: false })).catch((e) => {
      setState({ kind: "failure", failure: { code: "open_failed", message: toCommandError(e).message } });
      return null;
    });
    if (r === null) return;
    if (r.kind !== "done") return; // another operation is running, or this attempt is gone
    if (typeof r.value === "string") setFolder(r.value);
    else props.onClose(); // cancelling the folder choice leaves nothing to show, so the pane closes (same as "Not now" on the team card)
  };

  // Show the card for the first step still open; with none left the frame runs.
  useEffect(() => {
    if (!added) return;
    const step = steps[0];
    if (step === undefined) {
      setState({ kind: "frame" });
    } else if (step === "team") {
      setState({ kind: "grant", need: { permission: "messages:read", team: props.team, why: decl?.why["messages:read"] } });
    } else if (folder === null) {
      void chooseFolder();
    } else {
      setState({ kind: "grant", need: { permission: "files:read", path: folder, fileCount: null, denied: false, why: decl?.why["files:read"] } });
    }
  }, [added, steps, folder, props.team]);

  const onGrant = async (c: GrantChoice) => {
    if (!added || state.kind !== "grant" || guard.current.isBusy()) return;
    const need = state.need;
    const step: Step = need.permission === "messages:read" ? "team" : "folder";
    if (c === "notNow") {
      // "Not now" declines: the pane closes. On the denied card the same button reads "Choose another…" and picks again;
      // dropping the folder is what makes the effect above launch the picker (its only owner).
      if (need.permission === "files:read" && need.denied) setFolder(null);
      else props.onClose();
      return;
    }
    setPending(true);
    const r = await guard.current.run(async ({ stale }): Promise<{ error: { code: string; message: string } } | { chip: GrantChip; saveFailed?: string }> => {
      const remember = !isDev && (c === "always" || need.permission === "messages:read");
      if (need.permission === "messages:read") {
        const g = await source.grantTeam(added.id, need.team);
        if (!g.ok) return { error: g.error };
        // The pane was reopened or its add-on updated while the grant ran: that consent must not be saved.
        const saved = remember && !stale() ? await source.saveGrant(pane.addonId, pane.paneName, "messages:read", need.team) : null;
        return { chip: { key: `team:${need.team}`, label: need.team }, saveFailed: saved && !saved.ok ? saved.error.message : undefined };
      }
      const g = await source.grantRoot(added.id, need.path);
      if (!g.ok) return { error: g.error };
      const saved = remember && !stale() ? await source.saveGrant(pane.addonId, pane.paneName, "files:read", g.realPath) : null;
      return { chip: { key: `root:${g.realPath}`, label: g.realPath }, saveFailed: saved && !saved.ok ? saved.error.message : undefined };
    });
    if (r.kind !== "done") return; // busy: ignored; stale: the pane was reopened, so nothing here applies to it
    setPending(false);
    if ("error" in r.value) {
      const e = r.value.error;
      if (need.permission === "files:read" && e.code === "denied_path") return setState({ kind: "grant", need: { ...need, denied: true } });
      if (need.permission === "files:read" && e.code === "not_found") return setState({ kind: "failure", failure: { code: "path_missing", path: need.path } });
      return setState({ kind: "failure", failure: { code: "open_failed", message: e.message } });
    }
    const chip = r.value.chip;
    setChips((cs) => [...cs, chip]);
    // Allowed for now, but it could not be remembered: say so, never pretend.
    if (r.value.saveFailed) setBlocked(r.value.saveFailed);
    // Only the step this card was for is done; another step stays.
    setSteps((s) => (s[0] === step ? s.slice(1) : s));
  };

  const onFailure = (a: FailureAction) => {
    if (a === "reload") setAttempt((n) => n + 1);
    else if (a === "chooseAnother") {
      setFolder(null);
      setState({ kind: "frame" });
    } else if (a === "allowAgain") setAttempt((n) => n + 1);
    else props.onOpenSettings();
  };

  const network = parseNetwork(added?.network ?? "");
  const title = added?.title ?? pane.title;
  return (
    <AddonPane
      t={tt}
      title={title}
      chips={[...chips, ...grantChips([], decl?.network ?? network, tt)]}
      askedBy={pane.askedBy}
      blocked={blocked}
      canRemember={!isDev}
      devFolder={addon?.dev?.label}
      pending={pending}
      hideTitle
      hideClose
      state={state}
      frame={
        // No frame until every grant card is answered: a frame that loads early would start a generation for nothing.
        added && steps.length === 0 ? (
          <AddonFrame
            paneInstance={added.id}
            url={added.url}
            title={title}
            declaresMessages={added.permissions.includes("messages:read")}
            reloadKey={reloadKey}
            onRefused={(op, code) => setBlocked(`${op} (${code})`)}
            onFeedFailed={(code, message) =>
              setState({ kind: "failure", failure: code === "init_too_large" ? { code } : { code: "open_failed", message } })
            }
          />
        ) : undefined
      }
      onReload={() => (state.kind === "frame" ? setReloadKey((n) => n + 1) : setAttempt((n) => n + 1))}
      onClose={props.onClose}
      onGrant={(c) => void onGrant(c)}
      onFailure={onFailure}
    />
  );
}

// Holds one add-on pane's state on mock data: starts at the grant card for
// what the pane declares, Allow moves to the frame placeholder, Reload goes
// back through the same path. The wiring later replaces this state with the
// relay (addon_pane_add / addon_pane_loaded / port) and AddonPane stays as is.
function MockAddonPane(props: { pane: AddonPaneRef; onClose: () => void }) {
  const { t } = useTranslation();
  const addon = mockSnapshot.addons.find((a) => a.id === props.pane.addonId);
  const decl = addon?.panes.find((p) => p.name === props.pane.paneName);
  const [state, setState] = useState<PaneState>(() =>
    decl?.permissions.includes("messages:read")
      ? { kind: "grant", need: mockGrantNeeds.messages }
      : decl?.permissions.includes("files:read")
        ? { kind: "grant", need: { permission: "files:read", path: props.pane.openArgs?.path ?? "", fileCount: 1240, denied: false } satisfies GrantNeed }
        : { kind: "frame" },
  );
  const [chips, setChips] = useState<GrantChip[]>([]);
  const tt = t as never;
  return (
    <AddonPane
      t={tt}
      title={props.pane.title}
      chips={[...chips, ...grantChips([], decl?.network ?? { kind: "none" }, tt)]}
      askedBy={props.pane.askedBy}
      hideTitle
      hideClose
      state={state}
      onReload={() => setState((s) => (s.kind === "failure" ? { kind: "frame" } : s))}
      onClose={props.onClose}
      onGrant={(c) => {
        if (c === "notNow" || state.kind !== "grant") return;
        const scope = state.need.permission === "messages:read" ? state.need.team : state.need.path;
        setChips([{ key: scope, label: scope }]);
        setState({ kind: "frame" });
      }}
      onFailure={() => setState({ kind: "frame" })}
    />
  );
}
