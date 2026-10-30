import { seatInstruction } from "./openRequests";
import { useEffect, useState } from "react";
import type { ReactNode } from "react";
import type { AddonsSnapshot, EngineState, InstallError, InstalledAddon } from "./types";
import { declaredPermissions, addonNetwork, grantText, grantsOf, installErrorText, parseRepoInput, permissionRow, shortSha, type Translate } from "./model";
import { isChecking, offersRecheck } from "./recheck";
import { BusyButton } from "../busy";

// Settings → Add-ons (S1, S4). One intro line, the install field, then
// collapsible groups: Installed, Built in, Requests from agents, Developer.
// Every group is a <Group> and every add-on a <AddonCard>, so reordering or
// reshaping the screen is a change in this file's JSX, not in the pieces.
// Reads only AddonsSnapshot, so the wiring swaps the source without touching this.

/** What the green notice after an install or update says, and what "Open now" opens. */
export type InstalledNotice = { kind: "installed" | "updated"; addonId: string; title: string; paneName?: string };

/** What "Open now" opens: the first pane of the add-on just installed, or nothing when it declared none. */
export const openNowRef = (n: InstalledNotice) => (n.paneName === undefined ? null : { addonId: n.addonId, paneName: n.paneName, title: n.title });

type Props = {
  t: Translate;
  snapshot: AddonsSnapshot;
  engine: EngineState;
  /** The last install attempt's failure, shown under the input; the input keeps its text. */
  installError: InstallError | null;
  onInstall: (input: { owner: string; repo: string; ref: string | null }) => void;
  onRevoke: (addonId: string, grantIndex: number) => void;
  onCheckUpdate: (addonId: string) => void;
  onRemove: (addonId: string) => void;
  onOpenRequestsChange: (v: "show" | "off") => void;
  onLoadFromFolder: () => void;
  /** What is waiting for Rust: `install`, `load`, `grants`, `reload:<addonId>`, `check:<addonId>`, `revoke:<addonId>:<n>`. */
  busy?: ReadonlySet<string>;
  /** False while Rust has no install pipeline: the input is shown disabled with a note instead of faking an install. */
  canInstall?: boolean;
  /** addon_list failed: shown with a retry instead of an empty list. */
  listError?: string;
  onRetryList?: () => void;
  /** A one-line result shown above the installed list: "Up to date (abc1234)." or a failure of check / remove / load. */
  notice?: { kind: "info" | "error"; text: string } | null;
  /** Reading the remembered grants failed: the list below may be missing rows, so say so with a retry. */
  grantsError?: string;
  onRetryGrants?: () => void;
  /** Developer copies get Reload and Remove here. */
  onDevReload?: (addonId: string) => void;
  /** Set right after an install or update: the green notice, and the card of that add-on outlined green. */
  installedNotice?: InstalledNotice | null;
  /** "Open now": opens the add-on's first pane through the normal grant flow. */
  onOpenNow?: (notice: InstalledNotice) => void;
  /** The team on screen and its app user, for the text copied for agents. */
  seat?: SeatContext;
  /** "Check again" on the engine-off screen: runs the startup check once more. */
  onRecheck?: () => void;
};

/** The switch flips the stored Show/Off setting; the stored values are unchanged. */
export const nextOpenRequests = (current: "show" | "off"): "show" | "off" => (current === "off" ? "show" : "off");

/** Where the copy button takes the instruction's names from: the team on screen, its app user, and the scripts folder in use. */
export type SeatContext = { team: string; appUser: string; scriptsDir: string };

/** Copies the instruction an agent needs to ask the app to open a pane; says why when it cannot be filled in for a team. */
function CopyForAgents(props: { t: Translate; seat?: SeatContext }) {
  const { t } = props;
  const [state, setState] = useState<"idle" | "copied" | "failed" | "noTeam" | "noAppUser" | "noScripts">("idle");
  return (
    <div className="addon-row-line">
      <button
        type="button"
        className="addon-btn"
        onClick={() => {
          const made = seatInstruction(t, props.seat ?? { team: "", appUser: "", scriptsDir: "" });
          if (!made.ok) return setState(made.reason);
          navigator.clipboard.writeText(made.text).then(
            () => setState("copied"),
            () => setState("failed"),
          );
        }}
      >
        {t("addons.openRequests.copy")}
      </button>
      <span className={`addon-copy-state ${state}`} role="status">
        {state === "idle" ? "" : state === "copied" ? t("addons.openRequests.copied") : state === "failed" ? t("addons.openRequests.copyFailed") : t(`addons.openRequests.copy${state[0].toUpperCase()}${state.slice(1)}`)}
      </span>
    </div>
  );
}

/** A collapsible group with a count (or a short state word) next to its title. */
function Group(props: { id: string; title: string; badge?: string | number; defaultOpen?: boolean; problems?: number; t: Translate; children: ReactNode }) {
  const problems = props.problems ?? 0;
  // A failure inside the group must not hide behind a closed heading: the group opens by itself and the summary says so.
  return (
    <details className={`addon-group addon-group-${props.id}${problems > 0 ? " has-problem" : ""}`} open={props.defaultOpen || problems > 0}>
      <summary>
        <span className="addon-group-title">{props.title}</span>
        {props.badge !== undefined && <span className="addon-count">{props.badge}</span>}
        {problems > 0 && <span className="addon-problem">{props.t("addons.group.problems", { count: problems })}</span>}
      </summary>
      <div className="addon-group-body">{props.children}</div>
    </details>
  );
}

export function AddonsSettings(props: Props) {
  const { t, snapshot, engine } = props;
  const canInstall = props.canInstall ?? true;
  const [input, setInput] = useState("");
  const parsed = parseRepoInput(input);
  const builtins = snapshot.addons.filter((a) => a.builtin);
  const installed = snapshot.addons.filter((a) => !a.builtin && !a.dev);
  const devs = snapshot.addons.filter((a) => a.dev);
  const bad = (list: InstalledAddon[]) => list.filter((a) => a.digestOk === false).length;
  const newId = props.installedNotice?.addonId;
  // A finished install empties the field, so the next one starts blank.
  const installedKey = props.installedNotice?.kind === "installed" ? props.installedNotice.addonId : null;
  useEffect(() => {
    if (installedKey) setInput("");
  }, [installedKey]);

  if (!engine.ok) {
    return (
      <div className="addons-settings">
        <Alerts {...props} />
        <p className="addon-engine-off" role="status">
          {t("addons.engineOff")}{" "}
          {isChecking(engine.reasons)
            ? t("addons.checking")
            : engine.reasons.length > 0 && t("addons.engineReasons", { reasons: engine.reasons.join("; ") })}
        </p>
        {(offersRecheck(engine.reasons) || isChecking(engine.reasons)) && props.onRecheck && (
          <BusyButton type="button" className="addon-btn" busy={isChecking(engine.reasons)} onClick={() => props.onRecheck?.()}>
            {t("addons.checkAgain")}
          </BusyButton>
        )}
        <Group id="installed" t={t} problems={bad(installed)} title={t("addons.installed.title")} badge={installed.length} defaultOpen>
          <InstalledList {...props} installed={installed} readOnly />
        </Group>
      </div>
    );
  }

  return (
    <div className="addons-settings">
      <p className="addon-intro">{t("addons.intro")}</p>
      <Alerts {...props} />
      {props.installedNotice && (
        <div className="addon-toast" role="status">
          <span>{t(props.installedNotice.kind === "updated" ? "addons.installed.updatedNotice" : "addons.installed.doneNotice", { title: props.installedNotice.title })}</span>
          {props.installedNotice.paneName !== undefined && props.onOpenNow && (
            <button type="button" className="addon-btn" onClick={() => props.onOpenNow?.(props.installedNotice as InstalledNotice)}>
              {t("addons.installed.openNow")}
            </button>
          )}
        </div>
      )}

      <form
        className="addon-install-form"
        onSubmit={(e) => {
          e.preventDefault();
          if (parsed) props.onInstall(parsed);
        }}
      >
        <label htmlFor="addon-install-input">{t("addons.install.heading")}</label>
        <p className="addon-help">{t("addons.install.help")}</p>
        <div className="addon-row-line">
          <input
            id="addon-install-input"
            type="text"
            value={input}
            placeholder={t("addons.install.placeholder")}
            disabled={!canInstall}
            onChange={(e) => setInput(e.target.value)}
          />
          <BusyButton type="submit" className="addon-btn primary" busy={props.busy?.has("install")} disabled={!parsed || !canInstall}>
            {t("addons.install.button")}
          </BusyButton>
        </div>
        {!canInstall && <p className="addon-help">{t("addons.install.later")}</p>}
        {props.installError && (
          <div className="addon-install-error" role="alert">
            {(() => {
              const m = installErrorText(props.installError);
              return t(m.key, m.params);
            })()}
          </div>
        )}
      </form>

      <Group id="installed" t={t} problems={bad(installed)} title={t("addons.installed.title")} badge={installed.length} defaultOpen>
        <InstalledList {...props} installed={installed} newId={newId} />
      </Group>

      <Group id="builtin" t={t} problems={bad(builtins)} title={t("addons.builtin.title")} badge={builtins.length}>
        <ul className="addon-list">
          {builtins.map((a) => (
            <AddonCard key={a.id} t={t} addon={a} snapshot={snapshot} busy={props.busy} source={t("addons.builtin.source")} onRevoke={props.onRevoke} />
          ))}
        </ul>
      </Group>

      <Group id="requests" t={t} title={t("addons.openRequests.title")} badge={t(snapshot.openRequests === "off" ? "addons.openRequests.off" : "addons.openRequests.on")}>
        <div className="addon-switch-line">
          <p className="addon-help addon-help-main">{t("addons.openRequests.explain")}</p>
          <button
            type="button"
            role="switch"
            aria-checked={snapshot.openRequests !== "off"}
            aria-label={t("addons.openRequests.title")}
            className="addon-switch"
            onClick={() => props.onOpenRequestsChange(nextOpenRequests(snapshot.openRequests))}
          />
        </div>
        <p className="addon-help">{t("addons.openRequests.copyHelp")}</p>
        <CopyForAgents t={t} seat={props.seat} />
      </Group>

      {canInstall && (
        <Group id="developer" t={t} problems={bad(devs)} title={t("addons.developer.title")} badge={devs.length > 0 ? devs.length : undefined}>
          <p className="addon-help">{t("addons.developer.explain")}</p>
          <div className="addon-row-line">
            <BusyButton type="button" className="addon-btn" busy={props.busy?.has("load")} onClick={props.onLoadFromFolder}>
              {t("addons.developer.loadFromFolder")}
            </BusyButton>
          </div>
          {devs.length === 0 && <p className="addon-help">{t("addons.developer.none")}</p>}
          <ul className="addon-list">
            {devs.map((a) => (
              <AddonCard
                key={a.id}
                t={t}
                addon={a}
                snapshot={snapshot}
                busy={props.busy}
                source={t("addons.pane.dev", { folder: a.dev?.label ?? a.id })}
                onRevoke={props.onRevoke}
                actions={
                  <>
                    <BusyButton type="button" className="addon-btn" busy={props.busy?.has(`reload:${a.id}`)} onClick={() => props.onDevReload?.(a.id)}>
                      {t("addons.developer.reload")}
                    </BusyButton>
                    <button type="button" className="addon-btn danger" onClick={() => props.onRemove(a.id)}>
                      {t("addons.developer.remove")}
                    </button>
                  </>
                }
              />
            ))}
          </ul>
        </Group>
      )}
    </div>
  );
}

function Alerts(props: { t: Translate } & Pick<Props, "listError" | "onRetryList" | "grantsError" | "onRetryGrants" | "notice" | "busy">) {
  const { t } = props;
  return (
    <>
      {props.listError !== undefined && (
        <p className="addon-list-error" role="alert">
          {t("addons.listFailed", { message: props.listError })}{" "}
          <button type="button" className="addon-btn" onClick={props.onRetryList}>
            {t("addons.listRetry")}
          </button>
        </p>
      )}
      {props.grantsError !== undefined && (
        <p className="addon-list-error" role="alert">
          {t("addons.grantsFailed", { message: props.grantsError })}{" "}
          <BusyButton type="button" className="addon-btn" busy={props.busy?.has("grants")} onClick={props.onRetryGrants}>
            {t("addons.listRetry")}
          </BusyButton>
        </p>
      )}
      {props.notice && (
        <p className={`addon-notice ${props.notice.kind}`} role={props.notice.kind === "error" ? "alert" : "status"}>
          {props.notice.text}
        </p>
      )}
    </>
  );
}

/** "Can": what the add-on declares, one accent chip per permission. */
function CanRow(props: { t: Translate; addon: InstalledAddon }) {
  const { t, addon } = props;
  const network = addonNetwork(addon);
  const perms = declaredPermissions(addon);
  return (
    <div className="addon-kv">
      <span className="addon-lbl">{t("addons.card.can")}</span>
      <span className="addon-chips">
        {perms.length === 0 && <span className="addon-chip none">{t("addons.permission.none")}</span>}
        {perms.map((p) => {
          const row = permissionRow(p, network);
          return (
            <span key={p} className="addon-chip">
              {t(row.key, row.params)}
            </span>
          );
        })}
      </span>
    </div>
  );
}

/** "Allowed": what the user granted and remembered, one green chip each with Revoke. */
function AllowedRow(props: { t: Translate; snapshot: AddonsSnapshot; addonId: string; busy?: ReadonlySet<string>; onRevoke: (addonId: string, grantIndex: number) => void }) {
  const { t, snapshot, addonId } = props;
  const none = grantsOf(snapshot.grants, addonId).length === 0;
  return (
    <div className="addon-kv">
      <span className="addon-lbl">{t("addons.card.allowed")}</span>
      <span className="addon-chips">
        {none && <span className="addon-chip none">{t("addons.card.nothingYet")}</span>}
        {snapshot.grants.map((g, i) =>
          g.addonId === addonId ? (
            <span key={i} className="addon-chip ok">
              {grantText(t, g)}
              <BusyButton type="button" className="addon-link" busy={props.busy?.has(`revoke:${addonId}:${i}`)} onClick={() => props.onRevoke(addonId, i)}>
                {t("addons.grant.revoke")}
              </BusyButton>
            </span>
          ) : null,
        )}
      </span>
    </div>
  );
}

function AddonCard(props: {
  t: Translate;
  addon: InstalledAddon;
  snapshot: AddonsSnapshot;
  busy?: ReadonlySet<string>;
  /** The small mono line next to the name: `owner/repo · sha`, "built in" or the developer folder. */
  source: string;
  isNew?: boolean;
  actions?: ReactNode;
  onRevoke: (addonId: string, grantIndex: number) => void;
}) {
  const { t, addon: a } = props;
  const title = a.panes.map((p) => p.title).join(", ");
  return (
    <li className={`addon-acard${props.isNew ? " new" : ""}`}>
      <div className="addon-acard-head">
        <span className="addon-name">{title}</span>
        <span className="addon-src">{props.source}</span>
      </div>
      {a.digestOk === false && <p className="addon-digest-bad" role="alert">{t("addons.failure.digest_mismatch", { title: a.panes[0]?.title ?? a.id })}</p>}
      <CanRow t={t} addon={a} />
      <AllowedRow t={t} snapshot={props.snapshot} addonId={a.id} busy={props.busy} onRevoke={props.onRevoke} />
      {props.actions && <div className="addon-actions">{props.actions}</div>}
    </li>
  );
}

function InstalledList(props: {
  t: Translate;
  snapshot: AddonsSnapshot;
  installed: InstalledAddon[];
  readOnly?: boolean;
  canInstall?: boolean;
  newId?: string;
  busy?: ReadonlySet<string>;
  onRevoke: (addonId: string, grantIndex: number) => void;
  onCheckUpdate: (addonId: string) => void;
  onRemove: (addonId: string) => void;
}) {
  const { t, installed, snapshot } = props;
  if (installed.length === 0) return <p className="addon-help">{t("addons.installed.empty")}</p>;
  return (
    <ul className="addon-list">
      {installed.map((a) => (
        <AddonCard
          key={a.id}
          t={t}
          addon={a}
          snapshot={snapshot}
          source={[a.id, shortSha(a.sha), a.installedAt ? t("addons.card.installedOn", { date: a.installedAt.slice(0, 10) }) : ""].filter(Boolean).join(" · ")}
          isNew={a.id === props.newId}
          busy={props.busy}
          onRevoke={props.onRevoke}
          actions={
            <>
              {!props.readOnly && props.canInstall !== false && (
                <BusyButton type="button" className="addon-btn" busy={props.busy?.has(`check:${a.id}`)} onClick={() => props.onCheckUpdate(a.id)}>
                  {t("addons.installed.checkUpdates")}
                </BusyButton>
              )}
              {props.canInstall !== false && (
                <button type="button" className="addon-btn danger" onClick={() => props.onRemove(a.id)}>
                  {t("addons.installed.remove")}
                </button>
              )}
            </>
          }
        />
      ))}
    </ul>
  );
}
