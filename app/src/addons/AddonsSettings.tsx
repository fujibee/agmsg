import { SEAT_INSTRUCTION } from "./openRequests";
import { useState } from "react";
import type { AddonsSnapshot, EngineState, InstallError, InstalledAddon } from "./types";
import { declaredPermissions, addonNetwork, grantText, grantsOf, installErrorText, parseRepoInput, permissionRow, shortSha, type Translate } from "./model";

// Settings → Add-ons (S1, S4): built-in list, installed list with each add-on's
// grants and Revoke, the owner/repo input with Install, inline install errors,
// and a collapsed Developer section. Reads only AddonsSnapshot, so the wiring
// later swaps the source without touching this.

type Props = {
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
  /** False while Rust has no install pipeline: the input is shown disabled with a note instead of faking an install. */
  canInstall?: boolean;
  /** addon_list failed: shown with a retry instead of an empty list. */
  listError?: string;
  onRetryList?: () => void;
  /** A one-line result shown above the installed list: "Up to date (abc1234)." or a failure of check / remove / load. */
  notice?: { kind: "info" | "error"; text: string } | null;
  /** Reading the remembered grants failed: the list below may be missing rows, so say so with a retry. */
  grantsError?: string;
  onRetryGrants?: () => void;
  /** Developer copies get Reload and Remove here. */
  onDevReload?: (addonId: string) => void;
};

/** Copies the short instruction a seat needs to ask the app to open a pane. */
function CopyForSeats(props: { t: Props["t"] }) {
  const { t } = props;
  const [state, setState] = useState<"idle" | "copied" | "failed">("idle");
  return (
    <p className="addon-copy-seats">
      <button
        type="button"
        onClick={() => {
          navigator.clipboard.writeText(SEAT_INSTRUCTION).then(
            () => setState("copied"),
            () => setState("failed"),
          );
        }}
      >
        {t("addons.openRequests.copy")}
      </button>{" "}
      <span className="modal-note" role="status">
        {state === "copied" ? t("addons.openRequests.copied") : state === "failed" ? t("addons.openRequests.copyFailed") : t("addons.openRequests.copyHint")}
      </span>
    </p>
  );
}

export function AddonsSettings(props: Props) {
  const { t, snapshot, engine } = props;
  const canInstall = props.canInstall ?? true;
  const [input, setInput] = useState("");
  const parsed = parseRepoInput(input);
  const builtins = snapshot.addons.filter((a) => a.builtin);
  const installed = snapshot.addons.filter((a) => !a.builtin && !a.dev);
  const devs = snapshot.addons.filter((a) => a.dev);

  if (!engine.ok) {
    return (
      <div className="addons-settings">
        <Alerts {...props} />
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
      <Alerts {...props} />
      <section>
        <h3>{t("addons.builtin.title")}</h3>
        <ul className="addon-list">
          {builtins.map((a) => (
            <li key={a.id} className="addon-row">
              <span className="addon-name">{a.panes.map((p) => p.title).join(", ")}</span>
              {a.digestOk === false && <p className="addon-digest-bad" role="alert">{t("addons.failure.digest_mismatch", { title: a.panes[0]?.title ?? a.id })}</p>}
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
            disabled={!canInstall}
            onChange={(e) => setInput(e.target.value)}
          />
          <button type="submit" disabled={!parsed || !canInstall}>
            {t("addons.install.button")}
          </button>
        </form>
        {!canInstall && <p className="modal-note">{t("addons.install.later")}</p>}
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
        <CopyForSeats t={t} />
      </section>

      {canInstall && (
        <details className="addon-developer">
          <summary>{t("addons.developer.title")}</summary>
          <button type="button" onClick={props.onLoadFromFolder}>
            {t("addons.developer.loadFromFolder")}
          </button>
          <h4>{t("addons.developer.loaded")}</h4>
          {devs.length === 0 && <p className="modal-note">{t("addons.developer.none")}</p>}
          <ul className="addon-list">
            {devs.map((a) => (
              <li key={a.id} className="addon-row">
                <div className="addon-head">
                  <span className="addon-name">{a.panes.map((p) => p.title).join(", ")}</span>
                  <span className="addon-badge">{t("addons.pane.dev", { folder: a.dev?.label ?? a.id })}</span>
                </div>
                <PermissionList t={t} addon={a} />
                <div className="addon-actions">
                  <button type="button" onClick={() => props.onDevReload?.(a.id)}>
                    {t("addons.developer.reload")}
                  </button>
                  <button type="button" onClick={() => props.onRemove(a.id)}>
                    {t("addons.developer.remove")}
                  </button>
                </div>
              </li>
            ))}
          </ul>
        </details>
      )}
    </div>
  );
}

function Alerts(props: { t: Translate } & Pick<Props, "listError" | "onRetryList" | "grantsError" | "onRetryGrants" | "notice">) {
  const { t } = props;
  return (
    <>
      {props.listError !== undefined && (
        <p className="addon-list-error" role="alert">
          {t("addons.listFailed", { message: props.listError })}{" "}
          <button type="button" onClick={props.onRetryList}>
            {t("addons.listRetry")}
          </button>
        </p>
      )}
      {props.grantsError !== undefined && (
        <p className="addon-list-error" role="alert">
          {t("addons.grantsFailed", { message: props.grantsError })}{" "}
          <button type="button" onClick={props.onRetryGrants}>
            {t("addons.listRetry")}
          </button>
        </p>
      )}
      {props.notice && (
        <p className={`addon-notice ${props.notice.kind}`} role={props.notice.kind === "error" ? "alert" : "status"}>
          {props.notice.text}
        </p>
      )}
    </>
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
  canInstall?: boolean;
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
          {a.digestOk === false && <p className="addon-digest-bad" role="alert">{t("addons.failure.digest_mismatch", { title: a.panes[0]?.title ?? a.id })}</p>}
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
            {!props.readOnly && props.canInstall !== false && (
              <button type="button" onClick={() => props.onCheckUpdate(a.id)}>
                {t("addons.installed.checkUpdates")}
              </button>
            )}
            {props.canInstall !== false && (
              <button type="button" onClick={() => props.onRemove(a.id)}>
                {t("addons.installed.remove")}
              </button>
            )}
          </div>
        </li>
      ))}
    </ul>
  );
}
