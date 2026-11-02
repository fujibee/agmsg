import { BusyButton } from "../busy";
import type { Translate } from "./model";
import { choiceFor, visibleEntries } from "./agentEntries";
import type { MemberState } from "./source";

// The members and agents that add-ons made, with their state. An agent that may still be running after the
// app stopped (orphaned / unknown) shows its pid and waits for the person: open a new one, or leave it.

export function AddonAgents(props: {
  t: Translate;
  entries: MemberState[];
  /** Entries whose choice the person put off for now (kept in the list, without buttons). */
  left: ReadonlySet<string>;
  busy?: ReadonlySet<string>;
  onOpen: (key: string) => void;
  onLeave: (key: string) => void;
  onRefresh: () => void;
}) {
  const { t } = props;
  const entries = visibleEntries(props.entries);
  return (
    <section className="addon-block addon-agents" aria-label={t("addons.agents.title")}>
      <h4>
        {t("addons.agents.title")}{" "}
        <BusyButton type="button" className="addon-link" busy={props.busy?.has("agents")} onClick={props.onRefresh}>
          {t("addons.agents.refresh")}
        </BusyButton>
      </h4>
      {entries.length === 0 && <p className="addon-never">{t("addons.agents.none")}</p>}
      {entries.map((e) => {
        const choice = props.left.has(e.key) ? null : choiceFor(e);
        return (
          <div key={e.key} className="addon-agent-row">
            <b>{e.name}</b>{" "}
            <span className="addon-why">
              {t(`addons.agents.kind.${e.kind}`)} · {e.type} · {e.team} · {t(`addons.agents.state.${e.state}`)}
              {e.pid !== undefined && <> · {t("addons.agents.pid", { pid: e.pid })}</>}
              {e.reason && <> · {e.reason}</>}
            </span>
            {choice === "choose" && (
              <>
                <p className="addon-never">{t(e.state === "orphaned" ? "addons.agents.orphanedHelp" : "addons.agents.unknownHelp")}</p>
                <div className="addon-card-actions">
                  <BusyButton type="button" busy={props.busy?.has(`agent:${e.key}`)} onClick={() => props.onOpen(e.key)}>
                    {t("addons.agents.openNew")}
                  </BusyButton>
                  <button type="button" onClick={() => props.onLeave(e.key)}>
                    {t("addons.agents.leave")}
                  </button>
                </div>
              </>
            )}
            {choice === "open" && (
              <div className="addon-card-actions">
                <BusyButton type="button" busy={props.busy?.has(`agent:${e.key}`)} onClick={() => props.onOpen(e.key)}>
                  {t("addons.agents.open")}
                </BusyButton>
              </div>
            )}
          </div>
        );
      })}
    </section>
  );
}
