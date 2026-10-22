import type { PaneFailure } from "./types";
import type { Translate } from "./model";

// The in-pane failure table: a card saying what failed and the one next step,
// never a blank frame.

export type FailureAction = "reinstall" | "remove" | "reload" | "chooseAnother" | "allowAgain";

export function failureActions(f: PaneFailure): FailureAction[] {
  switch (f.code) {
    case "digest_mismatch":
      return ["reinstall", "remove"];
    case "load_timeout":
      return ["reload"];
    case "path_missing":
      return ["chooseAnother"];
    case "revoked":
      return ["allowAgain"];
  }
}

export function FailureCard(props: {
  t: Translate;
  title: string;
  failure: PaneFailure;
  onAction: (a: FailureAction) => void;
}) {
  const { t, title, failure } = props;
  const text =
    failure.code === "path_missing"
      ? t("addons.failure.path_missing", { path: failure.path })
      : failure.code === "revoked"
        ? t("addons.failure.revoked", { scope: failure.scope })
        : t(`addons.failure.${failure.code}`, { title });
  return (
    <div className="addon-card addon-failure-card" role="alert">
      <p>{text}</p>
      <div className="addon-card-actions">
        {failureActions(failure).map((a) => (
          <button key={a} type="button" onClick={() => props.onAction(a)}>
            {t(`addons.failure.action.${a}`)}
          </button>
        ))}
      </div>
    </div>
  );
}
