import type { GrantChip, PaneState } from "./types";
import type { Translate } from "./model";
import { GrantCard, type GrantChoice } from "./GrantCard";
import { FailureCard, type FailureAction } from "./FailureCard";
import { LoadingView } from "../busy";

// The add-on pane (S5): a body that is the grant card (S6), a failure card, or
// the frame, and a status bar under it with the title, one chip per active
// grant, "asked by" when it was opened from a seat's request, ⟳ and ×. The bar
// is below the body, not a header, so it never looks like the app's own pane
// header above it. Reload is always in the bar. The frame itself is a placeholder until the relay is wired.

export function AddonPane(props: {
  t: Translate;
  title: string;
  chips: GrantChip[];
  askedBy?: string;
  /** When the host app already draws the pane title and × (the tab's pane header). */
  hideTitle?: boolean;
  hideClose?: boolean;
  /** Whether grants can be remembered ("Always for this folder"); false shows it disabled. */
  canRemember?: boolean;
  /** A grant is being asked of Rust: the card disables its choices. */
  pending?: boolean;
  /** Which choice of the grant card is running (it shows the spinner; the others are only disabled). */
  pendingChoice?: GrantChoice;
  /** Header badge for a developer pane, e.g. the folder. */
  devFolder?: string;
  /** A refusal the broker just returned, shown briefly in the header. */
  blocked?: string;
  /** Closes the refusal notice (the host also clears it after a few seconds). */
  onClearBlocked?: () => void;
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
      <div className="addon-pane-body">
        {state.kind === "grant" && <GrantCard t={t} title={props.title} need={state.need} canRemember={props.canRemember} pending={props.pending} pendingChoice={props.pendingChoice} onChoose={props.onGrant} />}
        {state.kind === "failure" && (
          <FailureCard t={t} title={props.title} failure={state.failure} onAction={props.onFailure} />
        )}
        {state.kind === "frame" && (props.frame ?? <div className="addon-frame-placeholder"><LoadingView text={t("addons.pane.opening", { title: props.title })} /></div>)}
      </div>
      <div className="addon-pane-status">
        {!props.hideTitle && <span className="addon-pane-title">{props.title}</span>}
        {props.devFolder && <span className="addon-badge" title={t("addons.pane.dev", { folder: props.devFolder })}>{t("addons.pane.dev", { folder: props.devFolder })}</span>}
        {props.chips.map((c) => (
          <span key={c.key} className="addon-chip" title={c.note ? `${c.label} · ${c.note}` : c.label}>
            {c.label}
            {c.note && <span className="addon-chip-note"> · {c.note}</span>}
          </span>
        ))}
        {props.askedBy && <span className="addon-asked-by" title={t("addons.pane.askedBy", { agent: props.askedBy })}>{t("addons.pane.askedBy", { agent: props.askedBy })}</span>}
        {props.blocked && (
          <span className="addon-blocked">
            <span className="addon-blocked-text" title={t("addons.pane.blocked", { what: props.blocked })}>
              {t("addons.pane.blocked", { what: props.blocked })}
            </span>
            {props.onClearBlocked && (
              <button type="button" className="addon-blocked-close" title={t("addons.request.close")} aria-label={t("addons.request.close")} onClick={props.onClearBlocked}>
                ×
              </button>
            )}
          </span>
        )}
        <span className="addon-pane-status-fill" />
        <button type="button" className="addon-pane-status-btn" title={t("addons.pane.reload")} aria-label={t("addons.pane.reload")} onClick={props.onReload}>
          ⟳
        </button>
        {!props.hideClose && (
          <button type="button" className="addon-pane-status-btn" title={t("pane.closeTitle")} aria-label={t("pane.closeTitle")} onClick={props.onClose}>
            ×
          </button>
        )}
      </div>
    </div>
  );
}
