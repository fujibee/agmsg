// Measurement pane (a developer add-on, never shipped). It reports through the broker: `open.args`
// ignores its arguments, and a debug build with AGMSG_ADDON_TRACE=1 prints them as "report=...".
// One case per pane, named by data-case on the script tag.
var RTC_NAMES = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCSessionDescription', 'RTCDataChannel', 'RTCIceCandidate', 'RTCDataChannelEvent', 'RTCRtpSender', 'RTCRtpReceiver', 'RTCDtlsTransport', 'RTCIceTransport', 'RTCSctpTransport', 'RTCCertificate'];
// first statement of the first script of the page: what exists before anything else ran
var RTC_AT_START = RTC_NAMES.filter(function (n) { return typeof window[n] !== 'undefined' || n in window; }).join(',');
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

  function present(w) { try { return RTC_NAMES.filter(function (n) { return typeof w[n] !== 'undefined' || n in w; }).join(','); } catch (e) { return 'threw ' + e.name; } }
  function net() {
    var realms = {};
    var loaded = {};
    function setRealm(k, v) { if (!(k in realms)) realms[k] = v; }
    report('NET_realm_top_first_script', RTC_AT_START === '' ? 'absent' : 'PRESENT:' + RTC_AT_START);
    report('NET_realm_top', present(window) === '' ? 'absent' : 'PRESENT:' + present(window));

    // a child frame that runs a pane script (srcdoc inherits the pane CSP, so its script-src allows pane files)
    window.addEventListener('message', function (ev) {
      var d = ev.data;
      if (d && d.realm) setRealm(d.realm, d.present === '' ? 'absent' : 'PRESENT:' + d.present);
    });
    try {
      var g = document.createElement('iframe');
      g.name = 'srcdoc';
      g.onload = function () { loaded.srcdoc = true; };
      g.srcdoc = '<script src="child.js"></' + 'script>';
      document.body.appendChild(g);
    } catch (e) { setRealm('srcdoc', 'blocked:threw ' + e.name); }
    // an about:blank child: this page may not reach into it, and it has no way to run script of its own
    try {
      var f = document.createElement('iframe');
      document.body.appendChild(f);
      var how = [];
      try { f.contentWindow.document; how.push('document reachable'); } catch (e) { how.push('document ' + e.name); }
      try { f.contentWindow.eval('1'); how.push('eval ran'); } catch (e) { how.push('eval ' + e.name); }
      realms.blank_detail = how.join(' / ');
      setRealm('blank', how.some(function (h) { return h.indexOf('reachable') >= 0 || h.indexOf('eval ran') >= 0; }) ? 'PRESENT:reachable ' + present(f.contentWindow) : 'blocked:' + how.join(' / '));
    } catch (e) { setRealm('blank', 'blocked:threw ' + e.name); }
    // blob: and data: children
    try {
      var b = document.createElement('iframe');
      b.name = 'blob';
      b.onload = function () { loaded.blob = true; };
      b.src = URL.createObjectURL(new Blob(['<script src="' + location.origin + location.pathname + 'child.js"></' + 'script>'], { type: 'text/html' }));
      document.body.appendChild(b);
    } catch (e) { setRealm('blob', 'blocked:threw ' + e.name); }
    try {
      var dd = document.createElement('iframe');
      dd.name = 'data';
      dd.onload = function () { loaded.data = true; };
      dd.src = 'data:text/html,' + encodeURIComponent('<script src="' + location.origin + location.pathname + 'child.js"></' + 'script>');
      document.body.appendChild(dd);
    } catch (e) { setRealm('data', 'blocked:threw ' + e.name); }
    // workers
    try {
      var w = new Worker('worker.js');
      w.onmessage = function (ev) { setRealm('worker', ev.data === '' ? 'absent' : 'PRESENT:' + ev.data); };
      w.onerror = function () { setRealm('worker', 'blocked:worker error'); };
    } catch (e) { setRealm('worker', 'blocked:threw ' + e.name); }
    try {
      var sw = new SharedWorker('worker.js');
      sw.port.onmessage = function (ev) { setRealm('sharedworker', ev.data === '' ? 'absent' : 'PRESENT:' + ev.data); };
      sw.onerror = function () { setRealm('sharedworker', 'blocked:worker error'); };
    } catch (e) { setRealm('sharedworker', 'blocked:threw ' + e.name); }

    // a live attempt in every realm that still has the API (none should): points at a local UDP+TCP sink
    try {
      if (typeof RTCPeerConnection !== 'undefined') {
        var pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:127.0.0.1:47931' }, { urls: 'turn:127.0.0.1:47931?transport=tcp', username: 'u', credential: 'c' }] });
        pc.createDataChannel('x'); pc.createOffer().then(function (o) { return pc.setLocalDescription(o); });
        report('NET_live_attempt', 'RTCPeerConnection existed and was used');
      } else { report('NET_live_attempt', 'no API to use'); }
    } catch (e) { report('NET_live_attempt', 'threw ' + e.name); }

    var names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCSessionDescription', 'RTCDataChannel', 'RTCIceCandidate'];
    report('NET_webrtc_globals', names.map(function (n) { return n + '=' + typeof window[n]; }).join(' '));
    try { new Function('return 1')(); report('NET_eval', 'ALLOWED'); } catch (e) { report('NET_eval', 'blocked ' + e.name); }
    var SINK = '127.0.0.1:47931';
    var tries = {
      fetch_sink: function () { return fetch('http://' + SINK + '/fetch', { mode: 'no-cors' }).then(function () { return 'sent'; }, function () { return 'failed'; }); },
      xhr_sink: function () { return new Promise(function (r) { try { var x = new XMLHttpRequest(); x.open('GET', 'http://' + SINK + '/xhr'); x.onload = function () { r('answered'); }; x.onerror = function () { r('error'); }; x.send(); } catch (e) { r('threw ' + e.name); } }); },
      websocket_sink: function () { return new Promise(function (r) { try { var s = new WebSocket('ws://' + SINK + '/'); s.onerror = function () { r('error'); }; s.onopen = function () { r('OPEN'); }; } catch (e) { r('threw ' + e.name); } }); },
      eventsource_sink: function () { return new Promise(function (r) { try { var s = new EventSource('http://' + SINK + '/es'); s.onerror = function () { r('error'); }; s.onopen = function () { r('OPEN'); }; } catch (e) { r('threw ' + e.name); } }); },
      beacon_sink: function () { return Promise.resolve(String(navigator.sendBeacon('http://' + SINK + '/beacon', 'x'))); },
      image_sink: function () { return new Promise(function (r) { var i = new Image(); i.onload = function () { r('loaded'); }; i.onerror = function () { r('error'); }; i.src = 'http://' + SINK + '/i.png'; }); },
      fetch_lan_like: function () { return fetch('http://192.0.2.1/x', { mode: 'no-cors' }).then(function () { return 'sent'; }, function () { return 'failed'; }); },
      fetch_https: function () { return fetch('https://example.com/', { mode: 'no-cors' }).then(function () { return 'sent'; }, function () { return 'failed'; }); },
      image_lan_like: function () { return new Promise(function (r) { var i = new Image(); i.onload = function () { r('loaded'); }; i.onerror = function () { r('error'); }; i.src = 'http://192.0.2.1/x.png'; }); }
    };
    Object.keys(tries).forEach(function (k) {
      var done = false;
      var tm = setTimeout(function () { if (!done) report('NET_' + k, 'no answer in 4s'); }, 4000);
      tries[k]().then(function (v) { done = true; clearTimeout(tm); report('NET_' + k, v); });
    });
    // settle: every realm either answered or the CSP says why it cannot
    setTimeout(function () {
      var viol = violations.join(' | ');
      ['srcdoc', 'nested', 'blob', 'data', 'worker', 'sharedworker'].forEach(function (k) {
        if (k in realms) return;
        var why = '';
        if ((k === 'blob' || k === 'data') && /frame-src/.test(viol)) why = 'frame-src violation seen';
        else if (/worker/.test(k) && /worker-src/.test(viol)) why = 'worker-src violation seen';
        else if ((k === 'srcdoc' || k === 'blob' || k === 'data') && !loaded[k]) why = 'no load event: the frame never loaded (navigation refused)';
        else if (k === 'nested' && !loaded.srcdoc) why = 'its parent frame never loaded';
        else if (/script-src/.test(viol)) why = 'script-src violation seen';
        realms[k] = why ? 'blocked:' + why : 'noreport';
      });
      report('NET_loaded', JSON.stringify(loaded));
      Object.keys(realms).forEach(function (k) { if (k !== 'blank_detail') report('NET_realm_' + k, realms[k]); });
      report('NET_csp_violations', violations.length + ' ' + viol);
      report('NET_alive', 'yes');
    }, 6000);
  }

  function start() {
    report('START', K + ' ' + location.href.slice(0, 40));
    if (K === 'net') net(); else nav();
  }
})();
