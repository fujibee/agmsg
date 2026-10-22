// M1 C (navigation): the frame tries to leave. One target per launch (location.hash = case name).
let REP = null;
const rep = (k, v) => { try { new Image().src = 'http://127.0.0.1:' + REP + '/r?' + encodeURIComponent(k) + '=' + encodeURIComponent(String(v)); } catch (e) {} };
const K = location.hash.slice(1);
window.addEventListener('message', async (ev) => {
  if (!ev.data || ev.data.m1 !== 'cfg') return;
  const cfg = ev.data.cfg; REP = cfg.report;
  const S1 = 'http://127.0.0.1:' + cfg.s1, LAN = cfg.lan ? 'http://' + cfg.lan : 'http://127.0.0.2:1';
  rep('NAV_case_start', K);
  const go = {
    app_tauri: () => { location.href = 'tauri://localhost/'; },
    app_tauri_localhost_http: () => { location.href = 'http://tauri.localhost/'; },
    app_https: () => { location.href = 'https://tauri.localhost/'; },
    asset: () => { location.href = 'asset://localhost/etc/hosts'; },
    file: () => { location.href = 'file:///etc/hosts'; },
    ipc: () => { location.href = 'ipc://localhost/addon_canary'; },
    ext_https: () => { location.href = 'https://example.com/'; },
    other_loopback: () => { location.href = S1 + '/nav-other-loopback'; },
    lan: () => { location.href = LAN + '/nav-lan'; },
    redirect_to_app: () => { location.href = S1 + '/redir?to=' + encodeURIComponent('tauri://localhost/'); },
    redirect_to_loopback: () => { location.href = S1 + '/redir?to=' + encodeURIComponent('http://127.0.0.1:' + cfg.s2 + '/via-redirect'); },
    replace: () => { location.replace('tauri://localhost/'); },
    meta_refresh: () => { const m = document.createElement('meta'); m.httpEquiv = 'refresh'; m.content = '0;url=tauri://localhost/'; document.head.appendChild(m); },
    window_open: () => { const w = window.open(S1 + '/window-open', '_blank'); rep('NAV_window_open_result', String(w)); },
    window_open_app: () => { const w = window.open('tauri://localhost/', '_blank'); rep('NAV_window_open_result', String(w)); },
    target_blank: () => { const a = document.createElement('a'); a.href = S1 + '/target-blank'; a.target = '_blank'; document.body.appendChild(a); a.click(); },
    top_nav: () => { try { window.top.location.href = S1 + '/top-nav'; rep('NAV_top_result', 'no throw'); } catch (e) { rep('NAV_top_result', 'threw ' + e.name); } },
    parent_nav: () => { try { window.parent.location.href = S1 + '/parent-nav'; rep('NAV_parent_result', 'no throw'); } catch (e) { rep('NAV_parent_result', 'threw ' + e.name); } },
    download: () => { const a = document.createElement('a'); a.href = S1 + '/dl.bin'; a.download = 'x.bin'; document.body.appendChild(a); a.click(); },
    download_blob: () => { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(['x'])); a.download = 'x.txt'; document.body.appendChild(a); a.click(); },
    form_post: () => { const f = document.createElement('form'); f.action = S1 + '/form-nav'; f.method = 'post'; document.body.appendChild(f); f.submit(); },
    srcdoc_nav: () => { const f = document.createElement('iframe'); f.srcdoc = '<a id=a href="tauri://localhost/">x</a><script>location.href="tauri://localhost/"<\/script>'; document.body.appendChild(f); },
    about_blank_child: () => { const f = document.createElement('iframe'); document.body.appendChild(f); try { f.contentWindow.location.href = 'tauri://localhost/'; rep('NAV_about_blank', 'set'); } catch (e) { rep('NAV_about_blank', 'threw ' + e.name); } },
  }[K];
  if (!go) { rep('NAV_unknown_case', K); return; }
  try { go(); rep('NAV_call_returned', K); } catch (e) { rep('NAV_threw', K + ' ' + e); }
  setTimeout(() => rep('NAV_still_alive_after_2s', K + ' ' + location.href.slice(0, 60)), 2000);
});
