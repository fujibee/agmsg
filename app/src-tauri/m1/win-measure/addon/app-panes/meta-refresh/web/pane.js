// Measurement pane (a developer add-on, never shipped). It reports through the broker: `open.args`
// ignores its arguments, and a debug build with AGMSG_ADDON_TRACE=1 prints them as "report=...".
// One case per pane, named by data-case on the script tag.
(function () {
  var K = document.currentScript.getAttribute('data-case');
  var port = null, id = 1, queue = [];
  function report(k, v) {
    var m = { agmsg: 1, type: 'request', id: id++, op: 'open.args', args: { k: k, v: String(v).slice(0, 200) } };
    if (port) port.postMessage(m); else queue.push(m);
  }
  var ports = 0, started = false;
  window.addEventListener('message', function (ev) {
    if (ev.source !== window.parent) return;
    var d = ev.data;
    if (!d || d.agmsg !== 1 || d.type !== 'port' || !ev.ports || !ev.ports[0]) return;
    // The app sends a new port whenever this frame loads again (a refused navigation can count as a load),
    // and answers only the newest one: always switch to it.
    port = ev.ports[0];
    port.start();
    ports++;
    while (queue.length) port.postMessage(queue.shift());
    if (ports > 1) report('PORT_AGAIN', ports);
    if (!started) { started = true; start(); }
  });
  var violations = [];
  document.addEventListener('securitypolicyviolation', function (e) { violations.push(e.effectiveDirective + ' ' + e.blockedURI); });

  function nav() {
    var go = {
      app_tauri: function () { location.href = 'tauri://localhost/'; },
      app_tauri_localhost_http: function () { location.href = 'http://tauri.localhost/'; },
      app_https: function () { location.href = 'https://tauri.localhost/'; },
      replace: function () { location.replace('tauri://localhost/'); },
      meta_refresh: function () { var m = document.createElement('meta'); m.httpEquiv = 'refresh'; m.content = '0;url=http://tauri.localhost/'; document.head.appendChild(m); }
    }[K];
    report('NAV_case_start', K);
    // let the reports so far leave the page before it tries to go anywhere
    setTimeout(function () {
      try { go(); report('NAV_call_returned', K); } catch (e) { report('NAV_threw', K + ' ' + e.name); }
      setTimeout(function () { report('NAV_alive_after_3s', K + ' ' + location.href.slice(0, 50)); }, 3000);
    }, 800);
  }

  function net() {
    var names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCSessionDescription', 'RTCDataChannel', 'RTCIceCandidate'];
    report('NET_webrtc_globals', names.map(function (n) { return n + '=' + typeof window[n]; }).join(' '));
    try {
      var f = document.createElement('iframe');
      document.body.appendChild(f);
      var w = f.contentWindow;
      report('NET_webrtc_in_about_blank_child', names.map(function (n) { return n + '=' + typeof w[n]; }).join(' '));
    } catch (e) { report('NET_about_blank_child', 'threw ' + e.name); }
    try {
      var g = document.createElement('iframe');
      g.srcdoc = '<script>parent.postMessage({rtc: typeof RTCPeerConnection + "/" + typeof webkitRTCPeerConnection}, "*")<\/script>';
      window.addEventListener('message', function (ev) { if (ev.data && ev.data.rtc) report('NET_webrtc_in_srcdoc_child', ev.data.rtc); });
      document.body.appendChild(g);
    } catch (e) { report('NET_srcdoc_child', 'threw ' + e.name); }
    try { new Function('return 1')(); report('NET_eval', 'ALLOWED'); } catch (e) { report('NET_eval', 'blocked ' + e.name); }
    var tries = {
      fetch_loopback: function () { return fetch('http://127.0.0.1:1/x', { mode: 'no-cors' }).then(function () { return 'sent'; }, function () { return 'failed'; }); },
      fetch_lan_like: function () { return fetch('http://192.0.2.1/x', { mode: 'no-cors' }).then(function () { return 'sent'; }, function () { return 'failed'; }); },
      fetch_https: function () { return fetch('https://example.com/', { mode: 'no-cors' }).then(function () { return 'sent'; }, function () { return 'failed'; }); },
      websocket: function () { return new Promise(function (r) { try { var s = new WebSocket('ws://127.0.0.1:1/'); s.onerror = function () { r('error'); }; s.onopen = function () { r('OPEN'); }; } catch (e) { r('threw ' + e.name); } }); },
      image: function () { return new Promise(function (r) { var i = new Image(); i.onload = function () { r('loaded'); }; i.onerror = function () { r('error'); }; i.src = 'http://192.0.2.1/x.png'; }); }
    };
    Object.keys(tries).forEach(function (k) {
      var done = false;
      var t = setTimeout(function () { if (!done) report('NET_' + k, 'no answer in 4s'); }, 4000);
      tries[k]().then(function (v) { done = true; clearTimeout(t); report('NET_' + k, v); });
    });
    setTimeout(function () { report('NET_csp_violations', violations.length + ' ' + violations.join(' | ')); report('NET_alive', 'yes'); }, 5000);
  }

  function start() {
    report('START', K + ' ' + location.href.slice(0, 40));
    if (K === 'net') net(); else nav();
  }
})();
