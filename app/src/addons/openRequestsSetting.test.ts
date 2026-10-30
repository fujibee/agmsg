import { describe, expect, it } from "vitest";
import { createOpenRequestsSetting } from "./openRequestsSetting";

const fake = (writable = true) => {
  const data = new Map<string, string>();
  return {
    data,
    writable: { on: writable },
    store: {
      getItem: (k: string) => data.get(k) ?? null,
      setItem(k: string, v: string) {
        if (!fakeState.on) throw new Error("quota");
        data.set(k, v);
      },
    },
  };
};
let fakeState = { on: true };
const make = () => {
  const f = fake();
  fakeState = { on: true };
  let notified = 0;
  const s = createOpenRequestsSetting(() => f.store, () => notified++);
  return { s, f, set: (on: boolean) => (fakeState.on = on), notified: () => notified };
};

describe("open-requests setting", () => {
  it("defaults to show and stores the choice", () => {
    const { s, f } = make();
    expect(s.read()).toBe("show");
    s.write("off");
    expect(s.read()).toBe("off");
    expect(f.data.get("agmsg.addons.openRequests")).toBe("off");
  });
  it("an unsaved choice holds, and a later successful write clears it (off -> show comes back)", () => {
    const { s, set } = make();
    set(false);
    s.write("off");
    expect(s.read()).toBe("off");
    set(true);
    s.write("show");
    expect(s.read()).toBe("show");
  });
  it("an unsaved show wins over a stored off", () => {
    const { s, set, f } = make();
    s.write("off");
    set(false);
    s.write("show");
    expect(f.data.get("agmsg.addons.openRequests")).toBe("off");
    expect(s.read()).toBe("show");
  });
  it("no storage at all still works for the session", () => {
    const s = createOpenRequestsSetting(() => null, () => {});
    s.write("off");
    expect(s.read()).toBe("off");
    s.write("show");
    expect(s.read()).toBe("show");
  });
  it("every write tells the listeners", () => {
    const { s, notified, set } = make();
    s.write("off");
    set(false);
    s.write("show");
    expect(notified()).toBe(2);
  });
});
