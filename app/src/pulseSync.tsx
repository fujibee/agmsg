import { useLayoutEffect, useRef, type CSSProperties, type ReactNode } from "react";

/**
 * Negative animation-delay (a CSS time string, e.g. "-350ms") that phase-
 * locks a CSS animation of the given period to the wall clock: at any real
 * moment, every element sampling this at ITS OWN animation-start instant
 * lands on the same frame, regardless of when each one actually started
 * animating (koit: unsynced pulsing across panes read as noisy; getting
 * them to pulse together "looks cool"). The instant of sampling matters —
 * see PulseDot below for why this can't just be computed once and shared.
 */
export function pulseDelay(periodMs: number): string {
  return `-${Date.now() % periodMs}ms`;
}

type PulseDotProps = {
  periodMs: number;
  active?: boolean;
  className?: string;
  title?: string;
  style?: CSSProperties;
  children?: ReactNode;
};

/**
 * A span carrying a `--pulse-delay` custom property (consumed by CSS via
 * `animation-delay: var(--pulse-delay)`, either directly or through a
 * ::before pseudo-element that inherits it), resampled from the wall
 * clock at the exact moment this dot's animation actually starts — on
 * mount, and again every time `active` flips from false to true.
 *
 * A single delay value computed once (e.g. at the app root) only phase-
 * locks elements whose own animation happens to start at that same
 * instant. An agent that goes "working" ten minutes after launch, or a
 * pane opened later, starts its animation timeline at ITS mount/activate
 * time — offsetting a fixed delay sampled earlier just shifts that
 * element's phase by however long it waited, which is indistinguishable
 * from not being synced at all. Resampling per-element, at its own start,
 * is what actually keeps every element of a period in phase with the wall
 * clock (and therefore with each other).
 *
 * Every agent-status / team-status / monitor pulsing dot should render
 * through this one component rather than reimplementing the sampling.
 */
export function PulseDot({
  periodMs,
  active = true,
  className,
  title,
  style,
  children,
}: PulseDotProps) {
  const ref = useRef<HTMLSpanElement>(null);

  useLayoutEffect(() => {
    if (!active) return;
    ref.current?.style.setProperty("--pulse-delay", pulseDelay(periodMs));
  }, [active, periodMs]);

  return (
    <span ref={ref} className={className} title={title} style={style}>
      {children}
    </span>
  );
}
