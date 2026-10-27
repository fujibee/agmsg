(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const real = window.__TAURI_INTERNALS__.invoke.bind(window.__TAURI_INTERNALS__);
  const report = (m) => { try { real("plugin:event|emit", { event: "e2e-report", payload: String(m) }).catch(() => {}); } catch (_) {} };
  try {
    // The run script seeded the throwaway base with the bundled scripts; the app's own installer
    // (install.sh, which writes into the real home) is never called here.
    const ok = await real("agmsg_is_installed");
    report("core present in the throwaway base: " + ok);
    if (!ok) throw new Error("the throwaway base has no scripts; refusing to install");
    await real("agmsg_join", { team: "__TEAM__", name: "tester", agentType: "agmsg-app", project: "__FIXTURE__" });
    report("team joined: __TEAM__");
    report("finished");
  } catch (e) { report("FAILED: " + (e && e.message ? e.message : JSON.stringify(e))); }
})();
