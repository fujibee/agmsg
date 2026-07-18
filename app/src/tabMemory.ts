// Pure selection logic for "which tab should be active when we switch onto
// a team" (see the team-change layout effect in App.tsx). Kept separate from
// App.tsx, and DOM/React-free, so it's unit-testable without a rendered
// component (this repo's convention — see paneTree.ts).

// Resolves the tab to activate for a team we're switching onto.
//
// `remembered` is the tab id this team was left on last time (undefined on
// first visit this session). It's only usable if that tab still exists:
// "room" is usable only while Team Room is currently shown (it disappears
// from the tab bar entirely when toggled off — see showTeamRoom in App.tsx),
// and a window id is usable only if it's still in `openWindowIds`.
//
// When the remembered tab isn't usable, fall back to Team Room if it's
// shown, else the team's first open window, else Team Room anyway (there's
// nothing else to land on if a team has neither).
export function resolveActiveTab(
  remembered: string | undefined,
  showTeamRoom: boolean,
  openWindowIds: string[],
): string {
  const usable =
    remembered === "room" ? showTeamRoom : remembered !== undefined && openWindowIds.includes(remembered);
  if (usable) return remembered as string;
  return showTeamRoom ? "room" : (openWindowIds[0] ?? "room");
}
