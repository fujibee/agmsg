import { useEffect, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { invoke } from "@tauri-apps/api/core";
import { SUPPORTED_LANGUAGES } from "./i18n";
import { AUTO_TIMEZONE, detectTimeZone, isValidTimeZone, listTimeZones } from "./time";

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

/**
 * Hook for the project-dir field. If `override` is given (e.g. the team's own
 * project dir, carried over so agents default into the same place), it wins and
 * the field stays put. Otherwise the field defaults to <HOME>/agmsg-agents/<name>
 * and tracks the name until the user edits it.
 */
function useDefaultProject(name: string, override?: string) {
  const [project, setProject] = useState(override ?? "");
  const [edited, setEdited] = useState(false);
  useEffect(() => {
    if (edited || override) return;
    const n = name.trim();
    if (!n) {
      setProject("");
      return;
    }
    invoke<string>("agmsg_default_project", { name: n })
      .then((p) => setProject((cur) => (edited || override ? cur : p)))
      .catch(() => {});
  }, [name, edited, override]);
  return { project, setProject, markEdited: () => setEdited(true) };
}

export function NewTeamModal(props: {
  firstRun: boolean;
  onCreate: (team: string, appUser: string, project: string) => Promise<void>;
  onClose?: () => void;
  browseDir: BrowseDir;
}) {
  const { t } = useTranslation();
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
      title={props.firstRun ? t("modal.newTeam.titleFirstRun") : t("modal.newTeam.title")}
      onClose={props.onClose}
    >
      <p className="modal-note">{t("modal.newTeam.note")}</p>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <label>
          {t("modal.newTeam.teamNameLabel")}
          <input
            autoFocus
            value={team}
            onChange={(e) => setTeam(e.target.value)}
            placeholder={t("modal.newTeam.teamNamePlaceholder")}
          />
        </label>
        <label>
          {t("modal.newTeam.appUserLabel")}
          <input value={appUser} onChange={(e) => setAppUser(e.target.value)} />
        </label>
        <label>
          {t("common.projectDirLabel")}
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
              {t("common.browse")}
            </button>
          </span>
        </label>
        {err && <div className="modal-err">{err}</div>}
        <div className="modal-actions">
          {props.onClose && (
            <button type="button" onClick={props.onClose}>
              {t("common.cancel")}
            </button>
          )}
          <button type="submit" className="primary" disabled={!ready}>
            {t("modal.newTeam.create")}
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
  const { t } = useTranslation();
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
    <Modal title={t("modal.appUser.title")} onClose={props.onClose}>
      <p className="modal-note">{t("modal.appUser.note")}</p>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <label>
          {t("common.nameLabel")}
          <input autoFocus value={name} onChange={(e) => setName(e.target.value)} />
        </label>
        <label>
          {t("common.projectDirLabel")}
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
              {t("common.browse")}
            </button>
          </span>
        </label>
        {err && <div className="modal-err">{err}</div>}
        <div className="modal-actions">
          <button type="button" onClick={props.onClose}>
            {t("common.cancel")}
          </button>
          <button type="submit" className="primary" disabled={!name.trim()}>
            {t("modal.appUser.add")}
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
  /** The team's project dir — agents default into the same place. */
  defaultProject?: string;
  /** Spawnable agent types, from agmsg's registry. */
  types: string[];
}) {
  const { t } = useTranslation();
  const [type, setType] = useState(props.types[0] ?? "");
  useEffect(() => {
    if (!type && props.types[0]) setType(props.types[0]);
  }, [props.types, type]);
  const [name, setName] = useState("");
  const { project, setProject, markEdited } = useDefaultProject(name, props.defaultProject);
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
    <Modal title={t("modal.agent.title")} onClose={props.onClose}>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <label>
          {t("modal.agent.typeLabel")}
          <select value={type} onChange={(e) => setType(e.target.value)}>
            {props.types.map((typeName) => (
              <option key={typeName} value={typeName}>
                {typeName}
              </option>
            ))}
          </select>
        </label>
        <label>
          {t("common.nameLabel")}
          <input
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder={t("modal.agent.namePlaceholder")}
          />
        </label>
        <label>
          {t("common.projectDirLabel")}
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
              {t("common.browse")}
            </button>
          </span>
        </label>
        {err && <div className="modal-err">{err}</div>}
        <div className="modal-actions">
          <button type="button" onClick={props.onClose}>
            {t("common.cancel")}
          </button>
          <button type="submit" className="primary" disabled={!name.trim()}>
            {t("modal.agent.addAndSpawn")}
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
  const { t } = useTranslation();
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
    <Modal title={t("modal.rename.title", { current: props.current })} onClose={props.onClose}>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        <label>
          {t("modal.rename.newNameLabel")}
          <input autoFocus value={next} onChange={(e) => setNext(e.target.value)} />
        </label>
        {err && <div className="modal-err">{err}</div>}
        <div className="modal-actions">
          <button type="button" onClick={props.onClose}>
            {t("common.cancel")}
          </button>
          <button
            type="submit"
            className="primary"
            disabled={!next.trim() || next.trim() === props.current}
          >
            {t("modal.rename.confirmButton")}
          </button>
        </div>
      </form>
    </Modal>
  );
}

export function ConfirmModal(props: {
  title: string;
  body: string;
  confirmLabel?: string;
  danger?: boolean;
  onConfirm: () => void;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  return (
    <Modal title={props.title} onClose={props.onClose}>
      <p className="modal-note">{props.body}</p>
      <div className="modal-actions">
        <button type="button" onClick={props.onClose}>
          {t("common.cancel")}
        </button>
        <button
          type="button"
          className={props.danger ? "primary danger" : "primary"}
          onClick={() => {
            props.onConfirm();
            props.onClose();
          }}
        >
          {props.confirmLabel ?? t("modal.confirm.defaultLabel")}
        </button>
      </div>
    </Modal>
  );
}

// Exported so App.tsx can validate a localStorage-restored value against the
// same range this modal's <input> enforces (see terminalFontSize's lazy
// useState initializer).
export const MIN_TERMINAL_FONT_SIZE = 8;
export const MAX_TERMINAL_FONT_SIZE = 24;

export function SettingsModal(props: {
  onClose: () => void;
  terminalFontSize: number;
  onTerminalFontSizeChange: (size: number) => void;
  timezone: string;
  onTimezoneChange: (timezone: string) => void;
}) {
  const { t, i18n } = useTranslation();
  // Computed once per modal open, not on every keystroke — the full zone
  // list (400+ IANA names) doesn't change while the dropdown is open.
  const [timeZones] = useState(listTimeZones);
  // A plain <select> with 400+ flat IANA names is nearly unusable: a native
  // select's keyboard jump only matches the START of an option ("Asia/Tokyo"
  // never matches typing "Tokyo"). A text input + <datalist> keeps this
  // dependency-free while getting the browser's own substring-matching
  // suggestion filtering. Local draft text so a still-typing/partial value
  // can be shown without committing an invalid zone to app state.
  const autoLabel = t("settings.timezone.auto", { zone: detectTimeZone() });
  const [timezoneText, setTimezoneText] = useState(() =>
    props.timezone === AUTO_TIMEZONE ? autoLabel : props.timezone,
  );
  // Switching language mid-modal recomputes autoLabel (it's translated) but
  // wouldn't otherwise touch this draft, leaving it showing the old
  // language's "Auto (...)" text. Only re-sync when the draft still equals
  // the PREVIOUS autoLabel and the committed timezone is still auto — never
  // clobbers a custom zone name the user is typing/has typed.
  const lastAutoLabelRef = useRef(autoLabel);
  useEffect(() => {
    if (props.timezone === AUTO_TIMEZONE && timezoneText === lastAutoLabelRef.current) {
      setTimezoneText(autoLabel);
    }
    lastAutoLabelRef.current = autoLabel;
    // Deliberately scoped to autoLabel changes only (see comment above) —
    // timezoneText/props.timezone are read via closure, not deps, so this
    // doesn't re-fire on every keystroke or timezone change.
  }, [autoLabel]);
  return (
    <Modal title={t("modal.settings.title")} onClose={props.onClose}>
      <label>
        {t("language.label")}
        <select
          value={i18n.resolvedLanguage}
          onChange={(e) => void i18n.changeLanguage(e.target.value)}
        >
          {Object.entries(SUPPORTED_LANGUAGES).map(([code, label]) => (
            <option key={code} value={code}>
              {label}
            </option>
          ))}
        </select>
      </label>
      <label>
        {t("settings.terminalFontSize.label")}
        <input
          type="number"
          min={MIN_TERMINAL_FONT_SIZE}
          max={MAX_TERMINAL_FONT_SIZE}
          value={props.terminalFontSize}
          onChange={(e) => {
            const n = Number(e.target.value);
            if (n >= MIN_TERMINAL_FONT_SIZE && n <= MAX_TERMINAL_FONT_SIZE) {
              props.onTerminalFontSizeChange(n);
            }
          }}
        />
      </label>
      <label>
        {t("settings.timezone.label")}
        <input
          type="text"
          list="settings-timezone-options"
          value={timezoneText}
          onChange={(e) => {
            const v = e.target.value;
            setTimezoneText(v);
            // Only commit a complete, valid entry — mid-typing text (e.g.
            // "Tokyo" before the datalist suggestion is picked) shouldn't
            // overwrite the persisted timezone with something invalid.
            if (v === autoLabel) props.onTimezoneChange(AUTO_TIMEZONE);
            else if (isValidTimeZone(v)) props.onTimezoneChange(v);
          }}
        />
        <datalist id="settings-timezone-options">
          <option value={autoLabel} />
          {timeZones.map((zone) => (
            <option key={zone} value={zone} />
          ))}
        </datalist>
      </label>
      <div className="modal-actions">
        <button type="button" className="primary" onClick={props.onClose}>
          {t("common.close")}
        </button>
      </div>
    </Modal>
  );
}
