import { describe, expect, it } from "vitest";
import {
  shellPaneFrom,
  shellSplitStillValid,
  shellTabStillValid,
  shouldShowOutdatedBanner,
  type LoginShellInfo,
} from "./App";

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

describe("shellPaneFrom", () => {
  it("returns null when login_shell hasn't resolved — no guessed-shell fallback", () => {
    // Regression: an earlier version defaulted to "bash" here when the
    // async login_shell fetch hadn't landed yet, which broke on Windows
    // (no bash) and wasn't the user's actual login shell even on unix
    // (co1 review, PR #431).
    expect(shellPaneFrom(null, "shell-1", "Shell", undefined)).toBeNull();
  });

  it("builds a shell pane from resolved login shell info", () => {
    const info: LoginShellInfo = { cmd: "/bin/zsh", args: ["-il"], home: "/Users/koit" };
    expect(shellPaneFrom(info, "shell-1", "Shell", "/Users/koit/project")).toEqual({
      id: "shell-1",
      label: "Shell",
      cmd: "/bin/zsh",
      args: ["-il"],
      cwd: "/Users/koit/project",
      native: false,
      shell: true,
    });
  });

  it("passes cwd through as-is, including undefined", () => {
    const info: LoginShellInfo = { cmd: "/bin/bash", args: ["-il"], home: "/home/koit" };
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
    // the current team's windows render (co1, PR #431).
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
    // orphaned pane and `active` pointing at a nonexistent window id (co1,
    // PR #431).
    expect(shellSplitStillValid([{ id: "w-2", team: "teamA" }], "w-1", "teamA", "teamA")).toBe(false);
  });

  it("goes false against an empty window list", () => {
    expect(shellSplitStillValid([], "w-1", "teamA", "teamA")).toBe(false);
  });

  it("goes false when the team switched even though the window is still open", () => {
    // Regression (2nd co1 round): the target window can survive the await
    // untouched but now belong to the team the user navigated away from —
    // it's a hidden tab at that point, so splitting into it and activating
    // it reproduces the same hidden-active bug shellTabStillValid guards
    // against on the new-tab path (co1, PR #431).
    expect(shellSplitStillValid(windows, "w-1", "teamB", "teamA")).toBe(false);
  });
});
