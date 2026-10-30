import { describe, expect, it } from "vitest";
import { createModalStack, escapeCloses } from "./modalStack";

// What the window's keydown listeners do: every mounted modal hears the same Escape.
const press = (stack: ReturnType<typeof createModalStack>, modals: { id: number; onClose?: () => void }[]) =>
  modals.forEach((m) => escapeCloses(stack, m.id, m.onClose));

describe("Escape with stacked dialogs", () => {
  it("Settings under a busy dialog: Escape closes neither (the busy one has no way out and shields the parent)", () => {
    const stack = createModalStack();
    const closed: string[] = [];
    stack.push(1); // Settings
    stack.push(2); // busy dialog: no onClose
    press(stack, [{ id: 1, onClose: () => closed.push("settings") }, { id: 2 }]);
    expect(closed).toEqual([]);
  });
  it("Settings under a dialog that is not busy: Escape closes only the dialog", () => {
    const stack = createModalStack();
    const closed: string[] = [];
    stack.push(1);
    stack.push(2);
    press(stack, [{ id: 1, onClose: () => closed.push("settings") }, { id: 2, onClose: () => closed.push("dialog") }]);
    expect(closed).toEqual(["dialog"]);
  });
  it("after the dialog is gone Settings is the top again, and one Escape closes it", () => {
    const stack = createModalStack();
    const closed: string[] = [];
    stack.push(1);
    stack.push(2);
    stack.remove(2);
    press(stack, [{ id: 1, onClose: () => closed.push("settings") }]);
    expect(closed).toEqual(["settings"]);
  });
  it("a single modal closes as before; an empty stack closes nothing", () => {
    const stack = createModalStack();
    const closed: string[] = [];
    stack.push(1);
    press(stack, [{ id: 1, onClose: () => closed.push("only") }]);
    expect(closed).toEqual(["only"]);
    stack.remove(1);
    expect(stack.isTop(1)).toBe(false);
  });
  it("the stack is by mount order, however many times a modal is removed", () => {
    const stack = createModalStack();
    stack.push(1);
    stack.push(2);
    stack.push(3);
    stack.remove(2);
    expect(stack.isTop(3)).toBe(true);
    stack.remove(3);
    expect(stack.isTop(1)).toBe(true);
    stack.remove(9);
    expect(stack.isTop(1)).toBe(true);
  });
});
