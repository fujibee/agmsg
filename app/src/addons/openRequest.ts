// Parser for the interim carrier of `ctrl.app_open_pane` (design §7, CP5 v1.3
// §8–§9). Pure: the input is a message body, the output is "not a request", a
// parsed request, or a refusal with a reason the bar shows. The payload shape
// may still change, so everything that knows it lives in this one file.
//
//   agmsg-ctrl v1 ctrl.app_open_pane
//   {"pane":"diffview","args":{"path":"…","base":"main"},"requester":{"member_id":"…","token":"…"},"request_id":"…"}

export const OPEN_PANE_HEADER = "agmsg-ctrl v1 ctrl.app_open_pane";
export const MAX_PAYLOAD_BYTES = 2048;
export const ARG_KEYS = ["path", "url", "base"] as const;
export type ArgKey = (typeof ARG_KEYS)[number];

export type PaneTarget =
  | { kind: "fileview" }
  | { kind: "diffview" }
  | { kind: "browser" }
  | { kind: "addon"; owner: string; repo: string; pane: string };

export type OpenRequest = {
  /** The pane name exactly as sent (`fileview`, `addon:owner/repo/pane`, …). */
  pane: string;
  target: PaneTarget;
  args: Partial<Record<ArgKey, string>>;
  requester: { memberId: string; /** Optional in the interim form: seats without a claim token send none. */ token?: string };
  requestId: string;
};

export type RefusalReason =
  | "missing_payload"
  | "extra_content"
  | "too_large"
  | "bad_json"
  | "bad_shape"
  | "bad_pane"
  | "unknown_arg_key"
  | "bad_arg_value"
  | "bad_requester"
  | "bad_request_id"
  | "request_id_reused"; // reported by the host when a later message reuses an id with different content

export type ParseResult =
  | { kind: "none" } // an ordinary message
  | { kind: "request"; request: OpenRequest }
  | { kind: "refused"; reason: RefusalReason; detail?: string };

const ADDON_PANE = /^addon:([A-Za-z0-9][A-Za-z0-9-]{0,38})\/([A-Za-z0-9._-]{1,100})\/([A-Za-z0-9._-]{1,100})$/;

export function parsePane(pane: string): PaneTarget | null {
  if (pane === "fileview" || pane === "diffview" || pane === "browser") return { kind: pane };
  const m = ADDON_PANE.exec(pane);
  return m ? { kind: "addon", owner: m[1], repo: m[2], pane: m[3] } : null;
}

const utf8Length = (s: string) => new TextEncoder().encode(s).length;
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const isNonEmptyString = (v: unknown): v is string => typeof v === "string" && v.length > 0;

export function parseOpenRequest(body: string): ParseResult {
  const lines = body.replace(/\r\n/g, "\n").split("\n");
  if (lines[0] !== OPEN_PANE_HEADER) return { kind: "none" };
  const payload = lines[1];
  if (payload === undefined || payload.trim() === "") return { kind: "refused", reason: "missing_payload" };
  if (lines.slice(2).some((l) => l.trim() !== "")) return { kind: "refused", reason: "extra_content" };
  if (utf8Length(payload) > MAX_PAYLOAD_BYTES) return { kind: "refused", reason: "too_large" };

  let json: unknown;
  try {
    json = JSON.parse(payload);
  } catch {
    return { kind: "refused", reason: "bad_json" };
  }
  if (!isObject(json)) return { kind: "refused", reason: "bad_shape" };

  if (typeof json.pane !== "string") return { kind: "refused", reason: "bad_pane" };
  const target = parsePane(json.pane);
  if (!target) return { kind: "refused", reason: "bad_pane", detail: json.pane };

  if (!isObject(json.args)) return { kind: "refused", reason: "bad_shape", detail: "args" };
  const args: OpenRequest["args"] = {};
  for (const [key, value] of Object.entries(json.args)) {
    if (!(ARG_KEYS as readonly string[]).includes(key)) return { kind: "refused", reason: "unknown_arg_key", detail: key };
    if (!isNonEmptyString(value)) return { kind: "refused", reason: "bad_arg_value", detail: key };
    args[key as ArgKey] = value;
  }

  const r = json.requester;
  if (!isObject(r) || !isNonEmptyString(r.member_id) || (r.token !== undefined && !isNonEmptyString(r.token))) {
    return { kind: "refused", reason: "bad_requester" };
  }
  if (!isNonEmptyString(json.request_id)) return { kind: "refused", reason: "bad_request_id" };

  return {
    kind: "request",
    request: { pane: json.pane, target, args, requester: { memberId: r.member_id, token: r.token as string | undefined }, requestId: json.request_id },
  };
}
