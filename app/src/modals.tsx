import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";

// Agent types selectable when adding an agent (each maps to a spawnable CLI).
const AGENT_TYPES = ["claude-code", "codex", "gemini"];

type BrowseDir = (current: string) => Promise<string | null>;

/** Modal chrome: dimmed backdrop + centered card. */
function Modal(props: {
  title: string;
  children: React.ReactNode;
  onClose?: () => void;
}) {
  return (
    <div className="modal-backdrop" onClick={props.onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-title">{props.title}</div>
        {props.children}
      </div>
    </div>
  );
}

/** Hook: keep `project` defaulted to <HOME>/agmsg-agents/<name> until edited. */
function useDefaultProject(name: string) {
  const [project, setProject] = useState("");
  const [edited, setEdited] = useState(false);
  useEffect(() => {
    if (edited) return;
    const n = name.trim();
    if (!n) {
      setProject("");
      return;
    }
    invoke<string>("agmsg_default_project", { name: n })
      .then((p) => setProject((cur) => (edited ? cur : p)))
      .catch(() => {});
  }, [name, edited]);
  return { project, setProject, markEdited: () => setEdited(true) };
}

export function NewTeamModal(props: {
  firstRun: boolean;
  onCreate: (team: string, appUser: string, project: string) => Promise<void>;
  onClose?: () => void;
  browseDir: BrowseDir;
}) {
  const [team, setTeam] = useState("");
  const [appUser, setAppUser] = useState("you");
  const { project, setProject, markEdited } = useDefaultProject(appUser);
  const [err, setErr] = useState("");
  const ready = team.trim() && appUser.trim();
  const submit = async () => {
    if (!ready) return;
    try {
      await props.onCreate(team.trim(), appUser.trim(), project);
    } catch (e) {
      setErr(String(e));
    }
  };
  return (
    <Modal
      title={props.firstRun ? "Welcome — create your first team" : "New team"}
      onClose={props.onClose}
    >
      <p className="modal-note">
        Creates the team and adds you as its app-user (the bottom chat box owner).
      </p>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <label>
          Team name
          <input autoFocus value={team} onChange={(e) => setTeam(e.target.value)} placeholder="my-team" />
        </label>
        <label>
          Your name (app-user)
          <input value={appUser} onChange={(e) => setAppUser(e.target.value)} />
        </label>
        <label>
          Project dir
          <span className="path-row">
            <input
              value={project}
              onChange={(e) => {
                markEdited();
                setProject(e.target.value);
              }}
            />
            <button
              type="button"
              onClick={async () => {
                const d = await props.browseDir(project);
                if (d) {
                  markEdited();
                  setProject(d);
                }
              }}
            >
              Browse…
            </button>
          </span>
        </label>
        {err && <div className="modal-err">{err}</div>}
        <div className="modal-actions">
          {props.onClose && (
            <button type="button" onClick={props.onClose}>
              Cancel
            </button>
          )}
          <button type="submit" className="primary" disabled={!ready}>
            Create
          </button>
        </div>
      </form>
    </Modal>
  );
}

export function AppUserModal(props: {
  onAdd: (name: string, project: string) => Promise<void>;
  onClose: () => void;
  browseDir: BrowseDir;
}) {
  const [name, setName] = useState("you");
  const { project, setProject, markEdited } = useDefaultProject(name);
  const [err, setErr] = useState("");
  const submit = async () => {
    if (!name.trim()) return;
    try {
      await props.onAdd(name.trim(), project);
    } catch (e) {
      setErr(String(e));
    }
  };
  return (
    <Modal title="Add app-user (you)" onClose={props.onClose}>
      <p className="modal-note">
        The app-user is your identity in this team — the owner of the bottom chat box.
        One per team.
      </p>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <label>
          Name
          <input autoFocus value={name} onChange={(e) => setName(e.target.value)} />
        </label>
        <label>
          Project dir
          <span className="path-row">
            <input
              value={project}
              onChange={(e) => {
                markEdited();
                setProject(e.target.value);
              }}
            />
            <button
              type="button"
              onClick={async () => {
                const d = await props.browseDir(project);
                if (d) {
                  markEdited();
                  setProject(d);
                }
              }}
            >
              Browse…
            </button>
          </span>
        </label>
        {err && <div className="modal-err">{err}</div>}
        <div className="modal-actions">
          <button type="button" onClick={props.onClose}>
            Cancel
          </button>
          <button type="submit" className="primary" disabled={!name.trim()}>
            Add
          </button>
        </div>
      </form>
    </Modal>
  );
}

export function AgentModal(props: {
  onAdd: (name: string, type: string, project: string) => Promise<void>;
  onClose: () => void;
  browseDir: BrowseDir;
}) {
  const [type, setType] = useState(AGENT_TYPES[0]);
  const [name, setName] = useState("");
  const { project, setProject, markEdited } = useDefaultProject(name);
  const [err, setErr] = useState("");
  const submit = async () => {
    if (!name.trim()) return;
    try {
      await props.onAdd(name.trim(), type, project);
    } catch (e) {
      setErr(String(e));
    }
  };
  return (
    <Modal title="Add agent" onClose={props.onClose}>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <label>
          Type
          <select value={type} onChange={(e) => setType(e.target.value)}>
            {AGENT_TYPES.map((t) => (
              <option key={t} value={t}>
                {t}
              </option>
            ))}
          </select>
        </label>
        <label>
          Name
          <input autoFocus value={name} onChange={(e) => setName(e.target.value)} placeholder="alice" />
        </label>
        <label>
          Project dir
          <span className="path-row">
            <input
              value={project}
              onChange={(e) => {
                markEdited();
                setProject(e.target.value);
              }}
            />
            <button
              type="button"
              onClick={async () => {
                const d = await props.browseDir(project);
                if (d) {
                  markEdited();
                  setProject(d);
                }
              }}
            >
              Browse…
            </button>
          </span>
        </label>
        {err && <div className="modal-err">{err}</div>}
        <div className="modal-actions">
          <button type="button" onClick={props.onClose}>
            Cancel
          </button>
          <button type="submit" className="primary" disabled={!name.trim()}>
            Add &amp; spawn
          </button>
        </div>
      </form>
    </Modal>
  );
}

export function RenameModal(props: {
  current: string;
  onRename: (current: string, next: string) => Promise<void>;
  onClose: () => void;
}) {
  const [next, setNext] = useState(props.current);
  const [err, setErr] = useState("");
  const submit = async () => {
    if (!next.trim() || next.trim() === props.current) return;
    try {
      await props.onRename(props.current, next.trim());
    } catch (e) {
      setErr(String(e));
    }
  };
  return (
    <Modal title={`Rename ${props.current}`} onClose={props.onClose}>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <label>
          New name
          <input autoFocus value={next} onChange={(e) => setNext(e.target.value)} />
        </label>
        {err && <div className="modal-err">{err}</div>}
        <div className="modal-actions">
          <button type="button" onClick={props.onClose}>
            Cancel
          </button>
          <button
            type="submit"
            className="primary"
            disabled={!next.trim() || next.trim() === props.current}
          >
            Rename
          </button>
        </div>
      </form>
    </Modal>
  );
}
