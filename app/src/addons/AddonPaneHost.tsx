import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { invoke } from "@tauri-apps/api/core";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { AddonFrame } from "./AddonFrame";
import { AddonPane } from "./AddonPane";
import type { FailureAction } from "./FailureCard";
import type { GrantChoice } from "./GrantCard";
import { grantChips } from "./model";
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
  const [added, setAdded] = useState<AddedPane | null>(null);
  const [state, setState] = useState<PaneState>({ kind: "frame" });
  const [steps, setSteps] = useState<Step[]>([]);
  const [folder, setFolder] = useState<string | null>(pane.openArgs?.path ?? null);
  const [chips, setChips] = useState<GrantChip[]>([]);
  const [blocked, setBlocked] = useState<string | undefined>();
  const [attempt, setAttempt] = useState(0);
  const [reloadKey, setReloadKey] = useState(0);
  const addonsRef = useRef(props.addons);
  addonsRef.current = props.addons;

  // Open the pane (again on every retry); the pane is removed when this goes away.
  useEffect(() => {
    let cancelled = false;
    let openedId: number | null = null;
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
      .then((a) => {
        if (cancelled) {
          void source.removePane(a.id).catch(() => {});
          return;
        }
        openedId = a.id;
        setAdded(a);
        const next: Step[] = [];
        if (a.permissions.includes("messages:read")) next.push("team");
        if (a.permissions.includes("files:read") || a.permissions.includes("git:read")) next.push("folder");
        setSteps(next);
      })
      .catch((e) => {
        if (!cancelled) setState({ kind: "failure", failure: { code: "open_failed", message: toCommandError(e).message } });
      });
    return () => {
      cancelled = true;
      if (openedId !== null) void source.removePane(openedId).catch(() => {});
    };
  }, [pane.addonId, pane.paneName, pane.openArgs, attempt]);

  const chooseFolder = async () => {
    const picked = await openDialog({ directory: true, multiple: false });
    if (typeof picked === "string") setFolder(picked);
    else if (folder === null) props.onClose();
  };

  // Show the card for the first step still open; with none left the frame runs.
  useEffect(() => {
    if (!added) return;
    const step = steps[0];
    if (step === undefined) {
      setState({ kind: "frame" });
    } else if (step === "team") {
      setState({ kind: "grant", need: { permission: "messages:read", team: props.team } });
    } else if (folder === null) {
      void chooseFolder();
    } else {
      setState({ kind: "grant", need: { permission: "files:read", path: folder, fileCount: null, denied: false } });
    }
  }, [added, steps, folder, props.team]);

  const onGrant = async (c: GrantChoice) => {
    if (!added || state.kind !== "grant") return;
    const need = state.need;
    if (c === "notNow") {
      if (need.permission === "files:read") {
        setFolder(null);
        void chooseFolder();
      } else props.onClose();
      return;
    }
    if (need.permission === "messages:read") {
      const r = await source.grantTeam(added.id, need.team);
      if (!r.ok) return setState({ kind: "failure", failure: { code: "open_failed", message: r.error.message } });
      setChips((cs) => [...cs, { key: `team:${need.team}`, label: need.team }]);
    } else {
      const r = await source.grantRoot(added.id, need.path);
      if (!r.ok) {
        if (r.error.code === "denied_path") return setState({ kind: "grant", need: { ...need, denied: true } });
        if (r.error.code === "not_found") return setState({ kind: "failure", failure: { code: "path_missing", path: need.path } });
        return setState({ kind: "failure", failure: { code: "open_failed", message: r.error.message } });
      }
      setChips((cs) => [...cs, { key: `root:${r.realPath}`, label: r.realPath }]);
    }
    setSteps((s) => s.slice(1));
  };

  const onFailure = (a: FailureAction) => {
    if (a === "reload") setAttempt((n) => n + 1);
    else if (a === "chooseAnother") {
      setFolder(null);
      setState({ kind: "frame" });
      void chooseFolder();
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
