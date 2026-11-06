(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const real = window.__TAURI_INTERNALS__.invoke.bind(window.__TAURI_INTERNALS__);
  const report = (m) => { try { real("plugin:event|emit", { event: "e2e-report", payload: String(m) }).catch(() => {}); } catch (_) {} return Promise.resolve(); };
  const waitFor = async (fn, what, ms = 30000) => { const t = Date.now(); while (Date.now() - t < ms) { const v = fn(); if (v) return v; await sleep(250); } throw new Error("timeout waiting for " + what); };
  const menuItems = () => [...document.querySelectorAll(".new-menu [role=menuitem]")];
  const trigger = () => document.querySelector(".new-wrap-tabs > button");
  let bad = 0;
  const check = (ok, what) => { if (!ok) bad++; report((ok ? "POW PASS " : "POW FAIL ") + what); };
  try {
    const teamBtn = [...document.querySelectorAll("button")].find((b) => ((b.title || "").startsWith("__TEAM__:") || b.textContent.trim() === "__TEAM__"));
    if (teamBtn) teamBtn.click();
    await sleep(800);
    await real("addon_dev_load", { spec: { path: "__ADDON__" } });
    try { await real("plugin:event|emit", { event: "addon-updated", payload: null }); } catch (_) {}
    await sleep(2000);
    (await waitFor(trigger, "the + of the tab bar")).click();
    await sleep(500);
    const item = await waitFor(() => menuItems().find((b) => (b.dataset.key || "").endsWith("/powers") && !b.disabled), "menu entry for pane powers", 60000);
    item.click();
    // the team card of messages:read: "Allow" is its first button
    const card = await waitFor(() => document.querySelector(".addon-grant-card:not(.denied) .addon-card-actions button:first-child:not(:disabled)"), "the team grant card", 30000);
    card.click();
    // the frame must be current before the broker answers
    const ask = async (op, args) => { const t = Date.now(); const r = await real("addon_request", { id: 1, generation: 1, op, args }); report("POW TIME " + op + " " + (Date.now() - t) + " ms " + (r.ok ? "ok" : r.error.code)); return r; };
    for (let t = Date.now(); ; ) {
      const r = await ask("open.args", {}).catch(() => ({ ok: false }));
      if (r.ok) break;
      if (Date.now() - t > 60000) throw new Error("the frame of pane 1 never became current");
      await sleep(500);
    }
    // before any power is allowed: not_granted
    let r = await ask("team.join", {});
    check(!r.ok && r.error.code === "not_granted", "team.join before the power is allowed -> not_granted (" + (r.ok ? "ok" : r.error.code) + ")");
    for (const p of ["team:join", "messages:send", "agents:spawn"]) await real("addon_set_power", { id: 1, power: p, on: true });
    r = await ask("agents.types", {});
    check(r.ok && r.result.types.length > 0, "agents.types lists " + (r.ok ? r.result.types.map((t) => t.type).join(",") : r.error.code));
    r = await ask("team.join", {});
    check(r.ok && r.result.type === "app-addon" && r.result.created === true, "team.join -> " + JSON.stringify(r.ok ? r.result : r.error));
    const me = r.ok ? r.result.name : "";
    r = await ask("team.join", {});
    check(r.ok && r.result.created === false && r.result.name === me, "team.join again -> created=false, same name");
    r = await ask("messages.send", { to: "tester", body: "hello from the measurement", from: "tester", team: "other" });
    check(r.ok && r.result.to === "tester", "messages.send (forged from/team ignored) -> " + JSON.stringify(r.ok ? r.result : r.error));
    r = await ask("messages.send", { to: "nobody", body: "x" });
    check(!r.ok && r.error.code === "bad_args", "messages.send to a non-member -> bad_args");
    r = await ask("agents.spawn", { type: "claude-code", name: "..", folder: undefined });
    check(!r.ok && r.error.code === "bad_args", "agents.spawn with a bad name -> bad_args");
    r = await ask("agents.spawn", { type: "claude-code", name: "white", folder: "../x" });
    check(!r.ok && ["bad_args", "not_granted"].includes(r.error.code), "agents.spawn with a folder escape -> " + (r.ok ? "ok" : r.error.code));
    const t0 = Date.now();
    r = await ask("agents.spawn", { type: "claude-code", name: "white" });
    const spawnMs = Date.now() - t0;
    let agent = r.ok ? r.result : null;
    check(r.ok && ["running", "unknown"].includes(r.result.state), "agents.spawn -> " + JSON.stringify(r.ok ? r.result : r.error) + " in " + spawnMs + " ms");
    // After the 15 s wait the app hands over with state=unknown; the terminal then reports and the entry becomes running.
    // Wait for that through agents.list (no new spawn) before the later steps need a pid.
    if (agent && agent.state === "unknown") {
      report("POW SPAWN state=unknown after " + spawnMs + " ms; waiting for agents.list to show running");
      for (let i = 0; i < 60 && !(agent.state === "running" && agent.pid > 0); i++) {
        await sleep(1000);
        const l = await ask("agents.list", {});
        const e = l.ok ? l.result.agents.find((x) => x.name === agent.name) : null;
        if (e) agent = e;
      }
    }
    check(!!agent && agent.state === "running" && agent.pid > 0, "the spawned agent is running with a pid -> " + JSON.stringify(agent));
    report("POW SPAWNED pid=" + (agent ? agent.pid : "none"));
    r = await ask("agents.spawn", { type: "claude-code", name: "white" });
    check(r.ok && r.result.state === "running", "agents.spawn again returns the running agent, no second pane");
    r = await ask("agents.list", {});
    check(r.ok && r.result.agents.length === 1, "agents.list -> " + JSON.stringify(r.ok ? r.result : r.error));
    // the pane exists in the UI, next to the add-on pane
    await sleep(2000);
    check(!!document.querySelector(".xterm"), "a terminal pane is open in the window");
    if (bad > 0) throw new Error(bad + " check(s) failed");
    await report("finished");
  } catch (e) { report("FAILED: " + (e && e.message ? e.message : JSON.stringify(e))); }
})();
