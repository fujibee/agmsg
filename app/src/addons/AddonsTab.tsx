import { useState } from "react";
import { useTranslation } from "react-i18next";
import { AddonsSettings } from "./AddonsSettings";
import { mockEngine, mockSnapshot } from "./mock";
import type { AddonsSnapshot, InstallError } from "./types";

// Container for Settings → Add-ons. Holds the snapshot in local state seeded
// from the mock module; the wiring later replaces the seed and the callbacks
// with the Tauri commands, and AddonsSettings does not change.
export function AddonsTab() {
  const { t } = useTranslation();
  const [snapshot, setSnapshot] = useState<AddonsSnapshot>(mockSnapshot);
  const [installError, setInstallError] = useState<InstallError | null>(null);
  return (
    <AddonsSettings
      t={t as never}
      snapshot={snapshot}
      engine={mockEngine}
      installError={installError}
      onInstall={({ owner, repo }) => setInstallError({ code: "repo_not_found", owner, repo })}
      onRevoke={(addonId, i) =>
        setSnapshot((s) => ({ ...s, grants: s.grants.filter((g, idx) => !(g.addonId === addonId && idx === i)) }))
      }
      onCheckUpdate={() => {}}
      onRemove={(addonId) =>
        setSnapshot((s) => ({
          ...s,
          addons: s.addons.filter((a) => a.id !== addonId),
          grants: s.grants.filter((g) => g.addonId !== addonId),
        }))
      }
      onOpenRequestsChange={(v) => setSnapshot((s) => ({ ...s, openRequests: v }))}
      onLoadFromFolder={() => {}}
    />
  );
}
