import { describe, expect, it } from "vitest";
import {
  actasSpawnArgs,
  actionFailedToast,
  deleteTeamForceToast,
  deleteTeamToast,
  hasUnsafeDropPath,
  joinDroppedPaths,
  purgeMessagesToast,
  renameTeamInWindows,
  renameTeamKey,
  renameTeamToast,
  resolveFileDropTarget,
  shellPaneFrom,
  shellSplitStillValid,
  shellTabStillValid,
  shouldShowOutdatedBanner,
  shouldSuppressClickAfterDrag,
  shouldClearModalOnClose,
  spawnTargetWindowId,
  teamActionInvocation,
  type LoginShellInfo,
} from "./App";

describe("actasSpawnArgs", () => {
  it("claude-code: no cmd_prefix/prompt_arg -> bare '/<cmd> actas <name>' (unchanged)", () => {
    expect(actasSpawnArgs("agmsg", "alice", null, null)).toEqual(["/agmsg actas alice"]);
  });

  it("opencode: cmd_prefix '$' and prompt_arg '--prompt' -> ['--prompt', '$<cmd> actas <name>']", () => {
    expect(actasSpawnArgs("agmsg", "OC", "$", "--prompt")).toEqual(["--prompt", "$agmsg actas OC"]);
  });

  it("copilot: no cmd_prefix (defaults to '/') with prompt_arg '--interactive'", () => {
    expect(actasSpawnArgs("agmsg", "X", null, "--interactive")).toEqual(["--interactive", "/agmsg actas X"]);
  });
});

describe("shouldShowOutdatedBanner", () => {
  it("shows when outdated, not updating, and not dismissed", () => {
    expect(shouldShowOutdatedBanner({ installed: "1.1.0", pinned: "1.1.8" }, false, false)).toBe(true);
  });

  it("hides when not outdated (null)", () => {
    expect(shouldShowOutdatedBanner(null, false, false)).toBe(false);
  });

  it("hides while an update is in flight", () => {
    expect(shouldShowOutdatedBanner({ installed: "1.1.0", pinned: "1.1.8" }, true, false)).toBe(false);
  });

  it("hides once dismissed, independent of updatingCore", () => {
    expect(shouldShowOutdatedBanner({ installed: "1.1.0", pinned: "1.1.8" }, false, true)).toBe(false);
  });
});

describe("shouldSuppressClickAfterDrag", () => {
  it("suppresses a click on the SAME pane immediately after its drag finished", () => {
    expect(shouldSuppressClickAfterDrag({ paneId: "p1", finishedAt: 1_000 }, "p1", 1_010)).toBe(true);
  });

  it("suppresses a click at the tail end of the window", () => {
    expect(shouldSuppressClickAfterDrag({ paneId: "p1", finishedAt: 1_000 }, "p1", 1_299)).toBe(true);
  });

  it("does not suppress a click on a DIFFERENT pane, even immediately after", () => {
    // Regression (#481, 3rd round): a global timestamp with no pane
    // identity would suppress a deliberate click on some other pane header
    // too, just because it lands within the window of an unrelated pane's
    // drag finishing.
    expect(shouldSuppressClickAfterDrag({ paneId: "p1", finishedAt: 1_000 }, "p2", 1_010)).toBe(false);
  });

  it("does not suppress once consumed — a second click on the same pane isn't ALSO swallowed", () => {
    // The caller is expected to clear the ref (set it to null) after this
    // returns true — modeled here as the "already consumed" state.
    expect(shouldSuppressClickAfterDrag(null, "p1", 1_010)).toBe(false);
  });

  it("does not suppress a genuinely separate click once the window has passed", () => {
    // A drag that ends via blur or pointercancel with the pointer released
    // outside the app never gets a matching click to consume — an
    // unbounded "consume the next click" listener would sit on the button
    // forever and wrongly swallow the next, wholly unrelated click. The
    // bounded window must let it through.
    expect(shouldSuppressClickAfterDrag({ paneId: "p1", finishedAt: 1_000 }, "p1", 1_301)).toBe(false);
  });

  it("does not suppress when no drag has ever finished", () => {
    expect(shouldSuppressClickAfterDrag(null, "p1", 1_000_000)).toBe(false);
  });
});

describe("shellPaneFrom", () => {
  it("returns null when login_shell hasn't resolved — no guessed-shell fallback", () => {
    // Regression: an earlier version defaulted to "bash" here when the
    // async login_shell fetch hadn't landed yet, which broke on Windows
    // (no bash) and wasn't the user's actual login shell even on unix
    // (review, PR #431).
    expect(shellPaneFrom(null, "shell-1", "Shell", undefined)).toBeNull();
  });

  it("builds a shell pane from resolved login shell info", () => {
    const info: LoginShellInfo = { cmd: "/bin/zsh", args: ["-il"], home: "/Users/dev" };
    expect(shellPaneFrom(info, "shell-1", "Shell", "/Users/dev/project")).toEqual({
      id: "shell-1",
      label: "Shell",
      cmd: "/bin/zsh",
      args: ["-il"],
      cwd: "/Users/dev/project",
      native: false,
      shell: true,
    });
  });

  it("passes cwd through as-is, including undefined", () => {
    const info: LoginShellInfo = { cmd: "/bin/bash", args: ["-il"], home: "/home/dev" };
    expect(shellPaneFrom(info, "shell-2", "Shell", undefined)?.cwd).toBeUndefined();
  });
});

describe("shellTabStillValid", () => {
  it("stays valid when the team hasn't changed while getLoginShell was in flight", () => {
    expect(shellTabStillValid("teamA", "teamA")).toBe(true);
  });

  it("goes invalid when the user switched teams during the await", () => {
    // Regression: openShellTab used to commit the new window under the
    // stale (closed-over) team regardless, silently hiding it since only
    // the current team's windows render (#431).
    expect(shellTabStillValid("teamB", "teamA")).toBe(false);
  });
});

describe("shellSplitStillValid", () => {
  const windows = [
    { id: "w-1", team: "teamA" },
    { id: "w-2", team: "teamA" },
  ];

  it("stays valid when the target window is open and the team hasn't changed", () => {
    expect(shellSplitStillValid(windows, "w-1", "teamA", "teamA")).toBe(true);
  });

  it("goes false when the target window was closed during the await", () => {
    // Regression: openShellInWindow used to commit anyway, leaving an
    // orphaned pane and `active` pointing at a nonexistent window id (review,
    // PR #431).
    expect(shellSplitStillValid([{ id: "w-2", team: "teamA" }], "w-1", "teamA", "teamA")).toBe(false);
  });

  it("goes false against an empty window list", () => {
    expect(shellSplitStillValid([], "w-1", "teamA", "teamA")).toBe(false);
  });

  it("goes false when the team switched even though the window is still open", () => {
    // Regression (2nd round): the target window can survive the await
    // untouched but now belong to the team the user navigated away from —
    // it's a hidden tab at that point, so splitting into it and activating
    // it reproduces the same hidden-active bug shellTabStillValid guards
    // against on the new-tab path (#431).
    expect(shellSplitStillValid(windows, "w-1", "teamB", "teamA")).toBe(false);
  });
});

describe("hasUnsafeDropPath", () => {
  it("is false for ordinary paths", () => {
    expect(hasUnsafeDropPath(["/Users/dev/file.txt", "/a/b c.png"])).toBe(false);
  });

  it("catches a newline — could submit the target prompt on drop alone", () => {
    expect(hasUnsafeDropPath(["/Users/dev/evil\nrm -rf ~.txt"])).toBe(true);
  });

  it("catches a carriage return", () => {
    expect(hasUnsafeDropPath(["/Users/dev/evil\rfile.txt"])).toBe(true);
  });

  it("catches an ESC byte — terminal control sequence, not text", () => {
    expect(hasUnsafeDropPath(["/Users/dev/evil\x1bfile.txt"])).toBe(true);
  });

  it("catches DEL (\\u007f), just outside the C0 range", () => {
    expect(hasUnsafeDropPath(["/Users/dev/evil\x7ffile.txt"])).toBe(true);
  });

  it("is false for an empty list", () => {
    expect(hasUnsafeDropPath([])).toBe(false);
  });
});

describe("joinDroppedPaths", () => {
  it("joins multiple paths with a single space, unquoted", () => {
    // Deliberately bare, not shell-quoted — see joinDroppedPaths' own doc:
    // quoting broke Claude Code's own file-path recognition in live
    // testing, even though it's fine for Codex.
    expect(joinDroppedPaths(["/a/b.txt", "/c/d.txt"])).toBe("/a/b.txt /c/d.txt");
  });

  it("passes a path with a space through unquoted", () => {
    expect(joinDroppedPaths(["/Users/dev/my file.txt"])).toBe("/Users/dev/my file.txt");
  });

  it("returns an empty string for no paths", () => {
    expect(joinDroppedPaths([])).toBe("");
  });

  it("rejects the WHOLE drop — returns null, not a sanitized string — when any path has a control character", () => {
    // Regression (#481): a crafted filename containing a newline
    // written raw to the PTY would submit whatever's on the current prompt
    // line the instant the file is dropped. Rejecting outright (not
    // stripping the bad byte) avoids silently writing a DIFFERENT path than
    // what was actually dropped.
    expect(joinDroppedPaths(["/Users/dev/evil\nfile.txt", "/Users/dev/fine.txt"])).toBeNull();
  });
});

describe("resolveFileDropTarget", () => {
  const leaf = (paneId: string) => ({ kind: "leaf" as const, paneId });
  const windows = [
    {
      id: "w-1",
      root: { kind: "split" as const, axis: "col" as const, ratio: 0.5, a: leaf("p-1"), b: leaf("p-2") },
    },
  ];

  it("prefers the pane directly under the cursor when there is one", () => {
    expect(resolveFileDropTarget("p-hovered", windows, "w-1", null)).toBe("p-hovered");
  });

  it("falls back to the active tab's focused pane when nothing was hit", () => {
    // e.g. dropped on the sidebar or tab bar, not any pane cell. Follow-up
    // feedback: prefer the pane the user was actually using, not
    // just whichever leaf happens to be first in the tree.
    expect(resolveFileDropTarget(null, windows, "w-1", "p-2")).toBe("p-2");
  });

  it("falls back to the active window's first pane when nothing was hit and nothing is focused", () => {
    expect(resolveFileDropTarget(null, windows, "w-1", null)).toBe("p-1");
  });

  it("ignores a focused pane that belongs to a different (inactive) tab", () => {
    // lastFocusedPaneId is tracked globally, not per-tab — a stale value
    // from another tab must not steer a drop away from the active one.
    expect(resolveFileDropTarget(null, windows, "w-1", "p-from-another-tab")).toBe("p-1");
  });

  it("returns null when there's no active window to fall back to", () => {
    // e.g. Team Room is showing (active === "room"), no panes at all.
    expect(resolveFileDropTarget(null, windows, "room", null)).toBeNull();
  });
});

describe("teamActionInvocation", () => {
  // #1479: the sidebar's team context menu (Rename/Delete team/Delete
  // messages) must call the right agmsg command with the right args — a
  // wrong mapping here would silently run the wrong destructive action.
  it("maps rename to agmsg_rename_team with the old and new team names", () => {
    expect(teamActionInvocation("renameTeam", "old-team", { nextName: "new-team" })).toEqual({
      command: "agmsg_rename_team",
      args: { oldTeam: "old-team", newTeam: "new-team" },
    });
  });

  it("maps delete team to agmsg_delete_team with just the team", () => {
    expect(teamActionInvocation("deleteTeam", "my-team")).toEqual({
      command: "agmsg_delete_team",
      args: { team: "my-team" },
    });
  });

  it("maps delete messages to agmsg_purge_team_messages, not agmsg_delete_team", () => {
    expect(teamActionInvocation("purgeMessages", "my-team")).toEqual({
      command: "agmsg_purge_team_messages",
      args: { team: "my-team" },
    });
  });

  // #1493: escalating a refused --delete must add --force AND keep
  // --purge-messages independently opt-in, never on by default.
  it("maps the force-delete escalation to agmsg_delete_team_force with purgeMessages defaulting to false", () => {
    expect(teamActionInvocation("deleteTeamForce", "my-team")).toEqual({
      command: "agmsg_delete_team_force",
      args: { team: "my-team", purgeMessages: false },
    });
  });

  it("maps the force-delete escalation with the purge-messages checkbox checked", () => {
    expect(teamActionInvocation("deleteTeamForce", "my-team", { purgeMessages: true })).toEqual({
      command: "agmsg_delete_team_force",
      args: { team: "my-team", purgeMessages: true },
    });
  });
});

describe("shouldClearModalOnClose", () => {
  it("clears when the modal is still the one that opened the confirm", () => {
    expect(shouldClearModalOnClose({ kind: "deleteTeam" }, "deleteTeam")).toBe(true);
  });

  it("does not clear when onConfirm already swapped in a different modal", () => {
    // Regression (#1484 review): deleting the LAST team reopens the
    // first-run "create a team" modal from inside onDeleteTeam via
    // settleActiveTeam. ConfirmModal's own onClose fires right after and,
    // without this guard, would stomp the new modal back to null.
    const reopenedModal: { kind: string; firstRun: boolean } = { kind: "team", firstRun: true };
    expect(shouldClearModalOnClose(reopenedModal, "deleteTeam")).toBe(false);
  });

  it("is a no-op against an already-null modal", () => {
    expect(shouldClearModalOnClose(null, "deleteTeam")).toBe(false);
  });
});

describe("completion toast builders", () => {
  // #1484 review, round 3: rename/delete-team/delete-messages had no
  // feedback at all once their modal had already closed. Each builder
  // returns the i18n key + vars (not a rendered string) so this stays
  // testable without a translation context — the actual t() call happens
  // at push time, inside the component.
  it("builds the rename-team toast from the old and new names", () => {
    expect(renameTeamToast("A", "B")).toEqual({ key: "toast.renameTeam", vars: { from: "A", to: "B" } });
  });

  it("builds the plain delete-team toast from just the team name", () => {
    expect(deleteTeamToast("my-team")).toEqual({ key: "toast.deleteTeam", vars: { team: "my-team" } });
  });

  it("builds the force-delete toast with the removed member count", () => {
    expect(deleteTeamForceToast("my-team", 3)).toEqual({
      key: "toast.deleteTeamForce",
      vars: { team: "my-team", count: 3 },
    });
  });

  it("builds the purge-messages toast from the team name", () => {
    expect(purgeMessagesToast("my-team")).toEqual({ key: "toast.purgeMessages", vars: { team: "my-team" } });
  });

  it("builds the generic failure toast from the raw reason", () => {
    expect(actionFailedToast("Team 'my-team' is actively synced; refusing to delete or purge its data.")).toEqual({
      key: "toast.actionFailed",
      vars: { reason: "Team 'my-team' is actively synced; refusing to delete or purge its data." },
    });
  });
});

describe("spawnTargetWindowId", () => {
  const windows = [
    { id: "w-mine", team: "alpha" },
    { id: "w-other-team", team: "beta" },
  ];

  it("viewing a pane tab of the current team -> that tab", () => {
    expect(spawnTargetWindowId(windows, "w-mine", "alpha")).toBe("w-mine");
  });

  it("viewing the team room -> a new tab (undefined)", () => {
    expect(spawnTargetWindowId(windows, "room", "alpha")).toBeUndefined();
  });

  it("viewing a pane tab that belongs to another team -> a new tab (undefined)", () => {
    expect(spawnTargetWindowId(windows, "w-other-team", "alpha")).toBeUndefined();
  });
});

describe("renameTeamInWindows", () => {
  // Regression: a tab spawned under a team stayed tagged with that team's
  // OLD name after a rename, and the sidebar only ever renders
  // `w.team === team` for the current (now-renamed) team — so the tab's
  // PTY kept running but its tab vanished from the tab bar entirely.
  const windows = [
    { id: "w-1", team: "old-team" },
    { id: "w-2", team: "old-team" },
    { id: "w-3", team: "other-team" },
  ];

  it("repoints every window tagged with the old team name to the new one", () => {
    const result = renameTeamInWindows(windows, "old-team", "new-team");
    expect(result.filter((w) => w.team === "new-team").map((w) => w.id)).toEqual(["w-1", "w-2"]);
  });

  it("leaves windows belonging to a different team untouched", () => {
    const result = renameTeamInWindows(windows, "old-team", "new-team");
    expect(result.find((w) => w.id === "w-3")).toEqual({ id: "w-3", team: "other-team" });
  });

  it("is a no-op when no window belongs to the renamed team", () => {
    expect(renameTeamInWindows(windows, "nonexistent-team", "new-team")).toEqual(windows);
  });
});

describe("renameTeamKey", () => {
  // lastActiveTabByTeam (the other team-keyed state a rename must follow,
  // same regression) is a Record<string, string>, but this is generic —
  // any future team-keyed state can reuse it.
  it("moves the old team's entry to the new key", () => {
    expect(renameTeamKey({ "old-team": "w-1", "other-team": "w-3" }, "old-team", "new-team")).toEqual({
      "other-team": "w-3",
      "new-team": "w-1",
    });
  });

  it("is a no-op (same reference) when the old team has no entry", () => {
    const byTeam = { "other-team": "w-3" };
    expect(renameTeamKey(byTeam, "old-team", "new-team")).toBe(byTeam);
  });
});
