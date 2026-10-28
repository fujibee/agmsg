(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const internals = window.__TAURI_INTERNALS__;
  const real = internals.invoke.bind(internals);
  const report = (m) => { try { real("plugin:event|emit", { event: "e2e-report", payload: String(m) }).catch(() => {}); } catch (_) {} return Promise.resolve(); };
  const waitFor = async (fn, what, ms = 30000) => {
    const t = Date.now();
    let n = 0; while (Date.now() - t < ms) { const v = fn(); if (v) return v; if (++n % 20 === 0) report("waiting for " + what + " " + Math.round((Date.now() - t) / 1000) + "s; buttons: " + [...document.querySelectorAll("button")].map((b) => (b.textContent.trim() || b.title || b.getAttribute("aria-label") || b.className) + (b.disabled ? "(disabled)" : "")).join(" | ").slice(-400)); await sleep(250); }
    throw new Error("timeout waiting for " + what);
  };
  // Nothing here depends on the UI language (the app follows the OS language): the tab bar's + is
  // `.new-wrap-tabs > button`, menu entries carry `data-key`, and in a permission card the first
  // button is "Allow once" (files cards) or "Allow" (messages cards).
  const menuItems = () => [...document.querySelectorAll(".new-menu [role=menuitem]")];
  // A disabled entry is waited for only while the startup check is still running; once it has ended
  // "off", fail at once with its reasons instead of waiting for a menu that cannot enable.
  const gateOff = async () => {
    const v = await real("addon_gate_status");
    return v && !v.enabled && !/^(checking again|the startup check has not run)/.test((v.reasons || [""])[0]) ? v.reasons.join("; ") : null;
  };
  const pick = async (match, what) => {
    const t = Date.now();
    while (Date.now() - t < 60000) {
      const it = menuItems().find((b) => match(b.dataset.key || ""));
      if (it && !it.disabled) return it;
      const off = await gateOff();
      if (off) throw new Error(what + " is disabled; add-ons are off: " + off);
      // add-ons are on but the entry stays disabled: no team selected in the UI
      if (it && it.disabled && Date.now() - t > 15000) throw new Error(what + " stays disabled although add-ons are on (no team selected?)");
      await sleep(250);
    }
    throw new Error("timeout waiting for " + what);
  };
  const byKey = (key) => pick((k) => k === key, "menu entry " + key);
  const byPane = (pane) => pick((k) => k.endsWith("/" + pane), "menu entry for pane " + pane);
  const ONCE = () => {
    if (document.querySelector(".addon-grant-card.denied")) throw new Error("the permission card says the folder is denied");
    return document.querySelector(".addon-grant-card:not(.denied) .addon-card-actions button:first-child:not(:disabled)");
  };
  // Waiting for a permission card: when it does not come, say what the page shows instead (is this the
  // e2e build, did the folder seam have a value, which add-on elements exist and what do they say).
  const card = async (what) => {
    try {
      return await waitFor(ONCE, what, 30000);
    } catch (e) {
      // Structured facts only, no page text (it can carry real paths): the build flag, whether the seam holds
      // the fixture this run put there, the number of frames, the innermost permission/failure cards with
      // their kind and error code, and the add-on class names present.
      const cards = [...document.querySelectorAll(".addon-card")].filter((c) => !c.querySelector(".addon-card")).map((c) => c.className.replace(/\s+/g, ".") + (c.dataset.code ? "[" + c.dataset.code + "]" : "") + " buttons=" + c.querySelectorAll("button").length);
      const classes = [...new Set([...document.querySelectorAll("[class*=addon]")].flatMap((x) => [...x.classList].filter((k) => k.startsWith("addon"))))].sort();
      report("DIAG e2e-build=" + (window.__AGMSG_E2E_BUILD__ === true) + " seam-is-fixture=" + (window.__AGMSG_E2E_FOLDER__ === "__FIXTURE__") + " frames=" + document.querySelectorAll("iframe").length + " cards=[" + cards.join("; ") + "] classes=" + classes.join(","));
      throw e;
    }
  };
  const trigger = () => document.querySelector(".new-wrap-tabs > button");
  let folder = null;
  const openMenu = async () => {
    if (!menuItems().length) { (await waitFor(trigger, "the + of the tab bar")).click(); await sleep(500); }
    await waitFor(() => menuItems().length > 0, "the open menu", 5000);
  };
  try {
    await report("driver started; buttons: " + [...document.querySelectorAll("button")].map((b) => b.textContent.trim() || b.title).slice(0, 25).join(" | "));
    // select a team (the add-on entries of the tab bar menu need one)
    const teamBtn = [...document.querySelectorAll("button")].find((b) => ((b.title || "").startsWith("__TEAM__:") || b.textContent.trim() === "__TEAM__"));
    report("team button: " + (teamBtn ? "found" : "none"));
    if (teamBtn) teamBtn.click();
    await sleep(800);
    await openMenu();
    report("menu: " + menuItems().map((b) => (b.dataset.key || "?") + (b.disabled ? "(disabled)" : "")).join(" | "));
    // Without the e2e frontend the folder picker is the native dialog, which nothing here can answer: stop now.
    if (window.__AGMSG_E2E_BUILD__ !== true) throw new Error("this is not the e2e frontend build: File view would open the native folder dialog");
    window.__AGMSG_E2E_FOLDER__ = "__FIXTURE__";
    await report("opening File view");
    (await byKey("fileview")).click();
    (await card("the folder grant card")).click();
    await report("file view granted");
    await sleep(8000);
    await openMenu();
    await report("opening Diff view");
    (await byKey("diffview")).click();
    (await card("the second grant card")).click();
    await report("diff view granted");
    await sleep(12000);
    // Straight requests through the same command the frames use, for the pane ids and generations seen in the trace.
    let mismatches = 0;
    // expect: "ok" or the error code the answer must carry
    const ask = async (id, op, args, expect) => {
      let got;
      let body;
      try {
        const r = await real("addon_request", { id, generation: 1, op, args });
        got = r.ok ? "ok" : r.error.code;
        body = r.ok ? "ok " + JSON.stringify(r.result).slice(0, 260) : "ERR " + r.error.code + ": " + r.error.message.slice(0, 120);
      } catch (e) { got = "threw"; body = "threw " + e; }
      const pass = got === expect;
      if (!pass) mismatches++;
      report((pass ? "ASK PASS " : "ASK FAIL(expected " + expect + ") ") + "pane" + id + " " + op + " " + JSON.stringify(args) + " -> " + body);
    };
    await ask(1, "open.args", {}, "ok");
    await ask(1, "fs.stat", { path: "." }, "ok");
    await ask(1, "fs.list", { path: "." }, "ok");
    await ask(1, "fs.list", { path: "src" }, "ok");
    await ask(1, "fs.read", { path: "src/main.ts", range: { offset: 0, length: 20 } }, "ok");
    await ask(1, "fs.read", { path: "logo.png" }, "ok");
    await ask(1, "fs.read", { path: "../x" }, "bad_args");
    await ask(1, "fs.read", { path: "missing.txt" }, "not_found");
    await ask(1, "git.status", {}, "not_declared");
    await ask(2, "open.args", {}, "ok");
    await ask(2, "git.status", {}, "ok");
    await ask(2, "git.log", {}, "ok");
    await ask(2, "git.diff", {}, "ok");
    await ask(2, "git.diff", { base: "merge-base:main", context: 0 }, "ok");
    await ask(2, "git.diff", { base: "--output=/tmp/x" }, "bad_args");
    await ask(2, "git.show", { rev: "HEAD", path: "README.md" }, "ok");
    await ask(2, "git.show", { rev: "HEAD", path: "logo.png" }, "ok");
    await ask(2, "git.show", { rev: "HEAD" }, "bad_args");
    await ask(2, "git.show", { rev: "HEAD", path: "../../etc/hosts" }, "bad_args");
    await ask(2, "fs.list", { path: "." }, "ok");
    // Developer add-on with the measurement panes: load it, tell the UI, open each pane from the New menu.
    window.__AGMSG_E2E_FOLDER__ = "__ADDON__";
    try {
      await real("addon_dev_load", { spec: { path: "__ADDON__" } });
      report("DEV loaded");
    } catch (e) { report("DEV load FAILED " + JSON.stringify(e)); throw e; }
    try { await real("plugin:event|emit", { event: "addon-updated", payload: null }); } catch (_) {}
    await sleep(2000);
    const devPanes = ["app-tauri", "app-tauri-localhost-http", "app-https", "replace", "meta-refresh", "net"];
    for (const pane of devPanes) {
      await openMenu();
      const item = await byPane(pane);
      report("opening dev pane " + pane);
      item.click();
      await sleep(pane === "net" ? 70000 : 9000); // one pane at a time: a pane in a background tab does not run
    }
    await sleep(3000);
    if (mismatches > 0) throw new Error(mismatches + " answer(s) were not what was expected");
    await report("finished");
  } catch (e) {
    try { await report("FAILED: " + e.message + "; buttons: " + [...document.querySelectorAll("button")].map((b) => (b.textContent.trim() || b.title) + (b.disabled ? "(disabled)" : "")).slice(0, 40).join(" | ")); } catch (_) {}
  }
})();
