// M1 C: network egress + code-from-fetched-text, measured from inside the frame.
// Truth is the sentinel log (host side); this page also reports what it saw.
// The page is suspended by WebKit a few seconds after load when the screen is locked,
// so the cases are split into groups chosen by location.hash and run one group per launch.
let REP = null, CFG = null;
const rep = (k, v) => { try { const i = new Image(); i.src = 'http://127.0.0.1:' + REP + '/r?' + encodeURIComponent(k) + '=' + encodeURIComponent(String(v)); } catch (e) {} };
const viol = [];
document.addEventListener('securitypolicyviolation', (e) => { viol.push(e.effectiveDirective + ' ' + e.blockedURI.slice(0, 60)); });
const G = location.hash.slice(1) || 'net1';
window.addEventListener('message', async (ev) => {
  if (!ev.data || ev.data.m1 !== 'cfg') return;
  CFG = ev.data.cfg; REP = CFG.report;
  rep('C_group', G + ' ua=' + navigator.userAgent.slice(-40));
  const S1 = 'http://127.0.0.1:' + CFG.s1, S2 = 'http://127.0.0.1:' + CFG.s2, LAN = CFG.lan ? 'http://' + CFG.lan : null;
  const T = async (label, fn) => { try { const v = await Promise.race([fn(), new Promise((_, r) => setTimeout(() => r(new Error('timeout')), 1500))]); rep(label, 'ok ' + String(v).slice(0, 60)); } catch (e) { rep(label, 'fail ' + (e && e.name) + ':' + String(e && e.message).slice(0, 50)); } };
  const code = (kind) => "(new Image).src='http://127.0.0.1:" + REP + "/r?RAN_" + kind + "=1';";
  const targets = { S1other: S1, S2net: S2, LAN: LAN };
  const perTarget = {
    net1: {
      fetch_cors: (b) => fetch(b + '/fetch-cors').then((r) => r.status),
      fetch_nocors: (b) => fetch(b + '/fetch-nocors', { mode: 'no-cors' }).then((r) => r.type),
      xhr: (b) => new Promise((res, rej) => { const x = new XMLHttpRequest(); x.open('GET', b + '/xhr'); x.onload = () => res(x.status); x.onerror = () => rej(new Error('xhr err')); x.send(); }),
      ws: (b) => new Promise((res, rej) => { const w = new WebSocket(b.replace('http', 'ws') + '/ws'); w.onopen = () => res('open'); w.onerror = () => rej(new Error('ws err')); w.onclose = () => rej(new Error('ws closed')); }),
      sse: (b) => new Promise((res, rej) => { const e = new EventSource(b + '/sse'); e.onopen = () => { e.close(); res('open'); }; e.onerror = () => { e.close(); rej(new Error('sse err')); }; }),
      beacon: async (b) => navigator.sendBeacon(b + '/beacon', 'x'),
      img: (b) => new Promise((res, rej) => { const i = new Image(); i.onload = () => res('load'); i.onerror = () => rej(new Error('img err')); i.src = b + '/img.png'; }),
    },
    net2: {
      css_link: (b) => new Promise((res, rej) => { const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = b + '/s.css'; l.onload = () => res('load'); l.onerror = () => rej(new Error('css err')); document.head.appendChild(l); }),
      font: async (b) => { const f = new FontFace('m1f', 'url(' + b + '/f.woff2)'); await f.load(); return 'loaded'; },
      audio: (b) => new Promise((res) => { const a = new Audio(); a.src = b + '/a.mp3'; a.onerror = () => res('err'); a.load(); setTimeout(() => res('queued'), 500); }),
      worker_url: (b) => new Promise((res, rej) => { const w = new Worker(b + '/w.js'); w.onerror = () => rej(new Error('worker err')); setTimeout(() => res('queued'), 500); }),
      script_src: (b) => new Promise((res, rej) => { const s = document.createElement('script'); s.src = b + '/code.js'; s.onload = () => res('load'); s.onerror = () => rej(new Error('script err')); document.head.appendChild(s); }),
      module_import: async (b) => { await import(b + '/code-mod.js'); return 'imported'; },
      iframe: (b) => new Promise((res) => { const f = document.createElement('iframe'); f.src = b + '/iframe'; f.onload = () => res('load'); document.body.appendChild(f); setTimeout(() => res('queued'), 500); }),
      form: (b) => new Promise((res) => { const f = document.createElement('form'); f.action = b + '/form'; f.method = 'post'; document.body.appendChild(f); try { f.submit(); } catch (e) {} setTimeout(() => res('submitted'), 500); }),
    },
    css: {
      css_import: (b) => new Promise((res) => { const s = document.createElement('style'); s.textContent = '@import url("' + b + '/import.css");'; document.head.appendChild(s); setTimeout(() => res('queued'), 500); }),
      css_bgimage: (b) => new Promise((res) => { const d = document.createElement('div'); d.style.cssText = 'width:5px;height:5px;background:url("' + b + '/bg.png")'; document.body.appendChild(d); setTimeout(() => res('queued'), 500); }),
    },
  };
  if (perTarget[G]) {
    for (const [tn, base] of Object.entries(targets)) {
      if (!base) continue;
      for (const [name, fn] of Object.entries(perTarget[G])) await T('C_' + name + '_' + tn, () => fn(base));
    }
  } else if (G === 'webrtc') {
    await T('C_webrtc_stun', async () => {
      const pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:127.0.0.1:' + CFG.udp }] });
      pc.createDataChannel('x');
      await pc.setLocalDescription(await pc.createOffer());
      await new Promise((r) => setTimeout(r, 1200));
      return pc.iceGatheringState;
    });
  } else if (G === 'run1' || G === 'run2') {
    rep('C_inline_hashed_ran', !!window.__inlineHashedRan);
    rep('C_inline_unhashed_ran', !!window.__inlineUnhashedRan);
    let text = null;
    try { text = await (await fetch(S2 + '/code.js')).text(); rep('C_fetch_code_text_from_S2', 'len=' + text.length); } catch (e) { rep('C_fetch_code_text_from_S2', 'fail ' + e); }
    // code under test: the fetched text when the fetch worked, else a local string (shows the CSP, not the network, is what stops it)
    const src = text !== null ? text : code('local_text');
    const kind = (k) => text !== null ? src.replace(/RAN_remote_script_from_S2/, 'RAN_fetched_' + k) : code(k);
    const R = {
      run1: {
        inline_script_el: () => { const s = document.createElement('script'); s.textContent = kind('inline_script_el'); document.head.appendChild(s); },
        blob_script: () => { const s = document.createElement('script'); s.src = URL.createObjectURL(new Blob([kind('blob_script')], { type: 'text/javascript' })); document.head.appendChild(s); },
        data_script: () => { const s = document.createElement('script'); s.src = 'data:text/javascript,' + encodeURIComponent(kind('data_script')); document.head.appendChild(s); },
        blob_worker: () => { new Worker(URL.createObjectURL(new Blob(["fetch('http://127.0.0.1:" + REP + "/r?RAN_blob_worker=1')"], { type: 'text/javascript' }))); },
        data_worker: () => { new Worker('data:text/javascript,' + encodeURIComponent("fetch('http://127.0.0.1:" + REP + "/r?RAN_data_worker=1')")); },
        import_blob: () => import(URL.createObjectURL(new Blob([kind('import_blob')], { type: 'text/javascript' }))),
        import_data: () => import('data:text/javascript,' + encodeURIComponent(kind('import_data'))),
      },
      run2: {
        eval: () => { (0, eval)(kind('eval')); },
        new_Function: () => { new Function(kind('new_Function'))(); },
        setTimeout_string: () => { setTimeout(kind('setTimeout_string'), 0); },
        wasm: async () => { await WebAssembly.instantiate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0])); (new Image).src = 'http://127.0.0.1:' + REP + '/r?RAN_wasm=1'; },
        inline_handler: () => { const d = document.createElement('div'); d.innerHTML = '<img src="x" onerror="(new Image).src=\'http://127.0.0.1:' + REP + '/r?RAN_inline_handler=1\'">'; document.body.appendChild(d); },
        javascript_url: () => { const a = document.createElement('a'); a.href = "javascript:(new Image).src='http://127.0.0.1:" + REP + "/r?RAN_javascript_url=1'"; document.body.appendChild(a); a.click(); },
        srcdoc_iframe: () => { const f = document.createElement('iframe'); f.srcdoc = '<script>(new Image).src="http://127.0.0.1:' + REP + '/r?RAN_srcdoc=1"<\/script>'; document.body.appendChild(f); },
      },
    }[G];
    for (const [name, fn] of Object.entries(R)) await T('C_run_' + name, async () => { await fn(); return 'attempted'; });
  }
  await new Promise((r) => setTimeout(r, 700));
  rep('C_csp_violations', viol.length + ' :: ' + viol.slice(0, 30).join(' | '));
  rep('C_done', G);
});
