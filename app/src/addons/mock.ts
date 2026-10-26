// Mock data for the add-on screens, shaped like the Rust records in the
// design (§3.1 index/grants, §2 permissions). The wiring later swaps this
// source for the Tauri commands; the screens read only AddonsSnapshot.

import type { RequestScan } from "./requests";
import type { AddonsSnapshot, EngineState, GrantNeed, InstallError, StagedInstall } from "./types";

export const mockSnapshot: AddonsSnapshot = {
  addons: [
    {
      id: "builtin:fileview",
      builtin: true,
      sha: "",
      archiveSha256: "",
      payloadDigest: "",
      installedAt: "",
      enabled: true,
      panes: [
        {
          name: "fileview",
          title: "File view",
          permissions: ["files:read"],
          network: { kind: "none" },
          opens: "path",
          why: { "files:read": "Shows the files in the folder you choose." },
        },
      ],
    },
    {
      id: "builtin:diffview",
      builtin: true,
      sha: "",
      archiveSha256: "",
      payloadDigest: "",
      installedAt: "",
      enabled: true,
      panes: [
        {
          name: "diffview",
          title: "Diff view",
          permissions: ["files:read", "git:read"],
          network: { kind: "none" },
          opens: "path",
          why: {
            "files:read": "Reads the files in the repository you choose.",
            "git:read": "Reads its history and changes.",
          },
        },
      ],
    },
    {
      id: "shinshin86/agmsg-office",
      builtin: false,
      sha: "67722c2a1f0e4b3d9a58c0de1b7f6a4c2e9d8b13",
      archiveSha256: "9f2c1e7a40b6d85e3a1c7f0b2d94e68a5c3b17d0e4f2a96b8c15d7e03a4b9f21",
      payloadDigest: "3b8e0d6f1a47c925e8d0b3a6f14c72e95d0a8b31c6e4f7092a5d1b8c3e60f47a",
      installedAt: "2026-10-20T09:12:00Z",
      enabled: true,
      panes: [
        {
          name: "agmsg-office",
          title: "agmsg office",
          permissions: ["messages:read", "network"],
          network: { kind: "origins", origins: ["https://fonts.example.com"] },
          opens: "",
          why: { "messages:read": "Draws the team's messages as an office." },
        },
      ],
    },
  ],
  grants: [
    {
      addonId: "shinshin86/agmsg-office",
      pane: "agmsg-office",
      permission: "messages:read",
      scope: "agmsg",
      remember: true,
      grantedAt: "2026-10-20T09:14:00Z",
    },
    {
      addonId: "builtin:diffview",
      pane: "diffview",
      permission: "files:read",
      scope: "/Users/me/proj/agmsg",
      remember: true,
      grantedAt: "2026-10-21T13:02:00Z",
    },
  ],
  openRequests: "show",
};

export const mockEngine: EngineState = { ok: true };
export const mockEngineOff: EngineState = { ok: false, reasons: ["WebView2 128.0: navigation control could not be verified"] };

export const mockGrantNeeds: Record<string, GrantNeed> = {
  messages: { permission: "messages:read", team: "agmsg" },
  files: { permission: "files:read", path: "/Users/me/proj/agmsg", fileCount: 1240, denied: false },
  filesDenied: { permission: "files:read", path: "/Users/me/.ssh", fileCount: null, denied: true },
};

/** One example of every install failure, for the screens and their tests. */
export const mockInstallErrors: InstallError[] = [
  { code: "repo_not_found", owner: "someone", repo: "missing" },
  { code: "ref_not_found", repo: "someone/repo", ref: "v9" },
  { code: "no_app_panes", repo: "someone/repo" },
  { code: "conf_invalid", pane: "view", line: 4, problem: "unknown permission \"files:write\"" },
  { code: "entry_missing", pane: "view", entry: "index.html" },
  { code: "min_app", minApp: "0.7.0", appVersion: "0.5.0" },
  { code: "protocol_unknown", protocol: 2 },
  { code: "too_large", measured: "63 MB", limit: "50 MB", largestFile: "web/assets/big.png" },
  { code: "unsafe_entry", what: "symlink", path: "web/link" },
  { code: "github_error", status: 502 },
  { code: "rate_limited", retryAfter: "10:42" },
  { code: "already_installed", sha: "67722c2" },
];

/** What a successful fetch of `owner/repo` stages, on mock data. */
export function mockStage(owner: string, repo: string): StagedInstall {
  return {
    addonId: `${owner}/${repo}`,
    title: repo,
    sha: "d41d8cd98f00b204e9800998ecf8427e1a2b3c4d",
    archiveSha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    panes: [
      {
        name: repo,
        title: repo,
        permissions: ["files:read"],
        network: { kind: "none" },
        opens: "path",
        why: { "files:read": "Shows the files you open it with." },
      },
    ],
  };
}

/** The S10 bar in a plain browser (no Tauri): what the host would hand back for three request lines. */
export const mockOpenView: RequestScan = {
  items: [
    { requestId: "1:0", from: "alice", team: "agmsg", at: "2026-10-22T08:40:00Z", addonId: "builtin:diffview", pane: "diffview", path: "/Users/me/proj/agmsg", status: "open" },
    { requestId: "2:0", from: "alice", team: "agmsg", at: "2026-10-22T08:41:00Z", addonId: "someone/viewer", pane: "viewer", status: "not_installed", installTarget: "someone/viewer" },
    { requestId: "3:0", from: "alice", team: "agmsg", at: "2026-10-22T08:42:00Z", addonId: "builtin:fileview", pane: "fileview", path: "/Users/me/missing", status: "not_found_here" },
  ],
  notes: new Map([["4:1", { kind: "malformed", reason: "bad_option", detail: "url=https://example.com" }]]),
};
