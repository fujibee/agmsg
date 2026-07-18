import { describe, expect, it } from "vitest";
import { shellPaneFrom, shouldShowOutdatedBanner, type LoginShellInfo } from "./App";

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
