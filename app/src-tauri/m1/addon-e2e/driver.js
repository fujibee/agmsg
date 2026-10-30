(async () => {
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const internals = window.__TAURI_INTERNALS__;
  const real = internals.invoke.bind(internals);
  const report = (m) => { try { real("plugin:event|emit", { event: "e2e-report", payload: String(m) }).catch(() => {}); } catch (_) {} return Promise.resolve(); };
  const waitFor = async (fn, what, ms = 30000) => {
    const t = Date.now();
    let n = 0; while (Date.now() - t < ms) { const v = fn(); if (v) return v; if (++n % 20 === 0) report("waiting for " + what + " " + Math.round((Date.now() - t) / 1000) + "s; buttons: " + [...document.querySelectorAll("button")].map((b) => (b.textContent.trim() || b.title) + (b.disabled ? "(disabled)" : "")).join(" | ").slice(-400)); await sleep(250); }
    throw new Error("timeout waiting for " + what);
  };
  const byLabel = (labels) => [...document.querySelectorAll("button")].find((b) => labels.includes(b.textContent.trim()) && !b.disabled);
  const FILE = ["File view…", "ファイルビュー…"];
  const DIFF = ["Diff view…", "差分ビュー…"];
  const ONCE = ["Allow once", "今回だけ許可"];
  const trigger = () => document.querySelector(".new-wrap > button");
  let folder = null;
  const openMenu = async () => { (await waitFor(trigger, "the New button")).click(); await sleep(500); };
  try {
    await report("driver started; buttons: " + [...document.querySelectorAll("button")].map((b) => b.textContent.trim() || b.title).slice(0, 25).join(" | "));
    // select a team (the New menu needs one), then collapse the sidebar: the New menu lives on the rail
    const teamBtn = [...document.querySelectorAll("button")].find((b) => ((b.title || "").startsWith("__TEAM__:") || b.textContent.trim() === "__TEAM__"));
    report("team button: " + (teamBtn ? "found" : "none"));
    if (teamBtn) teamBtn.click();
    await sleep(800);
    const collapse = [...document.querySelectorAll("button")].find((b) => b.title === "Collapse sidebar" || b.textContent.trim() === "Collapse sidebar");
    if (collapse) collapse.click();
    await sleep(800);
    await openMenu();
    report("menu: " + [...document.querySelectorAll(".new-wrap button")].map((b) => b.textContent.trim() + (b.disabled ? "(disabled)" : "")).join(" | "));
    window.__AGMSG_E2E_FOLDER__ = "__FIXTURE__";
    await report("opening File view");
    (await waitFor(() => byLabel(FILE), "File view menu item")).click();
    (await waitFor(() => byLabel(ONCE), "the folder grant card")).click();
    await report("file view granted");
    await sleep(8000);
    await openMenu();
    await report("opening Diff view");
    (await waitFor(() => byLabel(DIFF), "Diff view menu item")).click();
    (await waitFor(() => byLabel(ONCE), "the second grant card")).click();
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
    if (mismatches > 0) throw new Error(mismatches + " answer(s) were not what was expected");
    await report("finished");
  } catch (e) {
    try { await report("FAILED: " + e.message + "; buttons: " + [...document.querySelectorAll("button")].map((b) => (b.textContent.trim() || b.title) + (b.disabled ? "(disabled)" : "")).slice(0, 40).join(" | ")); } catch (_) {}
  }
})();
