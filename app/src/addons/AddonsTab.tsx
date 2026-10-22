import { useState } from "react";
import { useTranslation } from "react-i18next";
import { AddonsSettings } from "./AddonsSettings";
import { ConfirmInstallDialog, RemoveDialog } from "./Dialogs";
import { mockEngine, mockSnapshot, mockStage } from "./mock";
import type { AddonsSnapshot, InstallError, StagedInstall } from "./types";

// Container for Settings → Add-ons. Holds the snapshot in local state seeded
// from the mock module; the wiring later replaces the seed and the callbacks
// with the Tauri commands, and the screens do not change.
export function AddonsTab() {
  const { t } = useTranslation();
  const tt = t as never;
  const [snapshot, setSnapshot] = useState<AddonsSnapshot>(mockSnapshot);
  const [installError, setInstallError] = useState<InstallError | null>(null);
  const [staged, setStaged] = useState<StagedInstall | null>(null);
  const [removing, setRemoving] = useState<string | null>(null);
  const removingAddon = snapshot.addons.find((a) => a.id === removing);
  return (
    <>
      <AddonsSettings
        t={tt}
        snapshot={snapshot}
        engine={mockEngine}
        installError={installError}
        onInstall={({ owner, repo }) => {
          if (snapshot.addons.some((a) => a.id === `${owner}/${repo}`)) {
            setInstallError({ code: "already_installed", sha: "d41d8cd" });
            return;
          }
          setInstallError(null);
          setStaged(mockStage(owner, repo));
        }}
        onRevoke={(addonId, i) =>
          setSnapshot((s) => ({ ...s, grants: s.grants.filter((g, idx) => !(g.addonId === addonId && idx === i)) }))
        }
        onCheckUpdate={() => {}}
        onRemove={setRemoving}
        onOpenRequestsChange={(v) => setSnapshot((s) => ({ ...s, openRequests: v }))}
        onLoadFromFolder={() => {}}
      />
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
