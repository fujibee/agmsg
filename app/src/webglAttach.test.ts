import { describe, expect, it, vi } from "vitest";
import { attachWebglAddon, type MinimalWebglAddon } from "./webglAttach";

function makeAddon(overrides: Partial<MinimalWebglAddon> = {}): MinimalWebglAddon {
  return {
    dispose: vi.fn(),
    onContextLoss: vi.fn(),
    activate: vi.fn(),
    ...overrides,
  };
}

describe("attachWebglAddon", () => {
  it("loads the addon, sets the ref, and returns a cleanup that disposes + clears the ref", () => {
    const addon = makeAddon();
    const term = { loadAddon: vi.fn() };
    const ref: { current: MinimalWebglAddon | null } = { current: null };

    const cleanup = attachWebglAddon(term, () => addon, ref);

    expect(term.loadAddon).toHaveBeenCalledWith(addon);
    expect(ref.current).toBe(addon);
    expect(cleanup).toBeInstanceOf(Function);

    cleanup!();
    expect(addon.dispose).toHaveBeenCalledTimes(1);
    expect(ref.current).toBeNull();
  });

  it("disposes the addon and returns undefined when loadAddon throws immediately", () => {
    const addon = makeAddon();
    const term = {
      loadAddon: vi.fn(() => {
        throw new Error("WebGL2 unavailable");
      }),
    };
    const ref: { current: MinimalWebglAddon | null } = { current: null };

    const cleanup = attachWebglAddon(term, () => addon, ref);

    expect(cleanup).toBeUndefined();
    expect(addon.dispose).toHaveBeenCalledTimes(1);
    expect(ref.current).toBeNull();
  });

  it("does not throw when loadAddon throws AND dispose itself throws (partially-initialized addon)", () => {
    const addon = makeAddon({
      dispose: vi.fn(() => {
        throw new Error("cannot dispose a half-initialized context");
      }),
    });
    const term = {
      loadAddon: vi.fn(() => {
        throw new Error("WebGL2 unavailable");
      }),
    };
    const ref: { current: MinimalWebglAddon | null } = { current: null };

    expect(() => attachWebglAddon(term, () => addon, ref)).not.toThrow();
    expect(ref.current).toBeNull();
  });

  it("registers an onContextLoss handler that disposes and clears the ref when it fires", () => {
    const addon = makeAddon();
    const term = { loadAddon: vi.fn() };
    const ref: { current: MinimalWebglAddon | null } = { current: null };

    attachWebglAddon(term, () => addon, ref);
    expect(ref.current).toBe(addon);

    const onContextLossCallback = vi.mocked(addon.onContextLoss).mock.calls[0][0];
    onContextLossCallback();

    expect(addon.dispose).toHaveBeenCalledTimes(1);
    expect(ref.current).toBeNull();
  });

  it("cleanup does not double-dispose if onContextLoss already fired for this instance", () => {
    const addon = makeAddon();
    const term = { loadAddon: vi.fn() };
    const ref: { current: MinimalWebglAddon | null } = { current: null };

    const cleanup = attachWebglAddon(term, () => addon, ref);
    const onContextLossCallback = vi.mocked(addon.onContextLoss).mock.calls[0][0];
    onContextLossCallback();
    expect(addon.dispose).toHaveBeenCalledTimes(1);

    cleanup!();
    expect(addon.dispose).toHaveBeenCalledTimes(1);
  });

  it("cleanup does not dispose a DIFFERENT instance that has since taken over the ref", () => {
    const addon = makeAddon();
    const otherAddon = makeAddon();
    const term = { loadAddon: vi.fn() };
    const ref: { current: MinimalWebglAddon | null } = { current: null };

    const cleanup = attachWebglAddon(term, () => addon, ref);
    ref.current = otherAddon; // simulates a newer attach having taken over

    cleanup!();
    expect(addon.dispose).not.toHaveBeenCalled();
    expect(otherAddon.dispose).not.toHaveBeenCalled();
  });
});
