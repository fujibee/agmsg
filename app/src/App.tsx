import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { TerminalPane } from "./TerminalPane";
import "./App.css";

type Member = { name: string; types: string[] };
type Message = {
  id: number;
  team: string;
  from: string;
  to: string;
  body: string;
  created_at: string;
};
type Pane = { id: string; label: string; cmd: string; args: string[] };

// Which interactive CLI to spawn for a given agmsg agent type.
const SPAWN_CMD: Record<string, string> = {
  "claude-code": "claude",
  codex: "codex",
};

// The human at the app is a first-class agmsg member (joined as type "app-user").
const APP_USER = "you";

export default function App() {
  const [teams, setTeams] = useState<string[]>([]);
  const [team, setTeam] = useState<string>("");
  const [members, setMembers] = useState<Member[]>([]);
  const [messages, setMessages] = useState<Message[]>([]);
  const [panes, setPanes] = useState<Pane[]>([]);
  const [active, setActive] = useState<string>("room");
  const [target, setTarget] = useState<string>("");
  const [draft, setDraft] = useState<string>("");
  const seq = useRef(0);
  const feedRef = useRef<HTMLDivElement>(null);
  const chatRef = useRef<HTMLDivElement>(null);
  // Latest panes, readable from the (long-lived) event listener without re-subscribing.
  const panesRef = useRef<Pane[]>([]);
  panesRef.current = panes;

  // The app user's own send/receive thread: every message they sent or received.
  const myThread = messages.filter((m) => m.from === APP_USER || m.to === APP_USER);

  // Load teams once.
  useEffect(() => {
    invoke<string[]>("agmsg_teams")
      .then((t) => {
        setTeams(t);
        setTeam((cur) => cur || t[0] || "");
      })
      .catch(console.error);
  }, []);

  // Load members + messages whenever the selected team changes.
  useEffect(() => {
    if (!team) return;
    invoke<Member[]>("agmsg_members", { team }).then(setMembers).catch(console.error);
    invoke<Message[]>("agmsg_messages", { team, limit: 200 })
      .then(setMessages)
      .catch(console.error);
  }, [team]);

  // Live team-room updates from the backend DB watcher.
  useEffect(() => {
    const p = listen<Message>("agmsg-message", (e) => {
      if (e.payload.team !== team) return;
      setMessages((prev) => [...prev, e.payload]);
      // The strategic core: if the recipient is running in one of our panes,
      // inject the message into that agent's stdin once it is idle.
      const pane = panesRef.current.find((pn) => pn.label === e.payload.to);
      if (pane) {
        void invoke("pty_inject", { id: pane.id, text: e.payload.body });
      }
    });
    return () => void p.then((u) => u());
  }, [team]);

  // Keep the team-room feed scrolled to the newest message.
  useEffect(() => {
    feedRef.current?.scrollTo({ top: feedRef.current.scrollHeight });
  }, [messages, active]);

  // Keep the app-user chat scrolled to the newest message.
  useEffect(() => {
    chatRef.current?.scrollTo({ top: chatRef.current.scrollHeight });
  }, [myThread.length]);

  const spawn = useCallback((m: Member) => {
    const type = m.types.find((t) => SPAWN_CMD[t]);
    const cmd = type ? SPAWN_CMD[type] : "bash";
    const id = `${m.name}-${seq.current++}`;
    setPanes((prev) => [...prev, { id, label: m.name, cmd, args: [] }]);
    setActive(id);
  }, []);

  const closePane = useCallback((id: string) => {
    setPanes((prev) => prev.filter((p) => p.id !== id));
    setActive((a) => (a === id ? "room" : a));
  }, []);

  const send = useCallback(async () => {
    if (!draft.trim() || !target) return;
    try {
      await invoke("agmsg_send", { team, from: APP_USER, to: target, body: draft });
      setDraft("");
    } catch (err) {
      console.error(err);
      alert(`send failed: ${err}`);
    }
  }, [draft, target, team]);

  return (
    <div className="app">
      <header className="topbar">
        <span className="brand">agmsg</span>
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
            {members
              .filter((m) => m.name !== APP_USER)
              .map((m) => (
              <li key={m.name}>
                <button className="member" onClick={() => spawn(m)} title="spawn in a PTY pane">
                  <span className="member-name">{m.name}</span>
                  <span className="member-types">{m.types.join(", ") || "—"}</span>
                </button>
              </li>
            ))}
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
            {/* Team room: view-only feed, default tab. */}
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

            {/* One mounted TerminalPane per spawn; only the active one is shown. */}
            {panes.map((p) => (
              <div key={p.id} className="pane-host" hidden={active !== p.id}>
                <TerminalPane id={p.id} cmd={p.cmd} args={p.args} />
              </div>
            ))}
          </section>

          {/* App-user chat: the human's own send/receive thread, above the composer. */}
          <div className="appuser-chat" ref={chatRef}>
            {myThread.map((m) => (
              <div className={m.from === APP_USER ? "chat-line out" : "chat-line in"} key={m.id}>
                <span className="chat-time">{m.created_at.slice(11, 19)}</span>
                <span className="chat-peer">
                  {m.from === APP_USER ? `→ ${m.to}` : `${m.from} →`}
                </span>
                <span className="chat-body">{m.body}</span>
              </div>
            ))}
            {myThread.length === 0 && (
              <div className="empty">Your messages (as {APP_USER}) appear here.</div>
            )}
          </div>

          {/* Composer: send to any member as the human at the app. */}
          <footer className="composer">
            <span className="as">as {APP_USER}</span>
            <select value={target} onChange={(e) => setTarget(e.target.value)}>
              <option value="">to…</option>
              {members
                .filter((m) => m.name !== APP_USER)
                .map((m) => (
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
          </footer>
        </main>
      </div>
    </div>
  );
}
