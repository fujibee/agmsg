import type { BarItem, RowNote } from "./requests";
import { canOpen } from "./requests";
import type { Translate } from "./model";

// S10: the bar at the top of the team's tab. One request is a single line with
// Open / Dismiss; several collapse into "N open requests ▾". Refused states
// keep the line but take the Open button away and say why. Nothing opens
// without the click.

function describe(t: Translate, item: BarItem): string {
  return t("addons.request.wants", {
    agent: item.from,
    team: item.team,
    target: `${item.addonId} ${item.pane}`,
    args: item.path ? `: ${item.path}` : "",
  });
}

function Row(props: {
  t: Translate;
  item: BarItem;
  formatTime: (iso: string) => string;
  onOpen: (i: BarItem) => void;
  onDismiss: (i: BarItem) => void;
  onInstall: (target: string) => void;
}) {
  const { t, item } = props;
  return (
    <div className={`addon-request addon-request-${item.status}`} role="status">
      <span className="addon-request-text">{describe(t, item)}</span>
      <span className="addon-request-time">{props.formatTime(item.at)}</span>
      <span className="addon-request-unverified">{t("addons.request.unverified")}</span>
      {item.status !== "open" && <span className="addon-request-why">{item.detail ?? t(`addons.request.status.${item.status}`, { pane: item.pane })}</span>}
      {item.status === "not_installed" && item.installTarget && (
        <button type="button" onClick={() => props.onInstall(item.installTarget!)}>
          {t("addons.request.install")}
        </button>
      )}
      <button type="button" disabled={!canOpen(item)} onClick={() => props.onOpen(item)}>
        {t("addons.request.open")}
      </button>
      <button type="button" onClick={() => props.onDismiss(item)}>
        {t("addons.request.dismiss")}
      </button>
    </div>
  );
}

export function OpenRequestBar(props: {
  t: Translate;
  items: BarItem[];
  formatTime: (iso: string) => string;
  onOpen: (i: BarItem) => void;
  onDismiss: (i: BarItem) => void;
  onInstall: (target: string) => void;
}) {
  const { t, items } = props;
  if (items.length === 0) return null;
  const rows = items.map((item) => <Row key={item.requestId} {...props} item={item} />);
  if (items.length === 1) return <div className="addon-request-bar">{rows}</div>;
  return (
    <details className="addon-request-bar">
      <summary>{t("addons.request.many", { count: items.length })}</summary>
      {rows}
    </details>
  );
}

/**
 * Notes for lines that start like a request but cannot be read: each is shown
 * with the reason it was refused and can be dismissed, so it does not stay
 * forever. Nothing here has an Open button; nothing fails silently.
 */
export function OpenRequestNotes(props: { t: Translate; notes: { requestId: string; note: RowNote }[]; onDismiss: (requestId: string) => void }) {
  const { t, notes } = props;
  if (notes.length === 0) return null;
  const lines = notes.map(({ requestId, note }) => (
    <div key={requestId} className="addon-request-note addon-request-note-malformed" role="status">
      {t("addons.request.note.malformed", {
        reason: t(`addons.request.reason.${note.reason}`),
        detail: note.detail ? `: ${note.detail}` : "",
      })}{" "}
      <button type="button" onClick={() => props.onDismiss(requestId)}>
        {t("addons.request.dismiss")}
      </button>
    </div>
  ));
  if (notes.length === 1) return <div className="addon-request-notes">{lines}</div>;
  return (
    <details className="addon-request-notes">
      <summary>{t("addons.request.notes", { count: notes.length })}</summary>
      {lines}
    </details>
  );
}

/**
 * What the real rows can say besides the bar: the read failed (no bar, no Open),
 * the host explains why there is nothing to show, older requests were left out,
 * or the last click was refused. Rust's own words are shown as they are.
 */
export function OpenRequestMessages(props: {
  t: Translate;
  error: string | null;
  actionError: { code: string; message: string } | null;
  notice?: string;
  truncated?: boolean;
}) {
  const { t } = props;
  const lines: string[] = [];
  if (props.error) lines.push(t("addons.request.readFailed", { message: props.error }));
  if (props.notice) lines.push(props.notice);
  if (props.truncated) lines.push(t("addons.request.truncated"));
  if (props.actionError) lines.push(t("addons.request.actionFailed", { message: props.actionError.message }));
  if (lines.length === 0) return null;
  return (
    <div className="addon-request-notes">
      {lines.map((l, i) => (
        <div key={i} className="addon-request-note" role="status">
          {l}
        </div>
      ))}
    </div>
  );
}
