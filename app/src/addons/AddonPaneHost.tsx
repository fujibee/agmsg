import { useState } from "react";
import { useTranslation } from "react-i18next";
import { AddonPane } from "./AddonPane";
import { grantChips } from "./model";
import { mockGrantNeeds, mockSnapshot } from "./mock";
import type { AddonPaneRef, GrantChip, GrantNeed, PaneState } from "./types";

// Holds one add-on pane's state on mock data: starts at the grant card for
// what the pane declares, Allow moves to the frame placeholder, Reload goes
// back through the same path. The wiring later replaces this state with the
// relay (addon_pane_add / addon_pane_loaded / port) and AddonPane stays as is.
export function AddonPaneHost(props: { pane: AddonPaneRef; onClose: () => void }) {
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
