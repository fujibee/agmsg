// How the messages of an agent pane reach the agent, and what the dot in the pane header says about it.
//
// Three ways, read from agmsg's own `delivery.sh status` line (`mode: ...`):
//  - "agmsgd": the background service delivers to the CLI session itself (the status line starts with `agmsgd`).
//  - "native": the CLI runs its own monitor or hook (`monitor` or `both`).
//  - "app":    nothing delivers to it, so the app types a one-line notice into the terminal.
// Only "app" is typed into: a pane that already hears through agmsgd or its own monitor would get the message twice.

export type PaneDelivery = "agmsgd" | "native" | "app";

/** The delivery of a pane from the `mode:` value of `delivery.sh status`; a missing or unknown value is "app". */
export function deliveryFromMode(mode: string | null | undefined): PaneDelivery {
  const m = (mode ?? "").trim();
  if (m === "agmsgd" || m.startsWith("agmsgd ")) return "agmsgd";
  if (m === "monitor" || m === "both") return "native";
  return "app";
}

/** True when the app types its notices into a pane of this delivery. */
export function appTypesInto(delivery: PaneDelivery): boolean {
  return delivery === "app";
}

export type DeliveryDot = { className: string; tipKey: string };

/**
 * The dot of a pane header, or null for a pane that has none. Only an agent pane has a delivery; a shell, an add-on
 * pane and the shell an agent falls back to when its type has no CLI carry none, because nothing is delivered to them.
 */
export function deliveryDot(pane: { delivery?: PaneDelivery }): DeliveryDot | null {
  if (!pane.delivery) return null;
  return { className: `monitor-dot ${pane.delivery}`, tipKey: `pane.deliveryTip.${pane.delivery}` };
}
