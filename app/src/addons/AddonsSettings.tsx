import { useState } from "react";
import type { AddonsSnapshot, EngineState, InstallError, InstalledAddon } from "./types";
import { declaredPermissions, addonNetwork, grantText, grantsOf, installErrorText, parseRepoInput, permissionRow, shortSha, type Translate } from "./model";

// Settings → Add-ons (S1, S4): built-in list, installed list with each add-on's
// grants and Revoke, the owner/repo input with Install, inline install errors,
// and a collapsed Developer section. Reads only AddonsSnapshot, so the wiring
// later swaps the source without touching this.

export function AddonsSettings(props: {
  t: Translate;
  snapshot: AddonsSnapshot;
  engine: EngineState;
  /** The last install attempt's failure, shown under the input; the input keeps its text. */
  installError: InstallError | null;
  onInstall: (input: { owner: string; repo: string; ref: string | null }) => void;
  onRevoke: (addonId: string, grantIndex: number) => void;
  onCheckUpdate: (addonId: string) => void;
  onRemove: (addonId: string) => void;
  onOpenRequestsChange: (v: "show" | "off") => void;
  onLoadFromFolder: () => void;
}) {
  const { t, snapshot, engine } = props;
  const [input, setInput] = useState("");
  const parsed = parseRepoInput(input);
  const builtins = snapshot.addons.filter((a) => a.builtin);
  const installed = snapshot.addons.filter((a) => !a.builtin);

  if (!engine.ok) {
    return (
      <div className="addons-settings">
        <p className="addon-engine-off" role="status">
          {t("addons.engineOff")}{" "}
          {engine.reasons.length > 0 && t("addons.engineReasons", { reasons: engine.reasons.join("; ") })}
        </p>
        <InstalledList {...props} installed={installed} readOnly />
      </div>
    );
  }

  return (
    <div className="addons-settings">
      <section>
        <h3>{t("addons.builtin.title")}</h3>
        <ul className="addon-list">
          {builtins.map((a) => (
            <li key={a.id} className="addon-row">
              <span className="addon-name">{a.panes.map((p) => p.title).join(", ")}</span>
              <PermissionList t={t} addon={a} />
            </li>
          ))}
        </ul>
      </section>

      <section>
        <h3>{t("addons.installed.title")}</h3>
        <InstalledList {...props} installed={installed} />
        <form
          className="addon-install-form"
          onSubmit={(e) => {
            e.preventDefault();
            if (parsed) props.onInstall(parsed);
          }}
        >
          <input
            type="text"
            value={input}
            placeholder={t("addons.install.placeholder")}
            aria-label={t("addons.install.label")}
            onChange={(e) => setInput(e.target.value)}
          />
          <button type="submit" disabled={!parsed}>
            {t("addons.install.button")}
          </button>
        </form>
        {props.installError && (
          <div className="addon-install-error" role="alert">
            {(() => {
              const m = installErrorText(props.installError);
              return t(m.key, m.params);
            })()}
          </div>
        )}
      </section>

      <section>
        <label className="addon-open-requests">
          {t("addons.openRequests.label")}
          <select
            value={snapshot.openRequests}
            onChange={(e) => props.onOpenRequestsChange(e.target.value === "off" ? "off" : "show")}
          >
            <option value="show">{t("addons.openRequests.show")}</option>
            <option value="off">{t("addons.openRequests.off")}</option>
          </select>
        </label>
      </section>

      <details className="addon-developer">
        <summary>{t("addons.developer.title")}</summary>
        <button type="button" onClick={props.onLoadFromFolder}>
          {t("addons.developer.loadFromFolder")}
        </button>
      </details>
    </div>
  );
}

function PermissionList(props: { t: Translate; addon: InstalledAddon }) {
  const { t, addon } = props;
  const network = addonNetwork(addon);
  const perms = declaredPermissions(addon);
  if (perms.length === 0) return <span className="addon-perms none">{t("addons.permission.none")}</span>;
  return (
    <ul className="addon-perms">
      {perms.map((p) => {
        const row = permissionRow(p, network);
        return <li key={p}>{t(row.key, row.params)}</li>;
      })}
    </ul>
  );
}

function InstalledList(props: {
  t: Translate;
  snapshot: AddonsSnapshot;
  installed: InstalledAddon[];
  readOnly?: boolean;
  onRevoke: (addonId: string, grantIndex: number) => void;
  onCheckUpdate: (addonId: string) => void;
  onRemove: (addonId: string) => void;
}) {
  const { t, installed, snapshot } = props;
  if (installed.length === 0) return <p className="modal-note">{t("addons.installed.empty")}</p>;
  return (
    <ul className="addon-list">
      {installed.map((a) => (
        <li key={a.id} className="addon-row">
          <div className="addon-head">
            <span className="addon-name">{a.panes.map((p) => p.title).join(", ")}</span>
            <span className="addon-meta">
              {a.id} · {shortSha(a.sha)} · {a.installedAt.slice(0, 10)}
            </span>
          </div>
          <PermissionList t={t} addon={a} />
          <ul className="addon-grants">
            {snapshot.grants.map((g, i) =>
              g.addonId === a.id ? (
                <li key={i}>
                  {grantText(t, g)}{" "}
                  <button type="button" onClick={() => props.onRevoke(a.id, i)}>
                    {t("addons.grant.revoke")}
                  </button>
                </li>
              ) : null,
            )}
            {grantsOf(snapshot.grants, a.id).length === 0 && <li className="none">{t("addons.grant.none")}</li>}
          </ul>
          <div className="addon-actions">
            {!props.readOnly && (
              <button type="button" onClick={() => props.onCheckUpdate(a.id)}>
                {t("addons.installed.checkUpdates")}
              </button>
            )}
            <button type="button" onClick={() => props.onRemove(a.id)}>
              {t("addons.installed.remove")}
            </button>
          </div>
        </li>
      ))}
    </ul>
  );
}
