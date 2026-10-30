import { Modal } from "../modals";
import { BusyButton } from "../busy";
import type { FetchProgress, StagedInstall } from "./types";
import { addonNetwork, canSendWhatItReads, permissionDiff, permissionRow, shortSha, type Translate } from "./model";
import type { InstalledAddon, Permission } from "./types";

// S3 confirm (install), S8 confirm (update, with the difference highlighted),
// S9 remove, and S2 fetch progress. Install is never the default key: Cancel
// takes the initial focus and the Install button is never autofocused, never a
// form submit.

export function ConfirmInstallDialog(props: {
  t: Translate;
  staged: StagedInstall;
  onInstall: () => void;
  onCancel: () => void;
  /** The install is running: Install shows the spinner and both buttons wait. */
  busy?: boolean;
}) {
  const { t, staged } = props;
  const diff = staged.diff ?? (staged.from ? permissionDiff(staged.from.panes, staged.panes) : null);
  const perms = new Map<Permission, { panes: string[] }>();
  for (const pane of staged.panes) for (const p of pane.permissions) perms.set(p, { panes: [...(perms.get(p)?.panes ?? []), pane.name] });
  const net = addonNetwork({ panes: staged.panes } as InstalledAddon);
  const sends = staged.panes.some(canSendWhatItReads);
  const isNew = (p: Permission) => diff?.added.includes(p) || (p === "network" && diff?.networkWider) || false;
  return (
    <Modal title={t(diff ? "addons.confirm.updateTitle" : "addons.confirm.installTitle", { title: staged.title })} onClose={props.onCancel} wide busy={props.busy}>
      <div className="modal-body">
        <p className="addon-dlg-source">
          {diff && staged.from
            ? t("addons.confirm.sourceUpdate", { repo: staged.addonId, from: shortSha(staged.from.sha), to: shortSha(staged.sha), count: staged.panes.length })
            : t("addons.confirm.source", { repo: staged.addonId, sha: shortSha(staged.sha), count: staged.panes.length })}
        </p>
        <p className="addon-dlg-source addon-dlg-panes">{t("addons.confirm.panes", { names: staged.panes.map((p) => p.title).join(", ") })}</p>
        <div className="addon-block">
          <h4>{t("addons.confirm.canTitle")}</h4>
          {perms.size === 0 && <p className="addon-never">{t("addons.permission.none")}</p>}
          {[...perms.keys()].map((p) => {
            const row = permissionRow(p, net);
            const why = staged.panes.map((x) => x.why[p]).find(Boolean);
            return (
              <div key={p} className={`addon-perm-row${isNew(p) ? " addon-perm-new" : ""}`}>
                <span className="ico">◉</span>
                <b>
                  {isNew(p) && <>{t("addons.confirm.new")} </>}
                  {t(row.key, row.params)}
                </b>
                {why && <span className="addon-why">{why}</span>}
              </div>
            );
          })}
          {sends && (
            <p className="addon-never addon-sends" role="note">
              {t(net.kind === "any" ? "addons.confirm.sendsAny" : "addons.confirm.sends", {
                hosts: net.kind === "origins" ? net.origins.map((o) => o.replace(/^https?:\/\//, "")).join(", ") : "",
              })}
            </p>
          )}
        </div>
        <div className="addon-block">
          <h4>{t("addons.confirm.neverTitle")}</h4>
          <p className="addon-never">{t("addons.confirm.never")}</p>
        </div>
        {diff && <PaneChanges t={t} staged={staged} />}
        {diff?.asksAgain && <p className="addon-warn addon-asks-again">{t("addons.confirm.asksAgain")}</p>}
        <p className="addon-warn">{t("addons.confirm.noReview")}</p>
        <details className="addon-details">
          <summary>{t("addons.confirm.details")}</summary>
          <div>{t("addons.confirm.fullSha", { sha: staged.sha })}</div>
          <div>{t("addons.confirm.archive", { hash: staged.archiveSha256 })}</div>
        </details>
      </div>
      <div className="modal-actions">
        <button type="button" autoFocus disabled={props.busy} onClick={props.onCancel}>
          {t("common.cancel")}
        </button>
        <BusyButton type="button" className="primary" busy={props.busy} onClick={props.onInstall}>
          {t(diff ? "addons.confirm.update" : "addons.confirm.install")}
        </BusyButton>
      </div>
    </Modal>
  );
}

/** S9. */
export function RemoveDialog(props: { t: Translate; title: string; openPanes: number; onRemove: () => void; onCancel: () => void; busy?: boolean }) {
  const { t } = props;
  return (
    <Modal title={t("addons.remove.title", { title: props.title })} onClose={props.onCancel} busy={props.busy}>
      <p className="modal-note">{t("addons.remove.body", { title: props.title, count: props.openPanes })}</p>
      <div className="modal-actions">
        <button type="button" autoFocus disabled={props.busy} onClick={props.onCancel}>
          {t("common.cancel")}
        </button>
        <BusyButton type="button" className="primary danger" busy={props.busy} onClick={props.onRemove}>
          {t("addons.remove.confirm")}
        </BusyButton>
      </div>
    </Modal>
  );
}

/** S2: inline steps under the install input; Cancel deletes the staging directory. */
export function FetchProgressView(props: { t: Translate; progress: FetchProgress; onCancel: () => void }) {
  const { t, progress: p } = props;
  const text =
    p.step === "resolving"
      ? p.sha
        ? t("addons.fetch.resolved", { sha: shortSha(p.sha) })
        : t("addons.fetch.resolving")
      : p.step === "downloading"
        ? p.doneMb === undefined || p.totalMb === undefined
          ? t("addons.fetch.downloadingPlain")
          : t("addons.fetch.downloading", { done: p.doneMb, total: p.totalMb })
        : p.files === undefined || p.sizeMb === undefined
          ? t("addons.fetch.checkingPlain")
          : t("addons.fetch.checking", { files: p.files, size: p.sizeMb });
  return (
    <div className="addon-fetch" role="status">
      <span>{text}</span>{" "}
      <button type="button" onClick={props.onCancel}>
        {t("common.cancel")}
      </button>
    </div>
  );
}

/** The update's difference pane by pane: who gains what, and which panes lose their saved access. */
function PaneChanges(props: { t: Translate; staged: StagedInstall }) {
  const { t, staged } = props;
  const lines: string[] = [];
  for (const c of staged.paneChanges ?? []) {
    if (c.added.length > 0) lines.push(t("addons.confirm.paneAdds", { pane: c.pane, perms: c.added.join(", ") }));
    if (c.networkWidened) lines.push(t("addons.confirm.paneWider", { pane: c.pane }));
    if (c.networkNewlyCombined) lines.push(t("addons.confirm.paneCombined", { pane: c.pane }));
    if (c.networkWidened || c.networkNewlyCombined) lines.push(t("addons.confirm.paneAsksAgain", { pane: c.pane }));
  }
  for (const pane of staged.removedPanes ?? []) lines.push(t("addons.confirm.paneRemoved", { pane }));
  if (lines.length === 0) return null;
  return (
    <div className="addon-block addon-pane-changes">
      <h4>{t("addons.confirm.changesTitle")}</h4>
      <ul className="addon-perms">
        {lines.map((l, i) => (
          <li key={i}>{l}</li>
        ))}
      </ul>
    </div>
  );
}
