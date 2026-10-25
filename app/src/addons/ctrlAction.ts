// One click on Open or Dismiss, with the rule that its answer counts only while
// the scope it started in (team, add-ons on, tab mounted) is still current.
// Rust has already recorded the decision by the time the answer arrives; a stale
// answer must not open a pane, set a message, or re-read rows for an old team.

import type { CommandError, Outcome } from "./source";
import type { CtrlOpened } from "./ctrl";

export type CtrlActionDeps = {
  /** True while the scope the click started in is still the current one. */
  current: () => boolean;
  open: () => Promise<Outcome<CtrlOpened>>;
  dismiss: () => Promise<Outcome<null>>;
  onOpened: (o: CtrlOpened) => void;
  setError: (e: CommandError) => void;
  refresh: () => Promise<void>;
};

export async function runCtrlAction(opened: boolean, d: CtrlActionDeps): Promise<void> {
  if (opened) {
    const r = await d.open();
    if (!d.current()) return;
    if (r.ok) d.onOpened(r.value);
    else d.setError(r.error);
  } else {
    const r = await d.dismiss();
    if (!d.current()) return;
    if (!r.ok) d.setError(r.error);
  }
  await d.refresh();
}
