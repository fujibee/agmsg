import { describe, expect, it, vi } from "vitest";
import { createWriteBatcher } from "./writeBatcher";

const bytes = (s: string) => new TextEncoder().encode(s);
const text = (b: Uint8Array) => new TextDecoder().decode(b);

// Fully manual/injected scheduling — no real timers or requestAnimationFrame
// — so every test controls exactly which of (frame, timer, byte threshold)
// fires first, deterministically.
function fakeSchedulers() {
  let nextHandle = 1;
  const frameCallbacks = new Map<number, () => void>();
  const timerCallbacks = new Map<number, () => void>();
  return {
    requestFrame: vi.fn((cb: () => void) => {
      const h = nextHandle++;
      frameCallbacks.set(h, cb);
      return h;
    }),
    cancelFrame: vi.fn((h: number) => frameCallbacks.delete(h)),
    setTimer: vi.fn((cb: () => void, _ms: number) => {
      const h = nextHandle++;
      timerCallbacks.set(h, cb);
      return h as unknown as ReturnType<typeof setTimeout>;
    }),
    clearTimer: vi.fn((h: ReturnType<typeof setTimeout>) => timerCallbacks.delete(h as unknown as number)),
    fireFrame: () => {
      const [h, cb] = [...frameCallbacks.entries()][0];
      frameCallbacks.delete(h);
      cb();
    },
    fireTimer: () => {
      const [h, cb] = [...timerCallbacks.entries()][0];
      timerCallbacks.delete(h);
      cb();
    },
  };
}

describe("createWriteBatcher", () => {
  it("does not flush until the frame callback fires", () => {
    const s = fakeSchedulers();
    const onFlush = vi.fn();
    const batcher = createWriteBatcher({ onFlush, ...s });
    batcher.push(bytes("hi"));
    expect(onFlush).not.toHaveBeenCalled();
    s.fireFrame();
    expect(onFlush).toHaveBeenCalledTimes(1);
    expect(text(onFlush.mock.calls[0][0])).toBe("hi");
  });

  it("flushes via the latency timer if the frame never fires (backgrounded webview)", () => {
    const s = fakeSchedulers();
    const onFlush = vi.fn();
    const batcher = createWriteBatcher({ onFlush, ...s });
    batcher.push(bytes("bg"));
    // Simulate a suspended requestAnimationFrame: only the timer fires.
    s.fireTimer();
    expect(onFlush).toHaveBeenCalledTimes(1);
    expect(text(onFlush.mock.calls[0][0])).toBe("bg");
  });

  it("cancels the timer once the frame fires first", () => {
    const s = fakeSchedulers();
    const batcher = createWriteBatcher({ onFlush: vi.fn(), ...s });
    batcher.push(bytes("x"));
    s.fireFrame();
    expect(s.clearTimer).toHaveBeenCalledTimes(1);
  });

  it("cancels the frame once the timer fires first", () => {
    const s = fakeSchedulers();
    const batcher = createWriteBatcher({ onFlush: vi.fn(), ...s });
    batcher.push(bytes("x"));
    s.fireTimer();
    expect(s.cancelFrame).toHaveBeenCalledTimes(1);
  });

  it("flushes immediately once pending bytes reach the threshold, without waiting for scheduling", () => {
    const s = fakeSchedulers();
    const onFlush = vi.fn();
    const batcher = createWriteBatcher({ onFlush, maxPendingBytes: 5, ...s });
    batcher.push(bytes("abc")); // 3 bytes, schedules
    expect(onFlush).not.toHaveBeenCalled();
    batcher.push(bytes("def")); // total 6 >= 5 -> flush now, cancels the schedule
    expect(onFlush).toHaveBeenCalledTimes(1);
    expect(text(onFlush.mock.calls[0][0])).toBe("abcdef");
    expect(s.cancelFrame).toHaveBeenCalledTimes(1);
    expect(s.clearTimer).toHaveBeenCalledTimes(1);
  });

  it("merges multiple pushed chunks in arrival order", () => {
    const s = fakeSchedulers();
    const onFlush = vi.fn();
    const batcher = createWriteBatcher({ onFlush, ...s });
    batcher.push(bytes("one-"));
    batcher.push(bytes("two-"));
    batcher.push(bytes("three"));
    s.fireFrame();
    expect(text(onFlush.mock.calls[0][0])).toBe("one-two-three");
  });

  it("only schedules once across multiple pushes before a flush", () => {
    const s = fakeSchedulers();
    const batcher = createWriteBatcher({ onFlush: vi.fn(), ...s });
    batcher.push(bytes("a"));
    batcher.push(bytes("b"));
    batcher.push(bytes("c"));
    expect(s.requestFrame).toHaveBeenCalledTimes(1);
    expect(s.setTimer).toHaveBeenCalledTimes(1);
  });

  it("dispose cancels any pending schedule and drops buffered data without flushing", () => {
    const s = fakeSchedulers();
    const onFlush = vi.fn();
    const batcher = createWriteBatcher({ onFlush, ...s });
    batcher.push(bytes("never written"));
    batcher.dispose();
    expect(s.cancelFrame).toHaveBeenCalledTimes(1);
    expect(s.clearTimer).toHaveBeenCalledTimes(1);
    expect(onFlush).not.toHaveBeenCalled();
  });

  it("dispose is permanent — a push() arriving after dispose (e.g. a Tauri listener that resolved late, after its owning component already tore down) must not resurrect scheduling or flush", () => {
    const s = fakeSchedulers();
    const onFlush = vi.fn();
    const batcher = createWriteBatcher({ onFlush, ...s });
    batcher.dispose();
    s.requestFrame.mockClear();
    s.setTimer.mockClear();
    batcher.push(bytes("late arrival"));
    expect(s.requestFrame).not.toHaveBeenCalled();
    expect(s.setTimer).not.toHaveBeenCalled();
    expect(onFlush).not.toHaveBeenCalled();
    // Even an explicit flushNow() call must stay inert post-dispose.
    batcher.flushNow();
    expect(onFlush).not.toHaveBeenCalled();
  });

  it("flushNow flushes and cancels scheduling on demand (e.g. before writing an exit banner)", () => {
    const s = fakeSchedulers();
    const onFlush = vi.fn();
    const batcher = createWriteBatcher({ onFlush, ...s });
    batcher.push(bytes("last output"));
    batcher.flushNow();
    expect(onFlush).toHaveBeenCalledTimes(1);
    expect(s.cancelFrame).toHaveBeenCalledTimes(1);
    expect(s.clearTimer).toHaveBeenCalledTimes(1);
  });

  it("flushNow is a no-op when nothing is pending", () => {
    const s = fakeSchedulers();
    const onFlush = vi.fn();
    const batcher = createWriteBatcher({ onFlush, ...s });
    batcher.flushNow();
    expect(onFlush).not.toHaveBeenCalled();
  });
});
