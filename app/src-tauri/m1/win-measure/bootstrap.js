(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const real = window.__TAURI_INTERNALS__.invoke.bind(window.__TAURI_INTERNALS__);
  const report = (m) => { try { real("plugin:event|emit", { event: "e2e-report", payload: String(m) }).catch(() => {}); } catch (_) {} };
  try {
    // First run on an empty base: the app installs its bundled core by itself; wait for it.
    let ok = false;
    for (let i = 0; i < 120 && !ok; i++) { ok = await real("agmsg_is_installed"); if (!ok) await sleep(1000); }
    report("core installed: " + ok);
    if (!ok) throw new Error("the bundled core was not installed in 120 s");
    await real("agmsg_join", { team: "__TEAM__", name: "tester", agentType: "agmsg-app", project: "__FIXTURE__" });
    report("team joined: __TEAM__");
    report("finished");
  } catch (e) { report("FAILED: " + (e && e.message ? e.message : JSON.stringify(e))); }
})();
