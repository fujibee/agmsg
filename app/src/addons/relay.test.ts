import { describe, expect, it } from "vitest";
import { base64ToArrayBuffer, toPortMessage, type BrokerResponse } from "./relay";

const ok = (result: Record<string, unknown>): BrokerResponse => ({ agmsg: 1, type: "response", ok: true, result });

describe("base64ToArrayBuffer", () => {
  it("decodes bytes exactly, including 0x00 and 0xff", () => {
    const buf = base64ToArrayBuffer("AAEC//4="); // 00 01 02 ff fe
    expect(Array.from(new Uint8Array(buf))).toEqual([0, 1, 2, 255, 254]);
  });
  it("decodes the empty string to an empty buffer", () => {
    expect(base64ToArrayBuffer("").byteLength).toBe(0);
  });
  it("refuses malformed input", () => {
    for (const bad of ["A", "AAE", "AA=A", "!!!!", "AAEC//4=\n", "AAEC//4==="]) {
      expect(() => base64ToArrayBuffer(bad)).toThrow();
    }
  });
});

describe("toPortMessage", () => {
  it("turns bytesBase64 into an ArrayBuffer named bytes and transfers it", () => {
    const { message, transfer } = toPortMessage(7, ok({ bytesBase64: "AAEC//4=", size: 5, eof: true }));
    const r = message.result as Record<string, unknown>;
    expect(message).toMatchObject({ agmsg: 1, type: "response", id: 7, ok: true });
    expect(r.bytesBase64).toBeUndefined();
    expect(r.bytes).toBeInstanceOf(ArrayBuffer);
    expect(Array.from(new Uint8Array(r.bytes as ArrayBuffer))).toEqual([0, 1, 2, 255, 254]);
    expect(r.size).toBe(5);
    expect(r.eof).toBe(true);
    expect(transfer).toEqual([r.bytes]);
    expect(JSON.stringify(message)).not.toContain("AAEC");
  });
  it("leaves text and list results untouched", () => {
    const text = toPortMessage(1, ok({ text: "hi", size: 2, eof: true }));
    expect(text.message.result).toEqual({ text: "hi", size: 2, eof: true });
    expect(text.transfer).toEqual([]);
    const list = toPortMessage(2, ok({ entries: [{ name: "a", kind: "file", size: 1, mtime: "x" }], truncated: false }));
    expect((list.message.result as { entries: unknown[] }).entries).toHaveLength(1);
  });
  it("does not mutate the broker's object", () => {
    const resp = ok({ bytesBase64: "AAEC//4=", size: 5, eof: true });
    toPortMessage(1, resp);
    expect((resp.result as Record<string, unknown>).bytesBase64).toBe("AAEC//4=");
  });
  it("passes an error through with its code", () => {
    const { message } = toPortMessage(3, { agmsg: 1, type: "response", ok: false, error: { code: "denied_path", message: "no" } });
    expect(message).toEqual({ agmsg: 1, type: "response", id: 3, ok: false, error: { code: "denied_path", message: "no" } });
  });
  it("turns malformed answers into an error response instead of throwing", () => {
    const bad = toPortMessage(4, ok({ bytesBase64: "not base64!" }));
    expect(bad.message).toMatchObject({ id: 4, ok: false, error: { code: "error" } });
    expect(bad.transfer).toEqual([]);
    const garbage = toPortMessage(5, null as unknown as BrokerResponse);
    expect(garbage.message).toMatchObject({ id: 5, ok: false });
    const notResp = toPortMessage(6, { agmsg: 2 } as unknown as BrokerResponse);
    expect(notResp.message).toMatchObject({ id: 6, ok: false });
  });
  it("an error without detail still has a code and a message", () => {
    const { message } = toPortMessage(8, { agmsg: 1, type: "response", ok: false });
    expect(message).toMatchObject({ ok: false, error: { code: "error" } });
  });
});
