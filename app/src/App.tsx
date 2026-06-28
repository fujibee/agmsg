import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { TerminalPane } from "./TerminalPane";
import {
  AgentModal,
  AppUserModal,
  NewTeamModal,
  RenameModal,
} from "./modals";
import "./App.css";

export type Member = { name: string; types: string[]; project: string };
type Message = {
  id: number;
  team: string;
  from: string;
  to: string;
  body: string;
  created_at: string;
};
type Pane = { id: string; label: string; cmd: string; args: string[]; cwd?: string };
type Modal =
  | { kind: "team"; firstRun: boolean }
  | { kind: "agent" }
  | { kind: "appuser" }
  | { kind: "rename"; current: string }
  | null;

// The agmsg type that represents the human at the app (the bottom chat box owner).
export const APP_USER_TYPE = "agmsg-app";
// Which interactive CLI to spawn for a given agmsg agent type.
export const SPAWN_CMD: Record<string, string> = {
  "claude-code": "claude",
  codex: "codex",
  gemini: "gemini",
};

export default function App() {
  const [teams, setTeams] = useState<string[]>([]);
  const [team, setTeam] = useState<string>("");
  const [members, setMembers] = useState<Member[]>([]);
  const [messages, setMessages] = useState<Message[]>([]);
  const [panes, setPanes] = useState<Pane[]>([]);
  const [active, setActive] = useState<string>("room");
  const [target, setTarget] = useState<string>("");
  const [draft, setDraft] = useState<string>("");
  const [modal, setModal] = useState<Modal>(null);
  const [newMenu, setNewMenu] = useState(false);
  const seq = useRef(0);
  const feedRef = useRef<HTMLDivElement>(null);
  const chatRef = useRef<HTMLDivElement>(null);
  const panesRef = useRef<Pane[]>([]);
  panesRef.current = panes;

  // The app user = the member registered with the agmsg-app type (one per team).
  const appUser = members.find((m) => m.types.includes(APP_USER_TYPE))?.name ?? "";
  // Everyone else is a spawnable/messageable agent.
  const others = members.filter((m) => !m.types.includes(APP_USER_TYPE));
  // The app user's own send/receive thread.
  const myThread = messages.filter((m) => m.from === appUser || m.to === appUser);

  const loadTeams = useCallback(async () => {
    const t = await invoke<string[]>("agmsg_teams");
    setTeams(t);
    return t;
  }, []);

  const loadMembers = useCallback(async (t: string) => {
    const m = await invoke<Member[]>("agmsg_members", { team: t });
    setMembers(m);
    return m;
  }, []);

  // First load: teams. If there are none, the first-run flow opens New Team.
  useEffect(() => {
    loadTeams()
      .then((t) => {
        if (t.length === 0) setModal({ kind: "team", firstRun: true });
        else setTeam((cur) => cur || t[0]);
      })
      .catch(console.error);
  }, [loadTeams]);

  // On team change: load members + history. Prompt to add an app-user if missing.
  useEffect(() => {
    if (!team) return;
    invoke<Message[]>("agmsg_messages", { team, limit: 200 })
      .then(setMessages)
      .catch(console.error);
    loadMembers(team)
      .then((m) => {
        if (!m.some((x) => x.types.includes(APP_USER_TYPE))) {
          setModal((cur) => cur ?? { kind: "appuser" });
        }
      })
      .catch(console.error);
  }, [team, loadMembers]);

  // Live team-room updates; inject into a matching pane.
  useEffect(() => {
    const p = listen<Message>("agmsg-message", (e) => {
      if (e.payload.team !== team) return;
      setMessages((prev) => [...prev, e.payload]);
      const pane = panesRef.current.find((pn) => pn.label === e.payload.to);
      if (pane) void invoke("pty_inject", { id: pane.id, text: e.payload.body });
    });
    return () => void p.then((u) => u());
  }, [team]);

  useEffect(() => {
    feedRef.current?.scrollTo({ top: feedRef.current.scrollHeight });
  }, [messages, active]);
  useEffect(() => {
    chatRef.current?.scrollTo({ top: chatRef.current.scrollHeight });
  }, [myThread.length]);

  const spawnMember = useCallback((m: Member) => {
    const type = m.types.find((t) => SPAWN_CMD[t]);
    const cmd = type ? SPAWN_CMD[type] : "bash";
    const id = `${m.name}-${seq.current++}`;
    setPanes((prev) => [...prev, { id, label: m.name, cmd, args: [], cwd: m.project || undefined }]);
    setActive(id);
  }, []);

  const closePane = useCallback((id: string) => {
    setPanes((prev) => prev.filter((p) => p.id !== id));
    setActive((a) => (a === id ? "room" : a));
  }, []);

  const send = useCallback(async () => {
    if (!draft.trim() || !target || !appUser) return;
    try {
      await invoke("agmsg_send", { team, from: appUser, to: target, body: draft });
      setDraft("");
    } catch (err) {
      alert(`send failed: ${err}`);
    }
  }, [draft, target, team, appUser]);

  // --- modal handlers (all writes go through agmsg scripts via the backend) ---

  const onCreateTeam = useCallback(
    async (name: string, appUserName: string, project: string) => {
      // A single join.sh creates the team (if new) AND adds the app-user — no
      // empty-team intermediate, no extra agmsg script.
      await invoke("agmsg_join", {
        team: name,
        name: appUserName,
        agentType: APP_USER_TYPE,
        project,
      });
      await loadTeams();
      setTeam(name);
      setModal(null);
    },
    [loadTeams],
  );

  const onAddAppUser = useCallback(
    async (name: string, project: string) => {
      await invoke("agmsg_join", { team, name, agentType: APP_USER_TYPE, project });
      await loadMembers(team);
      setModal(null);
    },
    [team, loadMembers],
  );

  const onAddAgent = useCallback(
    async (name: string, type: string, project: string) => {
      await invoke("agmsg_join", { team, name, agentType: type, project });
      const m = await loadMembers(team);
      const added = m.find((x) => x.name === name);
      if (added) spawnMember(added);
      setModal(null);
    },
    [team, loadMembers, spawnMember],
  );

  const onRename = useCallback(
    async (current: string, next: string) => {
      await invoke("agmsg_rename", { team, oldName: current, newName: next });
      await loadMembers(team);
      setModal(null);
    },
    [team, loadMembers],
  );

  const browseDir = useCallback(async (current: string): Promise<string | null> => {
    const picked = await openDialog({ directory: true, defaultPath: current || undefined });
    return typeof picked === "string" ? picked : null;
  }, []);

  return (
    <div className="app" onClick={() => setNewMenu(false)}>
      <header className="topbar">
        <span className="brand">agmsg</span>
        <div className="new-wrap" onClick={(e) => e.stopPropagation()}>
          <button className="new-btn" onClick={() => setNewMenu((v) => !v)}>
            ＋ New ▾
          </button>
          {newMenu && (
            <div className="new-menu">
              <button
                onClick={() => {
                  setNewMenu(false);
                  setModal({ kind: "team", firstRun: false });
                }}
              >
                Team…
              </button>
              <button
                disabled={!team}
                onClick={() => {
                  setNewMenu(false);
                  setModal({ kind: "agent" });
                }}
              >
                Agent…
              </button>
            </div>
          )}
        </div>
        <select value={team} onChange={(e) => setTeam(e.target.value)}>
          {teams.map((t) => (
            <option key={t} value={t}>
              {t}
            </option>
          ))}
        </select>
        <span className="spacer" />
        <span className="hint">team-embedded terminals · universal stdin-inject delivery</span>
      </header>

      <div className="body">
        <aside className="sidebar">
          <div className="sidebar-title">Members</div>
          <ul className="members">
            {others.map((m) => (
              <li key={m.name}>
                <button className="member" onClick={() => spawnMember(m)} title="spawn in a PTY pane">
                  <span className="member-name">{m.name}</span>
                  <span className="member-types">{m.types.join(", ") || "—"}</span>
                </button>
              </li>
            ))}
            {others.length === 0 && <li className="empty">No agents yet. Use ＋ New → Agent.</li>}
          </ul>
        </aside>

        <main className="main">
          <nav className="tabs">
            <button
              className={active === "room" ? "tab active" : "tab"}
              onClick={() => setActive("room")}
            >
              # team room
            </button>
            {panes.map((p) => (
              <span key={p.id} className={active === p.id ? "tab active" : "tab"}>
                <button className="tab-label" onClick={() => setActive(p.id)}>
                  ▸ {p.label}
                </button>
                <button className="tab-close" onClick={() => closePane(p.id)}>
                  ×
                </button>
              </span>
            ))}
          </nav>

          <section className="stage">
            <div className="room" hidden={active !== "room"} ref={feedRef}>
              {messages.map((m) => (
                <div className="msg" key={m.id}>
                  <span className="msg-time">{m.created_at.slice(11, 19)}</span>
                  <span className="msg-from">{m.from}</span>
                  <span className="msg-arrow">→</span>
                  <span className="msg-to">{m.to}</span>
                  <span className="msg-body">{m.body}</span>
                </div>
              ))}
              {messages.length === 0 && <div className="empty">No messages yet.</div>}
            </div>

            {panes.map((p) => (
              <div key={p.id} className="pane-host" hidden={active !== p.id}>
                <TerminalPane id={p.id} cmd={p.cmd} args={p.args} cwd={p.cwd} />
              </div>
            ))}
          </section>

          {/* App-user chat: the human's own send/receive thread + composer. */}
          <div className="appuser-chat" ref={chatRef}>
            {myThread.map((m) => (
              <div className={m.from === appUser ? "chat-line out" : "chat-line in"} key={m.id}>
                <span className="chat-time">{m.created_at.slice(11, 19)}</span>
                <span className="chat-peer">
                  {m.from === appUser ? `→ ${m.to}` : `${m.from} →`}
                </span>
                <span className="chat-body">{m.body}</span>
              </div>
            ))}
            {appUser && myThread.length === 0 && (
              <div className="empty">Your messages (as {appUser}) appear here.</div>
            )}
            {!appUser && team && (
              <div className="empty">
                No app-user for this team.{" "}
                <button className="link" onClick={() => setModal({ kind: "appuser" })}>
                  Add one
                </button>
              </div>
            )}
          </div>

          <footer className="composer">
            {appUser ? (
              <>
                <span className="as">
                  as {appUser}
                  <button
                    className="rename"
                    title="rename app-user"
                    onClick={() => setModal({ kind: "rename", current: appUser })}
                  >
                    ✎
                  </button>
                </span>
                <select value={target} onChange={(e) => setTarget(e.target.value)}>
                  <option value="">to…</option>
                  {others.map((m) => (
                    <option key={m.name} value={m.name}>
                      {m.name}
                    </option>
                  ))}
                </select>
                <input
                  value={draft}
                  placeholder="message"
                  onChange={(e) => setDraft(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && send()}
                />
                <button onClick={send} disabled={!draft.trim() || !target}>
                  send
                </button>
              </>
            ) : (
              <span className="as">no app-user — add one to send/receive</span>
            )}
          </footer>
        </main>
      </div>

      {modal?.kind === "team" && (
        <NewTeamModal
          firstRun={modal.firstRun}
          onCreate={onCreateTeam}
          onClose={modal.firstRun ? undefined : () => setModal(null)}
          browseDir={browseDir}
        />
      )}
      {modal?.kind === "appuser" && (
        <AppUserModal onAdd={onAddAppUser} onClose={() => setModal(null)} browseDir={browseDir} />
      )}
      {modal?.kind === "agent" && (
        <AgentModal onAdd={onAddAgent} onClose={() => setModal(null)} browseDir={browseDir} />
      )}
      {modal?.kind === "rename" && (
        <RenameModal current={modal.current} onRename={onRename} onClose={() => setModal(null)} />
      )}
    </div>
  );
}
