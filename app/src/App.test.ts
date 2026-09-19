import { describe, expect, it } from "vitest";
import {
  hasUnsafeDropPath,
  joinDroppedPaths,
  resolveFileDropTarget,
  shellPaneFrom,
  shellSplitStillValid,
  shellTabStillValid,
  shouldShowOutdatedBanner,
  shouldSuppressClickAfterDrag,
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
