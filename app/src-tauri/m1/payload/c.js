// M1 C: network egress + code-from-fetched-text, measured from inside the frame.
// Truth is the sentinel log (host side); this page also reports what it saw.
let REP = null, CFG = null;
const rep = (k, v) => { try { const i = new Image(); i.src = 'http://127.0.0.1:' + REP + '/r?' + encodeURIComponent(k) + '=' + encodeURIComponent(String(v)); } catch (e) {} };
// REPORT channel is itself an img to the report port; CSP img-src must allow it in test builds (report port is listed in <net> by the host when M1_REPORT_IN_CSP=1).
const viol = [];
document.addEventListener('securitypolicyviolation', (e) => { viol.push(e.effectiveDirective + ' ' + e.blockedURI.slice(0, 60)); });
window.addEventListener('message', async (ev) => {
  if (!ev.data || ev.data.m1 !== 'cfg') return;
  CFG = ev.data.cfg; REP = CFG.report;
  rep('C_start', 'ua=' + navigator.userAgent.slice(-60));
  rep('C_inline_hashed_ran', !!window.__inlineHashedRan);
  rep('C_inline_unhashed_ran', !!window.__inlineUnhashedRan);
  const S1 = 'http://127.0.0.1:' + CFG.s1, S2 = 'http://127.0.0.1:' + CFG.s2, LAN = CFG.lan ? 'http://' + CFG.lan : null;
  const T = async (label, fn) => { try { const v = await Promise.race([fn(), new Promise((_, r) => setTimeout(() => r(new Error('timeout')), 3000))]); rep(label, 'ok ' + String(v).slice(0, 60)); } catch (e) { rep(label, 'fail ' + (e && e.name) + ':' + String(e && e.message).slice(0, 50)); } };
  const targets = { S1other: S1, S2net: S2, LAN: LAN };
  for (const [tn, base] of Object.entries(targets)) {
    if (!base) continue;
    await T('C_fetch_cors_' + tn, async () => (await fetch(base + '/fetch-cors')).status);
    await T('C_fetch_nocors_' + tn, async () => (await fetch(base + '/fetch-nocors', { mode: 'no-cors' })).type);
    await T('C_xhr_' + tn, () => new Promise((res, rej) => { const x = new XMLHttpRequest(); x.open('GET', base + '/xhr'); x.onload = () => res(x.status); x.onerror = () => rej(new Error('xhr err')); x.send(); }));
    await T('C_ws_' + tn, () => new Promise((res, rej) => { const w = new WebSocket(base.replace('http', 'ws') + '/ws'); w.onopen = () => res('open'); w.onerror = () => rej(new Error('ws err')); w.onclose = () => rej(new Error('ws closed')); }));
    await T('C_sse_' + tn, () => new Promise((res, rej) => { const e = new EventSource(base + '/sse'); e.onopen = () => { e.close(); res('open'); }; e.onerror = () => { e.close(); rej(new Error('sse err')); }; }));
    await T('C_beacon_' + tn, async () => navigator.sendBeacon(base + '/beacon', 'x'));
    await T('C_img_' + tn, () => new Promise((res, rej) => { const i = new Image(); i.onload = () => res('load'); i.onerror = () => rej(new Error('img err')); i.src = base + '/img.png'; }));
    await T('C_css_link_' + tn, () => new Promise((res, rej) => { const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = base + '/s.css'; l.onload = () => res('load'); l.onerror = () => rej(new Error('css err')); document.head.appendChild(l); }));
    await T('C_css_import_' + tn, () => new Promise((res) => { const s = document.createElement('style'); s.textContent = '@import url("' + base + '/import.css");'; document.head.appendChild(s); setTimeout(() => res('queued'), 800); }));
    await T('C_css_bgimage_' + tn, () => new Promise((res) => { const d = document.createElement('div'); d.style.cssText = 'width:5px;height:5px;background:url("' + base + '/bg.png")'; document.body.appendChild(d); setTimeout(() => res('queued'), 800); }));
    await T('C_font_' + tn, async () => { const f = new FontFace('m1f', 'url(' + base + '/f.woff2)'); await f.load(); return 'loaded'; });
    await T('C_audio_' + tn, () => new Promise((res) => { const a = new Audio(); a.src = base + '/a.mp3'; a.onerror = () => res('err'); a.onloadstart = () => res('loadstart'); a.load(); setTimeout(() => res('queued'), 800); }));
    await T('C_worker_url_' + tn, () => new Promise((res, rej) => { const w = new Worker(base + '/w.js'); w.onerror = () => rej(new Error('worker err')); w.onmessage = () => res('msg'); setTimeout(() => res('queued'), 800); }));
    await T('C_script_src_' + tn, () => new Promise((res, rej) => { const s = document.createElement('script'); s.src = base + '/code.js'; s.onload = () => res('load'); s.onerror = () => rej(new Error('script err')); document.head.appendChild(s); }));
    await T('C_module_import_' + tn, async () => { await import(base + '/code-mod.js'); return 'imported'; });
    await T('C_iframe_' + tn, () => new Promise((res) => { const f = document.createElement('iframe'); f.src = base + '/iframe'; f.onload = () => res('load'); document.body.appendChild(f); setTimeout(() => res('queued'), 800); }));
    await T('C_form_' + tn, () => new Promise((res) => { const f = document.createElement('form'); f.action = base + '/form'; f.method = 'post'; document.body.appendChild(f); try { f.submit(); } catch (e) {} setTimeout(() => res('submitted'), 800); }));
  }
  // WebRTC / STUN to a UDP sentinel
  await T('C_webrtc_stun', async () => {
    const pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:127.0.0.1:' + CFG.udp }] });
    pc.createDataChannel('x');
    await pc.setLocalDescription(await pc.createOffer());
    await new Promise((r) => setTimeout(r, 2500));
    return pc.iceGatheringState;
  });
  // Code from fetched text: S2 serves JS text at /code.js ("RAN" marker); when not allowed the fetch fails and nothing runs.
  let text = null;
  try { text = await (await fetch(S2 + '/code.js')).text(); rep('C_fetch_code_text', 'len=' + text.length); } catch (e) { rep('C_fetch_code_text', 'fail ' + e); }
  if (text === null) text = "parent.postMessage('x','*');(new Image).src='http://127.0.0.1:" + REP + "/r?RAN_' + 'KIND=1'";
  const code = (kind) => "(new Image).src='http://127.0.0.1:" + REP + "/r?RAN_" + kind + "=1';";
  await T('C_run_inline_script_el', async () => { const s = document.createElement('script'); s.textContent = code('inline_script_el'); document.head.appendChild(s); return 'appended'; });
  await T('C_run_blob_script', async () => { const u = URL.createObjectURL(new Blob([code('blob_script')], { type: 'text/javascript' })); const s = document.createElement('script'); s.src = u; document.head.appendChild(s); return 'appended'; });
  await T('C_run_data_script', async () => { const s = document.createElement('script'); s.src = 'data:text/javascript,' + encodeURIComponent(code('data_script')); document.head.appendChild(s); return 'appended'; });
  await T('C_run_blob_worker', async () => { const u = URL.createObjectURL(new Blob([code('blob_worker').replace("(new Image).src=", "fetch(") .replace(/';$/, "');")], { type: 'text/javascript' })); new Worker(u); return 'created'; });
  await T('C_run_data_worker', async () => { new Worker('data:text/javascript,' + encodeURIComponent("fetch('http://127.0.0.1:" + REP + "/r?RAN_data_worker=1')")); return 'created'; });
  await T('C_run_import_blob', async () => { const u = URL.createObjectURL(new Blob([code('import_blob')], { type: 'text/javascript' })); await import(u); return 'imported'; });
  await T('C_run_import_data', async () => { await import('data:text/javascript,' + encodeURIComponent(code('import_data'))); return 'imported'; });
  await T('C_run_eval', async () => { (0, eval)(code('eval')); return 'evaled'; });
  await T('C_run_new_Function', async () => { new Function(code('new_Function'))(); return 'called'; });
  await T('C_run_setTimeout_string', async () => { setTimeout(code('setTimeout_string'), 0); return 'queued'; });
  await T('C_run_wasm', async () => { const m = await WebAssembly.instantiate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0])); (new Image).src = 'http://127.0.0.1:' + REP + '/r?RAN_wasm=1'; return 'instantiated'; });
  await T('C_run_inline_handler', async () => { const d = document.createElement('div'); d.innerHTML = '<img src="x" onerror="(new Image).src=\'http://127.0.0.1:' + REP + '/r?RAN_inline_handler=1\'">'; document.body.appendChild(d); return 'inserted'; });
  await T('C_run_javascript_url', async () => { const a = document.createElement('a'); a.href = 'javascript:(new Image).src=\'http://127.0.0.1:' + REP + '/r?RAN_javascript_url=1\''; document.body.appendChild(a); a.click(); return 'clicked'; });
  await T('C_run_srcdoc_iframe', async () => { const f = document.createElement('iframe'); f.srcdoc = '<script>(new Image).src="http://127.0.0.1:' + REP + '/r?RAN_srcdoc=1"<\/script>'; document.body.appendChild(f); return 'appended'; });
  await new Promise((r) => setTimeout(r, 1500));
  rep('C_csp_violations', viol.length + ' :: ' + viol.slice(0, 40).join(' | '));
  rep('C_done', 1);
});
