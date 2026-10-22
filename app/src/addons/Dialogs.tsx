import { Modal } from "../modals";
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
}) {
  const { t, staged } = props;
  const diff = staged.diff ?? (staged.from ? permissionDiff(staged.from.panes, staged.panes) : null);
  const perms = new Map<Permission, { panes: string[] }>();
  for (const pane of staged.panes) for (const p of pane.permissions) perms.set(p, { panes: [...(perms.get(p)?.panes ?? []), pane.name] });
  const net = addonNetwork({ panes: staged.panes } as InstalledAddon);
  const sends = staged.panes.some(canSendWhatItReads);
  const isNew = (p: Permission) => diff?.added.includes(p) || (p === "network" && diff?.networkWider) || false;
  return (
    <Modal title={t(diff ? "addons.confirm.updateTitle" : "addons.confirm.installTitle", { title: staged.title })} onClose={props.onCancel}>
      <p className="modal-note">
        {staged.addonId}{" "}
        {diff && staged.from
          ? t("addons.confirm.fromTo", { from: shortSha(staged.from.sha), to: shortSha(staged.sha) })
          : shortSha(staged.sha)}
      </p>
      <details className="addon-details">
        <summary>{t("addons.confirm.details")}</summary>
        <div>{t("addons.confirm.fullSha", { sha: staged.sha })}</div>
        <div>{t("addons.confirm.archive", { hash: staged.archiveSha256 })}</div>
      </details>
      <div className="addon-confirm-panes">{t("addons.confirm.panes", { names: staged.panes.map((p) => p.title).join(", ") })}</div>
      <div className="addon-confirm-can">{t("addons.confirm.canTitle")}</div>
      <ul className="addon-perms">
        {perms.size === 0 && <li>{t("addons.permission.none")}</li>}
        {[...perms.keys()].map((p) => {
          const row = permissionRow(p, net);
          const why = staged.panes.map((x) => x.why[p]).find(Boolean);
          return (
            <li key={p} className={isNew(p) ? "addon-perm-new" : ""}>
              {isNew(p) && <strong>{t("addons.confirm.new")} </strong>}
              {t(row.key, row.params)}
              {why && <span className="addon-why"> — {why}</span>}
            </li>
          );
        })}
      </ul>
      {sends && (
        <p className="modal-note addon-sends" role="note">
          {t(net.kind === "any" ? "addons.confirm.sendsAny" : "addons.confirm.sends", {
            hosts: net.kind === "origins" ? net.origins.map((o) => o.replace(/^https?:\/\//, "")).join(", ") : "",
          })}
        </p>
      )}
      <p className="modal-note">{t("addons.confirm.never")}</p>
      <p className="modal-note">{t("addons.confirm.noReview")}</p>
      {diff?.asksAgain && <p className="modal-note addon-asks-again">{t("addons.confirm.asksAgain")}</p>}
      <div className="modal-actions">
        <button type="button" autoFocus onClick={props.onCancel}>
          {t("common.cancel")}
        </button>
        <button type="button" onClick={props.onInstall}>
          {t(diff ? "addons.confirm.update" : "addons.confirm.install")}
        </button>
      </div>
    </Modal>
  );
}

/** S9. */
export function RemoveDialog(props: { t: Translate; title: string; openPanes: number; onRemove: () => void; onCancel: () => void }) {
  const { t } = props;
  return (
    <Modal title={t("addons.remove.title", { title: props.title })} onClose={props.onCancel}>
      <p className="modal-note">{t("addons.remove.body", { title: props.title, count: props.openPanes })}</p>
      <div className="modal-actions">
        <button type="button" autoFocus onClick={props.onCancel}>
          {t("common.cancel")}
        </button>
        <button type="button" className="primary danger" onClick={props.onRemove}>
          {t("addons.remove.confirm")}
        </button>
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
