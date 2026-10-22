import type { BarItem } from "./requests";
import { canOpen } from "./requests";
import type { Translate } from "./model";

// S10: the bar at the top of the team's tab. One request is a single line with
// Open / Dismiss; several collapse into "N open requests ▾". Refused states
// keep the line but take the Open button away and say why. Nothing opens
// without the click.

function describe(t: Translate, item: BarItem): string {
  const { path, url, base } = item.request.args;
  const what = path ?? url ?? "";
  const parts = [what, base ? t("addons.request.base", { base }) : ""].filter(Boolean).join(", ");
  return t("addons.request.wants", { agent: item.from, pane: item.pane, args: parts });
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
      {item.status !== "open" && <span className="addon-request-why">{t(`addons.request.status.${item.status}`, { pane: item.pane })}</span>}
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
