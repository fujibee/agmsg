import { describe, expect, it } from "vitest";
import { MAX_PAYLOAD_BYTES, OPEN_PANE_HEADER, parseOpenRequest, parsePane } from "./openRequest";

const payload = (o: Record<string, unknown> = {}) =>
  JSON.stringify({ pane: "diffview", args: { path: "/p", base: "main" }, requester: { member_id: "m1", token: "tok" }, request_id: "r1", ...o });
const body = (o?: Record<string, unknown>) => `${OPEN_PANE_HEADER}\n${payload(o)}`;
const refusal = (b: string) => {
  const r = parseOpenRequest(b);
  return r.kind === "refused" ? r : null;
};

describe("parseOpenRequest", () => {
  it("parses a well-formed request", () => {
    const r = parseOpenRequest(body());
    expect(r).toMatchObject({
      kind: "request",
      request: { pane: "diffview", target: { kind: "diffview" }, args: { path: "/p", base: "main" }, requester: { memberId: "m1", token: "tok" }, requestId: "r1" },
    });
  });
  it("treats anything without the exact header as an ordinary message", () => {
    for (const b of ["hello", "", `${OPEN_PANE_HEADER} `, ` ${OPEN_PANE_HEADER}\n${payload()}`, `agmsg-ctrl v2 ctrl.app_open_pane\n${payload()}`, `note\n${body()}`]) {
      expect(parseOpenRequest(b).kind, b).toBe("none");
    }
  });
  it("accepts CRLF and trailing blank lines, refuses other trailing content", () => {
    expect(parseOpenRequest(body().replace("\n", "\r\n") + "\n\n").kind).toBe("request");
    expect(refusal(body() + "\nmore")?.reason).toBe("extra_content");
  });
  it("refuses a missing second line", () => {
    expect(refusal(OPEN_PANE_HEADER)?.reason).toBe("missing_payload");
    expect(refusal(`${OPEN_PANE_HEADER}\n`)?.reason).toBe("missing_payload");
  });
  it("refuses a payload over 2 KB, counted in bytes", () => {
    const long = body({ args: { path: "あ".repeat(MAX_PAYLOAD_BYTES / 3) } });
    expect(refusal(long)?.reason).toBe("too_large");
    expect(parseOpenRequest(body({ args: { path: "a".repeat(100) } })).kind).toBe("request");
  });
  it("refuses bad JSON and non-object JSON", () => {
    expect(refusal(`${OPEN_PANE_HEADER}\n{nope`)?.reason).toBe("bad_json");
    expect(refusal(`${OPEN_PANE_HEADER}\n[1]`)?.reason).toBe("bad_shape");
    expect(refusal(`${OPEN_PANE_HEADER}\n"x"`)?.reason).toBe("bad_shape");
  });
  it("refuses an unknown pane, and names it", () => {
    expect(refusal(body({ pane: "terminal" }))).toMatchObject({ reason: "bad_pane", detail: "terminal" });
    expect(refusal(body({ pane: "addon:a/b" }))?.reason).toBe("bad_pane");
    expect(refusal(body({ pane: 3 }))?.reason).toBe("bad_pane");
  });
  it("refuses an unknown args key and shows which", () => {
    expect(refusal(body({ args: { path: "/p", cmd: "rm" } }))).toMatchObject({ reason: "unknown_arg_key", detail: "cmd" });
  });
  it("refuses non-string or empty arg values", () => {
    expect(refusal(body({ args: { path: 5 } }))?.reason).toBe("bad_arg_value");
    expect(refusal(body({ args: { path: "" } }))?.reason).toBe("bad_arg_value");
  });
  it("the requester token is optional", () => {
    const r = parseOpenRequest(body({ requester: { member_id: "m1" } }));
    expect(r).toMatchObject({ kind: "request", request: { requester: { memberId: "m1", token: undefined } } });
  });
  it("requires nested requester and a request_id; the flat form is gone", () => {
    expect(refusal(body({ requester: undefined, requester_member_id: "m1" }))?.reason).toBe("bad_requester");
    expect(refusal(body({ requester: { member_id: "m1", token: 5 } }))?.reason).toBe("bad_requester");
    expect(refusal(body({ requester: { member_id: "m1", token: "" } }))?.reason).toBe("bad_requester");
    expect(refusal(body({ requester: { token: "t" } }))?.reason).toBe("bad_requester");
    expect(refusal(body({ request_id: "" }))?.reason).toBe("bad_request_id");
    expect(refusal(body({ request_id: undefined }))?.reason).toBe("bad_request_id");
  });
  it("parses add-on panes", () => {
    const r = parseOpenRequest(body({ pane: "addon:shinshin86/agmsg-office/agmsg-office", args: {} }));
    expect(r).toMatchObject({ kind: "request", request: { target: { kind: "addon", owner: "shinshin86", repo: "agmsg-office", pane: "agmsg-office" } } });
  });
});

describe("parsePane", () => {
  it("rejects path-like and over-long names", () => {
    expect(parsePane("addon:a/b/../c")).toBeNull();
    expect(parsePane("addon:a/b/c/d")).toBeNull();
    expect(parsePane("fileview ")).toBeNull();
  });
});
