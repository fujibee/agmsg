import type { GrantNeed } from "./types";
import type { Translate } from "./model";
import { BusyButton } from "../busy";
import type { FolderTrust } from "./source";

// S6: the grant card inside the pane (not a modal; the rest of the app stays
// usable). Messages: Allow / Not now. Files: Allow once / Always for this
// folder / Not now. A denied path is refused in the card, with no Allow.

export type GrantChoice = "allow" | "once" | "always" | "notNow";

/** The opt-in to trust ~/agmsg-agents in Claude Code, shown with the agents:spawn grant. `state` null = not read yet. */
export type TrustOption = { state: FolderTrust | null; checked: boolean; onChange: (on: boolean) => void };

export function GrantCard(props: {
  t: Translate;
  title: string;
  need: GrantNeed;
  onChoose: (choice: GrantChoice) => void;
  /** False until grants persist: "Always" is shown disabled, never accepted and treated as "once". */
  canRemember?: boolean;
  /** A grant call or the folder dialog is running: every choice is disabled until it ends. */
  pending?: boolean;
  /** The choice that started the running call: its button shows the spinner. */
  pendingChoice?: GrantChoice;
  /** Only given with agents:spawn. */
  trust?: TrustOption;
}) {
  const { t, title, need, onChoose } = props;
  const canRemember = props.canRemember ?? true;
  const pending = props.pending ?? false;
  const spin = (c: GrantChoice) => pending && props.pendingChoice === c;
  if (need.permission === "messages:read") {
    return (
      <div className="addon-card addon-grant-card" role="group" aria-label={t("addons.card.grantAria")}>
        <p>{t("addons.card.messagesWant", { title, team: need.team })}</p>
        {need.why && <p className="addon-why">{need.why}</p>}
        <div className="addon-card-actions">
          <BusyButton type="button" disabled={pending} busy={spin("allow")} onClick={() => onChoose("allow")}>
            {t("addons.card.allow")}
          </BusyButton>
          <BusyButton type="button" disabled={pending} busy={spin("notNow")} onClick={() => onChoose("notNow")}>
            {t("addons.card.notNow")}
          </BusyButton>
        </div>
      </div>
    );
  }
  if (need.permission === "powers") {
    const rows = ["teamJoin", ...(need.send ? ["messagesSend"] : []), ...(need.spawn ? ["agentsSpawn"] : [])];
    return (
      <div className="addon-card addon-grant-card" role="group" aria-label={t("addons.card.grantAria")}>
        <p>{t("addons.card.powersWant", { title, team: need.team })}</p>
        <ul className="addon-powers">
          {rows.map((r) => (
            <li key={r}>{t(`addons.permission.${r}`)}</li>
          ))}
        </ul>
        {need.why && <p className="addon-why">{need.why}</p>}
        {(need.send || need.spawn) && (
          <>
            <p className="addon-never">{t("addons.confirm.agentsBody")}</p>
            {need.spawn && <p className="addon-never">{t("addons.confirm.agentsMode")}</p>}
            {need.spawn && <p className="addon-never">{t("addons.confirm.agentsFolder")}</p>}
          </>
        )}
        {need.spawn && props.trust && <TrustRow t={t} trust={props.trust} pending={pending} />}
        <div className="addon-card-actions">
          <BusyButton type="button" disabled={pending} busy={spin("allow")} onClick={() => onChoose("allow")}>
            {t("addons.card.allow")}
          </BusyButton>
          <BusyButton type="button" disabled={pending} busy={spin("notNow")} onClick={() => onChoose("notNow")}>
            {t("addons.card.notNow")}
          </BusyButton>
        </div>
      </div>
    );
  }
  if (need.denied) {
    return (
      <div className="addon-card addon-grant-card denied" role="alert">
        <p>{t("addons.card.denied", { path: need.path })}</p>
        <div className="addon-card-actions">
          <BusyButton type="button" disabled={pending} busy={spin("notNow")} onClick={() => onChoose("notNow")}>
            {t("addons.card.chooseAnother")}
          </BusyButton>
        </div>
      </div>
    );
  }
  return (
    <div className="addon-card addon-grant-card" role="group" aria-label={t("addons.card.grantAria")}>
      <p>
        {need.fileCount === null
          ? t("addons.card.filesWantOne", { title, path: need.path })
          : t("addons.card.filesWant", { title, path: need.path, count: need.fileCount })}
      </p>
      {need.why && <p className="addon-why">{need.why}</p>}
      <div className="addon-card-actions">
        <BusyButton type="button" disabled={pending} busy={spin("once")} onClick={() => onChoose("once")}>
          {t("addons.card.allowOnce")}
        </BusyButton>
        <BusyButton
          type="button"
          busy={spin("always")}
          disabled={!canRemember || pending}
          title={canRemember ? undefined : t("addons.card.allowAlwaysLater")}
          onClick={() => onChoose("always")}
        >
          {t("addons.card.allowAlways")}
        </BusyButton>
        <BusyButton type="button" disabled={pending} busy={spin("notNow")} onClick={() => onChoose("notNow")}>
          {t("addons.card.notNow")}
        </BusyButton>
      </div>
    </div>
  );
}

function TrustRow(props: { t: Translate; trust: TrustOption; pending: boolean }) {
  const { t, trust } = props;
  if (trust.state === "trusted") return <p className="addon-trust-state">{t("addons.trust.trusted")}</p>;
  if (trust.state === "config not found") return <p className="addon-trust-state">{t("addons.trust.notFound")}</p>;
  if (trust.state === null) return null;
  return (
    <label className="addon-trust">
      <input type="checkbox" checked={trust.checked} disabled={props.pending} onChange={(e) => trust.onChange(e.target.checked)} />
      <span>
        {t("addons.trust.label")}
        <small className="addon-trust-note">{t("addons.trust.note")}</small>
      </span>
    </label>
  );
}
