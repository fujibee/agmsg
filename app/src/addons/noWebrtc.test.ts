import { describe, expect, it } from "vitest";
import script from "../../src-tauri/src/addons/no_webrtc.js?raw";

const runInNewContext = (code: string, win: Record<string, unknown>) => new Function("window", code)(win);
const names = ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCSessionDescription", "RTCDataChannel", "RTCIceCandidate"];

describe("the Windows WebRTC removal script", () => {
  it("removes the API, and pins a name that cannot be deleted to undefined", () => {
    const win: Record<string, unknown> = {};
    for (const n of names) win[n] = function () {};
    Object.defineProperty(win, "RTCCertificate", { value: function () {}, configurable: false, writable: true });
    win.window = win;
    runInNewContext(script, win);
    for (const n of [...names, "RTCCertificate"]) {
      expect(typeof win[n]).toBe("undefined");
    }
    // the one that could not be deleted is pinned to undefined
    expect(() => { win.RTCCertificate = function () {}; }).toThrow();
  });
  it("does not throw when a name is absent already", () => {
    const win: Record<string, unknown> = {};
    win.window = win;
    expect(() => runInNewContext(script, win)).not.toThrow();
  });
});
