import { Settings } from "lucide-react";

// The bits of the sidebar that show the current team's app-user (#1510).
//
// They are components of their own, with the "is there an app-user?" decision
// INSIDE them, so a test can render them and look at the markup. When that
// decision was an `{appUser && ...}` wrapped around JSX in App.tsx, nothing
// short of rendering the whole app could tell whether the block was still
// there for a team without an app-user -- and a unit test of the decision
// alone would keep passing if the wrapper came back.

// Just the slice of react-i18next's `t` these use, so a test can pass a
// trivial stand-in instead of initialising i18next.
export type Translate = (key: string, options?: { team?: string }) => string;

// What the bottom block shows for the current team. The block also carries
// the settings gear, and settings are app-wide, so it is never hidden -- it
// used to be gated on the team having an app-user, which took the gear away
// in every team without one (a team joined through remote sync, say) and left
// no way to reach settings from there. Only the identity line varies: the
// app-user's name; a prompt to add one; or nothing, when no team is selected
// at all (there is nothing to add an app-user to).
export type SidebarUserBlock =
  | { kind: "user"; name: string }
  | { kind: "none" }
  | { kind: "no-team" };

export function sidebarUserBlock(appUser: string, team: string): SidebarUserBlock {
  if (appUser) return { kind: "user", name: appUser };
  return team ? { kind: "none" } : { kind: "no-team" };
}

function identityTitle(block: SidebarUserBlock, team: string, t: Translate): string | undefined {
  if (block.kind === "user") return t("sidebar.user.title", { team });
  if (block.kind === "none") return t("sidebar.user.none");
  return undefined;
}

// The expanded sidebar's footer: identity line + the settings gear. The gear
// is unconditional.
export function SidebarUser({
  appUser,
  team,
  t,
  onAddUser,
  onOpenSettings,
}: {
  appUser: string;
  team: string;
  t: Translate;
  onAddUser: () => void;
  onOpenSettings: () => void;
}) {
  const block = sidebarUserBlock(appUser, team);
  return (
    <div className="sidebar-user" title={identityTitle(block, team, t)}>
      {block.kind === "user" && (
        <>
          <span className="avatar" />
          <div className="su-meta">
            <span className="su-name">{block.name}</span>
            <span className="su-team">{team}</span>
          </div>
        </>
      )}
      {block.kind === "none" && (
        <>
          <span className="avatar" />
          <div className="su-meta">
            <span className="su-none">{t("sidebar.user.none")}</span>
            <button className="link su-add" onClick={onAddUser}>
              {t("sidebar.user.add")}
            </button>
          </div>
        </>
      )}
      <button
        className="settings-btn"
        title={t("settings.title")}
        onClick={(e) => {
          e.stopPropagation();
          onOpenSettings();
        }}
      >
        <Settings size={15} />
      </button>
    </div>
  );
}

// The collapsed rail's avatar button (it expands the sidebar). Always
// rendered; only its tooltip depends on the app-user.
export function RailAvatar({
  appUser,
  team,
  t,
  onExpand,
}: {
  appUser: string;
  team: string;
  t: Translate;
  onExpand: () => void;
}) {
  const block = sidebarUserBlock(appUser, team);
  return (
    <button className="rail-avatar-btn" title={t("sidebar.expand")} onClick={onExpand}>
      <span className="avatar" title={identityTitle(block, team, t)} />
    </button>
  );
}
