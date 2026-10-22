import type { GrantChip, PaneState } from "./types";
import type { Translate } from "./model";
import { GrantCard, type GrantChoice } from "./GrantCard";
import { FailureCard, type FailureAction } from "./FailureCard";

// The add-on pane (S5): a header with the title, one chip per active grant,
// "asked by" when it was opened from a seat's request, ⟳ and ×; and a body
// that is the grant card (S6), a failure card, or the frame. Reload is always
// in the header. The frame itself is a placeholder until the relay is wired.

export function AddonPane(props: {
  t: Translate;
  title: string;
  chips: GrantChip[];
  askedBy?: string;
  /** When the host app already draws the pane title and × (the tab's pane header). */
  hideTitle?: boolean;
  hideClose?: boolean;
  /** Header badge for a developer pane, e.g. the folder. */
  devFolder?: string;
  /** A refusal the broker just returned, shown briefly in the header. */
  blocked?: string;
  state: PaneState;
  /** The iframe (or a placeholder) for state.kind === "frame". */
  frame?: React.ReactNode;
  onReload: () => void;
  onClose: () => void;
  onGrant: (c: GrantChoice) => void;
  onFailure: (a: FailureAction) => void;
}) {
  const { t, state } = props;
  return (
    <div className="addon-pane">
      <div className="pane-header addon-pane-header">
        {!props.hideTitle && <span className="addon-pane-title">{props.title}</span>}
        {props.devFolder && <span className="addon-badge">{t("addons.pane.dev", { folder: props.devFolder })}</span>}
        {props.chips.map((c) => (
          <span key={c.key} className="addon-chip">
            {c.label}
          </span>
        ))}
        {props.askedBy && <span className="addon-asked-by">{t("addons.pane.askedBy", { agent: props.askedBy })}</span>}
        {props.blocked && <span className="addon-blocked">{t("addons.pane.blocked", { what: props.blocked })}</span>}
        <button type="button" className="pane-header-close" title={t("addons.pane.reload")} aria-label={t("addons.pane.reload")} onClick={props.onReload}>
          ⟳
        </button>
        {!props.hideClose && (
          <button type="button" className="pane-header-close" title={t("pane.closeTitle")} aria-label={t("pane.closeTitle")} onClick={props.onClose}>
            ×
          </button>
        )}
      </div>
      <div className="addon-pane-body">
        {state.kind === "grant" && <GrantCard t={t} title={props.title} need={state.need} onChoose={props.onGrant} />}
        {state.kind === "failure" && (
          <FailureCard t={t} title={props.title} failure={state.failure} onAction={props.onFailure} />
        )}
        {state.kind === "frame" && (props.frame ?? <div className="addon-frame-placeholder">{t("addons.pane.framePlaceholder")}</div>)}
      </div>
    </div>
  );
}
