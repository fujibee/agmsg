import { useOpenRequestsSetting } from "./openRequestsSetting";
import { useCallback, useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { AddonsSettings, openNowRef, type InstalledNotice } from "./AddonsSettings";
import type { Catalog } from "./catalog";
import { collectSavedGrants } from "./collectGrants";
import { closeIfStill, useBusy } from "../busy";
import { AddonAgents } from "./AddonAgents";
import { ConfirmInstallDialog, FetchProgressView, RemoveDialog } from "./Dialogs";
import { createLiveSource, toCommandError, type MemberState, type Outcome } from "./source";
import type { AddonPaneRef, FetchProgress, Grant, InstallError, StagedInstall } from "./types";

const source = createLiveSource((cmd, args) => invoke(cmd, args));

type Notice = { kind: "info" | "error"; text: string };

// Settings → Add-ons on the real commands: install and update through the
// fetch / confirm steps, remove, developer folders, and the remembered grants.
// Rust does the work and says why it refuses; this shows its words.
export function AddonsTabLive(props: { catalog: Catalog; openPanesOf: (addonId: string) => number; onOpenPane?: (ref: AddonPaneRef) => void; team?: string; appUser?: string }) {
  const { catalog } = props;
  const { t } = useTranslation();
  const tt = t as never;
  const [installError, setInstallError] = useState<InstallError | null>(null);
  const [notice, setNotice] = useState<Notice | null>(null);
  const [installedNotice, setInstalledNotice] = useState<InstalledNotice | null>(null);
  const [staged, setStaged] = useState<StagedInstall | null>(null);
  const [removing, setRemoving] = useState<string | null>(null);
  const [progress, setProgress] = useState<FetchProgress | null>(null);
  const [grants, setGrants] = useState<Grant[]>([]);
  const [grantsError, setGrantsError] = useState<string | null>(null);
  const grantsSeq = useRef(0);
  // The members and agents add-ons made: read when this opens and on Refresh or after a choice, never on a timer.
  const [entries, setEntries] = useState<MemberState[]>([]);
  const [left, setLeft] = useState<ReadonlySet<string>>(new Set());
  const [openRequests, setOpenRequests] = useOpenRequestsSetting();
  // Everything a click starts and Rust answers later: its button shows it until the answer, success or not.
  const { busy, run } = useBusy();
  // The fetch in flight: its progress and result count only while this is still its id.
  const currentOp = useRef<string | null>(null);
  const opSeq = useRef(0);
  const devFolders = useRef(new Map<string, string>());
  // The scripts folder of the agmsg this app runs against, for the text copied for agents.
  const [scriptsDir, setScriptsDir] = useState("");
  useEffect(() => {
    invoke<string>("agmsg_scripts_dir").then(setScriptsDir, () => setScriptsDir(""));
  }, []);

  useEffect(() => {
    const un = listen<{ opId: string | null; step: string; detail: string }>("addon-install-progress", (e) => {
      const p = e.payload;
      if (p.opId === null || p.opId !== currentOp.current) return;
      if (p.step === "resolving") setProgress({ step: "resolving", sha: /commit ([0-9a-f]{7,40})/.exec(p.detail)?.[1] });
      else if (p.step === "downloading") setProgress({ step: "downloading" });
      else if (p.step === "checking") setProgress({ step: "checking" });
    });
    return () => void un.then((f) => f());
  }, []);
  useEffect(
    () => () => {
      currentOp.current = null;
    },
    [],
  );

  // Remembered grants of the installed add-ons, read from Rust whenever the list changes.
  const loadGrants = useCallback(async () => {
    const seq = ++grantsSeq.current;
    const { grants: out, failure } = await collectSavedGrants(catalog.addons, source.savedGrants);
    if (seq !== grantsSeq.current) return; // a newer load started: this one is out of date
    setGrants(out);
    setGrantsError(failure);
  }, [catalog.addons]);
  useEffect(() => {
    void loadGrants();
  }, [loadGrants]);

  const fail = (e: { message: string }) => setInstallError({ code: "message", message: e.message });

  // Install and "Check for updates" share one path: stage, then confirm.
  const stage = async (run: (opId: string) => Promise<Outcome<StagedInstall>>, isUpdate: boolean) => {
    const opId = `op-${++opSeq.current}`;
    currentOp.current = opId;
    setInstallError(null);
    setNotice(null);
    setInstalledNotice(null);
    setProgress({ step: "resolving" });
    const r = await run(opId);
    if (currentOp.current !== opId) {
      // Cancelled meanwhile: drop what was staged.
      if (r.ok && r.value.stagingId) void source.installCancel(r.value.stagingId);
      return;
    }
    currentOp.current = null;
    setProgress(null);
    if (r.ok) return setStaged(r.value);
    if (isUpdate && r.error.code === "up_to_date") return setNotice({ kind: "info", text: r.error.message });
    if (isUpdate) return setNotice({ kind: "error", text: r.error.message });
    fail(r.error);
  };
  const cancelFetch = () => {
    currentOp.current = null;
    setProgress(null);
  };

  const confirm = async () => {
    const s = staged;
    if (!s?.stagingId) return;
    // The dialog stays up, with Install busy, until Rust has answered.
    try {
      const r = await source.installConfirm(s.stagingId);
      if (!r.ok) setNotice({ kind: "error", text: r.error.message });
      else setInstalledNotice({ kind: s.from ? "updated" : "installed", addonId: s.addonId, title: s.title, paneName: s.panes[0]?.name });
    } finally {
      // Only the dialog this answer is for: another install may have been staged meanwhile.
      setStaged((cur) => closeIfStill(cur, s, (a, b) => a.stagingId === b.stagingId));
    }
    catalog.reload();
  };
  const cancelConfirm = () => {
    if (staged?.stagingId) void source.installCancel(staged.stagingId);
    setStaged(null);
  };

  const removingAddon = catalog.addons.find((a) => a.id === removing);
  const doRemove = async () => {
    const a = removingAddon;
    setInstalledNotice(null);
    if (!a) return setRemoving(null);
    // The dialog stays up, with Remove busy, until Rust has answered.
    try {
      const r = a.dev ? await source.devRemove(a.id) : await source.remove(a.id);
      if (!r.ok) setNotice({ kind: "error", text: r.error.message });
    } finally {
      setRemoving((cur) => closeIfStill(cur, a.id, (x, y) => x === y));
    }
    catalog.reload();
  };

  const loadFolder = async (known?: string) => {
    let picked: unknown = known;
    if (picked === undefined) {
      try {
        picked = await openDialog({ directory: true, multiple: false });
      } catch (e) {
        return setNotice({ kind: "error", text: toCommandError(e).message });
      }
    }
    if (typeof picked !== "string") return;
    setNotice(null);
    const r = await source.devLoad(picked);
    if (!r.ok) setNotice({ kind: "error", text: r.error.message });
    else devFolders.current.set(r.value.id, picked);
    catalog.reload();
  };

  const loadEntries = useCallback(async () => {
    const r = await source.membersState();
    if (r.ok) setEntries(r.value);
    else setNotice({ kind: "error", text: r.error.message });
  }, []);
  useEffect(() => {
    void loadEntries();
  }, [loadEntries]);

  if (!catalog.ready) return null;
  return (
    <>
      <AddonsSettings
        t={tt}
        snapshot={{ addons: catalog.addons, grants, openRequests }}
        engine={catalog.engine}
        busy={busy}
        seat={{ team: props.team ?? "", appUser: props.appUser ?? "", scriptsDir }}
        listError={catalog.listError}
        onRetryList={catalog.reload}
        installError={installError}
        notice={notice}
        grantsError={grantsError ?? undefined}
        onRetryGrants={() => void run("grants", loadGrants)}
        onInstall={({ owner, repo, ref }) => void run("install", () => stage((opId) => source.installStart(`${owner}/${repo}${ref ? `@${ref}` : ""}`, opId), false))}
        onCheckUpdate={(id) => void run(`check:${id}`, () => stage((opId) => source.checkUpdate(id, opId), true))}
        onRevoke={(addonId, i) => {
          const g = grants[i];
          if (!g || g.addonId !== addonId) return;
          void run(`revoke:${addonId}:${i}`, async () => {
            const r = await source.forgetGrant(g.addonId, g.pane, g.permission, g.scope);
            if (!r.ok) setNotice({ kind: "error", text: r.error.message });
            await loadGrants();
          });
        }}
        onRemove={setRemoving}
        onOpenRequestsChange={setOpenRequests}
        onLoadFromFolder={() => void run("load", () => loadFolder())}
        onDevReload={(id) => void run(`reload:${id}`, () => loadFolder(devFolders.current.get(id)))}
        installedNotice={installedNotice}
        onRecheck={() => void source.recheck()}
        onOpenNow={(n) => {
          const ref = openNowRef(n);
          if (ref) props.onOpenPane?.(ref);
        }}
      />
      <AddonAgents
        t={tt}
        entries={entries}
        left={left}
        busy={busy}
        onRefresh={() => void run("agents", loadEntries)}
        onLeave={(key) => setLeft((s) => new Set(s).add(key))}
        onOpen={(key) =>
          void run(`agent:${key}`, async () => {
            const r = await source.agentReopen(key);
            if (!r.ok) setNotice({ kind: "error", text: r.error.message });
            await loadEntries();
          })
        }
      />
      {progress && <FetchProgressView t={tt} progress={progress} onCancel={cancelFetch} />}
      {staged && <ConfirmInstallDialog t={tt} staged={staged} busy={busy.has("confirm")} onCancel={cancelConfirm} onInstall={() => void run("confirm", confirm)} />}
      {removingAddon && (
        <RemoveDialog
          t={tt}
          title={removingAddon.panes[0]?.title ?? removingAddon.id}
          openPanes={props.openPanesOf(removingAddon.id)}
          busy={busy.has("remove")}
          onCancel={() => setRemoving(null)}
          onRemove={() => void run("remove", doRemove)}
        />
      )}
    </>
  );
}
