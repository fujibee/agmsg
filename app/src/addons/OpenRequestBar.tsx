import type { BarItem, RowNote } from "./requests";
import { canOpen } from "./requests";
import type { Translate } from "./model";
import { useEffect, useState } from "react";
import { BusyButton } from "../busy";

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
  /** Clicks waiting for Rust: `open:<requestId>` / `dismiss:<requestId>`. */
  busy?: ReadonlySet<string>;
  onOpen: (i: BarItem) => void;
  onDismiss: (i: BarItem) => void;
  onInstall: (target: string) => void;
}) {
  const { t, item } = props;
  const opening = props.busy?.has(`open:${item.requestId}`) ?? false;
  const dismissing = props.busy?.has(`dismiss:${item.requestId}`) ?? false;
  const working = opening || dismissing; // one click at a time on a row
  return (
    <div className={`addon-request addon-request-${item.status}`} role="status">
      <span className="addon-request-text">{describe(t, item)}</span>
      {item.status !== "open" && <span className="addon-request-why">{item.detail ?? t(`addons.request.status.${item.status}`, { pane: item.pane })}</span>}
      {item.status === "not_installed" && item.installTarget && (
        <button type="button" onClick={() => props.onInstall(item.installTarget!)}>
          {t("addons.request.install")}
        </button>
      )}
      <BusyButton type="button" busy={opening} disabled={!canOpen(item) || working} onClick={() => props.onOpen(item)}>
        {t("addons.request.open")}
      </BusyButton>
      <BusyButton type="button" busy={dismissing} disabled={working} onClick={() => props.onDismiss(item)}>
        {t("addons.request.dismiss")}
      </BusyButton>
    </div>
  );
}

export function OpenRequestBar(props: {
  t: Translate;
  items: BarItem[];
  busy?: ReadonlySet<string>;
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
export function OpenRequestNotes(props: { t: Translate; notes: { requestId: string; note: RowNote }[]; busy?: ReadonlySet<string>; onDismiss: (requestId: string) => void }) {
  const { t, notes } = props;
  if (notes.length === 0) return null;
  const lines = notes.map(({ requestId, note }) => (
    <div key={requestId} className="addon-request-note addon-request-note-malformed" role="status">
      {t("addons.request.note.malformed", {
        reason: t(`addons.request.reason.${note.reason}`),
        detail: note.detail ? `: ${note.detail}` : "",
      })}{" "}
      <BusyButton type="button" busy={props.busy?.has(`dismiss:${requestId}`)} onClick={() => props.onDismiss(requestId)}>
        {t("addons.request.dismiss")}
      </BusyButton>
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

/** How long a one-off message (a refused click) stays before it goes away on its own. */
export const NOTICE_MS = 6000;

type Line = { key: string; text: string; sticky: boolean };

/** The lines to show: a dismissed one is hidden until its condition has gone away and come back. */
export function messageLines(props: { t: Translate; error: string | null; actionError: { code: string; message: string } | null; notice?: string; truncated?: boolean }): Line[] {
  const { t } = props;
  const lines: Line[] = [];
  if (props.error) lines.push({ key: "readFailed", text: t("addons.request.readFailed", { message: props.error }), sticky: true });
  if (props.notice) lines.push({ key: "notice", text: props.notice, sticky: true });
  if (props.truncated) lines.push({ key: "truncated", text: t("addons.request.truncated"), sticky: true });
  if (props.actionError) lines.push({ key: "actionFailed", text: t("addons.request.actionFailed", { message: props.actionError.message }), sticky: false });
  return lines;
}

/**
 * What the real rows can say besides the bar: the read failed (no bar, no Open),
 * the host explains why there is nothing to show, older requests were left out,
 * or the last click was refused. Rust's own words are shown as they are.
 * Every line has a ×. A refused click was a one-off, so it also goes after a few
 * seconds; a line about a state that still holds (the read keeps failing) stays
 * until it is closed, because it vanishing on its own would hide a problem that is still there.
 */
export function OpenRequestMessages(props: {
  t: Translate;
  error: string | null;
  actionError: { code: string; message: string } | null;
  /** Clears the refused-click message (it goes after NOTICE_MS, or on ×). */
  onClearAction?: () => void;
  notice?: string;
  truncated?: boolean;
}) {
  const { t } = props;
  const lines = messageLines(props);
  const [closed, setClosed] = useState<Record<string, string>>({});
  const { actionError, onClearAction } = props;
  useEffect(() => {
    if (!actionError || !onClearAction) return;
    const id = setTimeout(onClearAction, NOTICE_MS);
    return () => clearTimeout(id);
  }, [actionError, onClearAction]);
  // A line closed by hand stays closed while it says the same thing; if its condition clears, it may show again later.
  const present = lines.map((l) => `${l.key}\n${l.text}`).join("\u0000");
  useEffect(() => {
    setClosed((c) => {
      const keep = Object.fromEntries(Object.entries(c).filter(([k, v]) => lines.some((l) => l.key === k && l.text === v)));
      return Object.keys(keep).length === Object.keys(c).length ? c : keep;
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [present]);
  const shown = lines.filter((l) => closed[l.key] !== l.text);
  if (shown.length === 0) return null;
  return (
    <div className="addon-request-notes">
      {shown.map((l) => (
        <div key={l.key} className="addon-request-note" role="status">
          <span className="addon-request-note-text">{l.text}</span>
          <button
            type="button"
            className="addon-request-note-close"
            title={t("addons.request.close")}
            aria-label={t("addons.request.close")}
            onClick={() => (l.key === "actionFailed" ? onClearAction?.() : setClosed((c) => ({ ...c, [l.key]: l.text })))}
          >
            ×
          </button>
        </div>
      ))}
    </div>
  );
}
