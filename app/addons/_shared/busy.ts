import { h } from "./dom";

// "Something is running" inside a pane. The spinner stays invisible for its first 150 ms (CSS, .spinner),
// so work that ends at once does not flicker. A busy button is disabled and says aria-busy; the state is
// always taken off again, whether the work succeeded or threw.

export function spinner(): HTMLElement {
  return h("span", { class: "spinner", "aria-hidden": "true" });
}

/** A waiting body: the spinner and a line saying what for. */
export function loadingView(text: string): HTMLElement {
  return h("div", { class: "empty loading", role: "status" }, spinner(), h("span", null, text));
}

/** Marks a button busy (disabled, aria-busy, spinner) or clears it. Safe to call twice. */
export function setBusy(button: HTMLButtonElement, on: boolean): void {
  const mark = button.querySelector(":scope > .spinner");
  if (on) {
    button.setAttribute("aria-busy", "true");
    button.disabled = true;
    if (!mark) button.append(spinner());
  } else {
    button.removeAttribute("aria-busy");
    button.disabled = false;
    mark?.remove();
  }
}

/** Runs `work` with the button busy. Ignored if it is already busy. The busy state ends whether `work` succeeds or throws. */
export async function withBusy<T>(button: HTMLButtonElement, work: () => Promise<T>): Promise<T | undefined> {
  if (button.getAttribute("aria-busy") === "true") return undefined;
  setBusy(button, true);
  try {
    return await work();
  } finally {
    setBusy(button, false);
  }
}
