import type { GrantNeed } from "./types";
import type { Translate } from "./model";

// S6: the grant card inside the pane (not a modal; the rest of the app stays
// usable). Messages: Allow / Not now. Files: Allow once / Always for this
// folder / Not now. A denied path is refused in the card, with no Allow.

export type GrantChoice = "allow" | "once" | "always" | "notNow";

export function GrantCard(props: {
  t: Translate;
  title: string;
  need: GrantNeed;
  onChoose: (choice: GrantChoice) => void;
  /** False until grants persist: "Always" is shown disabled, never accepted and treated as "once". */
  canRemember?: boolean;
}) {
  const { t, title, need, onChoose } = props;
  const canRemember = props.canRemember ?? true;
  if (need.permission === "messages:read") {
    return (
      <div className="addon-card addon-grant-card" role="group" aria-label={t("addons.card.grantAria")}>
        <p>{t("addons.card.messagesWant", { title, team: need.team })}</p>
        <div className="addon-card-actions">
          <button type="button" onClick={() => onChoose("allow")}>
            {t("addons.card.allow")}
          </button>
          <button type="button" onClick={() => onChoose("notNow")}>
            {t("addons.card.notNow")}
          </button>
        </div>
      </div>
    );
  }
  if (need.denied) {
    return (
      <div className="addon-card addon-grant-card denied" role="alert">
        <p>{t("addons.card.denied", { path: need.path })}</p>
        <div className="addon-card-actions">
          <button type="button" onClick={() => onChoose("notNow")}>
            {t("addons.card.chooseAnother")}
          </button>
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
      <div className="addon-card-actions">
        <button type="button" onClick={() => onChoose("once")}>
          {t("addons.card.allowOnce")}
        </button>
        <button
          type="button"
          disabled={!canRemember}
          title={canRemember ? undefined : t("addons.card.allowAlwaysLater")}
          onClick={() => onChoose("always")}
        >
          {t("addons.card.allowAlways")}
        </button>
        <button type="button" onClick={() => onChoose("notNow")}>
          {t("addons.card.notNow")}
        </button>
      </div>
    </div>
  );
}
