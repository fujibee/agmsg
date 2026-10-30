import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { AddonsSettings, openNowRef, type InstalledNotice } from "./AddonsSettings";
import { AddonsTabLive } from "./AddonsTabLive";
import { ConfirmInstallDialog, FetchProgressView, RemoveDialog } from "./Dialogs";
import type { Catalog } from "./catalog";
import { mockSnapshot, mockStage } from "./mock";
import type { AddonPaneRef, AddonsSnapshot, FetchProgress, InstallError, StagedInstall } from "./types";

// Container for Settings → Add-ons. Holds the snapshot in local state seeded
// from the mock module; the wiring later replaces the seed and the callbacks
// with the Tauri commands, and the screens do not change.
export function AddonsTab(props: { catalog: Catalog; openPanesOf: (addonId: string) => number; onOpenPane?: (ref: AddonPaneRef) => void; team?: string; appUser?: string }) {
  return props.catalog.live ? (
    <AddonsTabLive catalog={props.catalog} openPanesOf={props.openPanesOf} onOpenPane={props.onOpenPane} team={props.team} appUser={props.appUser} />
  ) : (
    <MockAddonsTab catalog={props.catalog} onOpenPane={props.onOpenPane} />
  );
}

function MockAddonsTab(props: { catalog: Catalog; onOpenPane?: (ref: AddonPaneRef) => void }) {
  const { catalog } = props;
  const [installedNotice, setInstalledNotice] = useState<InstalledNotice | null>(null);
  const { t } = useTranslation();
  const tt = t as never;
  const [local, setSnapshot] = useState<AddonsSnapshot>(mockSnapshot);
    const snapshot: AddonsSnapshot = local;
  const [installError, setInstallError] = useState<InstallError | null>(null);
  const [staged, setStaged] = useState<StagedInstall | null>(null);
  const [removing, setRemoving] = useState<string | null>(null);
  const [progress, setProgress] = useState<FetchProgress | null>(null);
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  const cancelFetch = () => {
    timers.current.forEach(clearTimeout);
    timers.current = [];
    setProgress(null);
  };
  useEffect(() => cancelFetch, []);
  // Mock of the fetch steps (resolving → downloading → checking); the real one reports from Rust.
  const startFetch = (owner: string, repo: string) => {
    const sha = "d41d8cd98f00b204e9800998ecf8427e1a2b3c4d";
    const steps: [number, FetchProgress | "done"][] = [
      [0, { step: "resolving" }],
      [250, { step: "resolving", sha }],
      [500, { step: "downloading", doneMb: 4, totalMb: 12 }],
      [800, { step: "checking", files: 30, sizeMb: 24 }],
      [1100, "done"],
    ];
    cancelFetch();
    for (const [at, p] of steps) {
      timers.current.push(
        setTimeout(() => {
          if (p === "done") {
            setProgress(null);
            setStaged(mockStage(owner, repo));
          } else setProgress(p);
        }, at),
      );
    }
  };
  if (!catalog.ready) return null;
  const removingAddon = snapshot.addons.find((a) => a.id === removing);
  return (
    <>
      <AddonsSettings
        t={tt}
        snapshot={snapshot}
        engine={catalog.engine}
        installError={installError}
        onInstall={({ owner, repo }) => {
          if (snapshot.addons.some((a) => a.id === `${owner}/${repo}`)) {
            setInstallError({ code: "already_installed", sha: "d41d8cd" });
            return;
          }
          setInstallError(null);
          startFetch(owner, repo);
        }}
        onRevoke={(addonId, i) =>
          setSnapshot((s) => ({ ...s, grants: s.grants.filter((g, idx) => !(g.addonId === addonId && idx === i)) }))
        }
        onCheckUpdate={() => {}}
        onRemove={setRemoving}
        onOpenRequestsChange={(v) => setSnapshot((s) => ({ ...s, openRequests: v }))}
        onLoadFromFolder={() => {}}
        installedNotice={installedNotice}
        onOpenNow={(n) => {
          const ref = openNowRef(n);
          if (ref) props.onOpenPane?.(ref);
        }}
      />
      {progress && <FetchProgressView t={tt} progress={progress} onCancel={cancelFetch} />}
      {staged && (
        <ConfirmInstallDialog
          t={tt}
          staged={staged}
          onCancel={() => setStaged(null)}
          onInstall={() => {
            setSnapshot((s) => ({
              ...s,
              addons: [
                ...s.addons,
                {
                  id: staged.addonId,
                  builtin: false,
                  sha: staged.sha,
                  archiveSha256: staged.archiveSha256,
                  payloadDigest: "",
                  panes: staged.panes,
                  installedAt: new Date().toISOString(),
                  enabled: true,
                },
              ],
            }));
            setInstalledNotice({ kind: staged.from ? "updated" : "installed", addonId: staged.addonId, title: staged.title, paneName: staged.panes[0]?.name });
            setStaged(null);
          }}
        />
      )}
      {removingAddon && (
        <RemoveDialog
          t={tt}
          title={removingAddon.panes[0]?.title ?? removingAddon.id}
          openPanes={0}
          onCancel={() => setRemoving(null)}
          onRemove={() => {
            setSnapshot((s) => ({
              ...s,
              addons: s.addons.filter((a) => a.id !== removing),
              grants: s.grants.filter((g) => g.addonId !== removing),
            }));
            setRemoving(null);
          }}
        />
      )}
    </>
  );
}
