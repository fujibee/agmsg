(() => {
  const internals = window.__TAURI_INTERNALS__;
  const real = internals.invoke.bind(internals);
  const report = (m) => { try { real("plugin:event|emit", { event: "e2e-report", payload: String(m) }).catch(() => {}); } catch (_) {} };
  const btns = [...document.querySelectorAll("button")].map((b) => (b.textContent.trim() || b.title) + (b.disabled ? "(disabled)" : "")).join(" | ");
  report("ALIVE perf=" + Math.round(performance.now()) + " iframes=" + document.querySelectorAll("iframe").length + " vis=" + document.visibilityState + " buttons=" + btns.slice(-500));
  setTimeout(() => report("ALIVE timer 1s fired"), 1000);
})();
