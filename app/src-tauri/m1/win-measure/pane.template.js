// Measurement pane (a developer add-on, never shipped). It reports through the broker: `open.args`
// ignores its arguments, and a debug build with AGMSG_ADDON_TRACE=1 prints them as "report=...".
// One case per pane, named by data-case on the script tag.
var RTC_NAMES = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCSessionDescription', 'RTCDataChannel', 'RTCIceCandidate', 'RTCDataChannelEvent', 'RTCRtpSender', 'RTCRtpReceiver', 'RTCDtlsTransport', 'RTCIceTransport', 'RTCSctpTransport', 'RTCCertificate'];
// first statement of the first script of the page: what exists before anything else ran
var RTC_AT_START = RTC_NAMES.filter(function (n) { return typeof window[n] !== 'undefined' || n in window; }).join(',');
(function () {
  var K = document.currentScript.getAttribute('data-case');
  var port = null, id = 1, queue = [];
  var ports = 0, started = false;
  var waiting = {};
  function onResponse(ev) {
    var d = ev.data;
    if (d && d.type === 'response' && waiting[d.id]) { waiting[d.id](); delete waiting[d.id]; }
  }
  // Returns a promise that settles when the app has answered (its trace line is printed before the answer leaves).
  function report(k, v) {
    var m = { agmsg: 1, type: 'request', id: id++, op: 'open.args', args: { k: k, v: String(v).slice(0, 200) } };
    var p = new Promise(function (res) { waiting[m.id] = res; });
    if (port) port.postMessage(m); else queue.push(m);
    return p;
  }
  window.addEventListener('message', function (ev) {
    if (ev.source !== window.parent) return;
    var d = ev.data;
    if (!d || d.agmsg !== 1 || d.type !== 'port' || !ev.ports || !ev.ports[0]) return;
    // The app sends a new port whenever this frame loads again (a refused navigation can count as a load),
    // and answers only the newest one: always switch to it.
    port = ev.ports[0];
    port.onmessage = onResponse;
    port.start();
    ports++;
    while (queue.length) port.postMessage(queue.shift());
    if (ports > 1) report('PORT_AGAIN', ports);
    if (!started) { started = true; start(); }
  });
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
  // Everything the net pane reports is one small record: no truncation, no dependence on order. A record names
  // the step (label) it belongs to; the steps run one after the other, each between an attempt and a done marker.
  function net() {
    var current = '-';
    var nonces = {};
    function nonce(label) { nonces[label] = Math.random().toString(36).slice(2, 10); report('NET_nonce', label + '|' + nonces[label]); return nonces[label]; }
    document.addEventListener('securitypolicyviolation', function (e) {
      report('NET_viol', current + '|' + e.disposition + '|' + e.effectiveDirective + '|' + String(e.blockedURI).slice(0, 110));
    });
    window.addEventListener('message', function (ev) {
      var d = ev.data;
      if (!d || !d.agmsg_net) return;
      if (d.kind === 'realm') report('NET_realm', d.label + '|' + (d.present === '' ? 'absent' : 'PRESENT:' + d.present));
      else if (d.kind === 'viol') report('NET_viol', d.label + '|' + d.disposition + '|' + d.directive + '|' + String(d.uri).slice(0, 110));
      else if (d.kind === 'attempt') report('NET_attempt', d.label).then(function () { try { ev.source.postMessage({ agmsg_ack: true }, '*'); } catch (e) { /* the child is gone */ } });
      else if (d.kind === 'done') report('NET_done', d.label);
      else if (d.kind === 'loaded') report('NET_loaded', d.label + '|' + d.loaded);
      else if (d.kind === 'nonce') report('NET_nonce', d.label + '|' + d.nonce);
    });
    function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
    function ack(p) { return Promise.race([p, sleep(1500)]); }
    function step(label, fn, wait) {
      current = label;
      return ack(report('NET_attempt', label)).then(function () {
        var r;
        try { r = fn(); } catch (e) { report('NET_outcome', label + '|threw ' + e.name); }
        Promise.resolve(r).then(function (v) { if (v !== undefined) report('NET_outcome', label + '|' + v); });
        return sleep(wait);
      }).then(function () { return ack(report('NET_done', label)); });
    }
    function childFrame(label, how) { // a child frame that runs child.js; its load event is recorded
      var f = document.createElement('iframe');
      f.name = label;
      var n = nonce(label);
      var src = new URL('child.js', location.href).href + '?n=' + n;
      var page = '<script src="' + src + '"></' + 'script>';
      var loaded = false;
      f.onload = function () { loaded = true; };
      if (how === 'srcdoc') f.srcdoc = page;
      else if (how === 'blob') f.src = URL.createObjectURL(new Blob([page], { type: 'text/html' }));
      else f.src = 'data:text/html,' + encodeURIComponent(page);
      document.body.appendChild(f);
      return function () { report('NET_loaded', label + '|' + loaded); };
    }
    var chain = Promise.resolve();
    function add(label, fn, wait) { chain = chain.then(function () { return step(label, fn, wait); }); }

    add('top_first_script', function () { return RTC_AT_START === '' ? 'absent' : 'PRESENT:' + RTC_AT_START; }, 100);
    add('top', function () { var p = present(window); return p === '' ? 'absent' : 'PRESENT:' + p; }, 100);
    ['srcdoc', 'blob', 'data'].forEach(function (how) {
      var done;
      add(how, function () { done = childFrame(how, how); }, how === 'srcdoc' ? 4500 : 2500);
      chain = chain.then(function () { if (done) done(); });
    });
    add('blank', function () {
      var f = document.createElement('iframe');
      document.body.appendChild(f);
      var how = [];
      try { f.contentWindow.document; how.push('document reachable'); } catch (e) { how.push('document ' + e.name); }
      try { f.contentWindow.eval('1'); how.push('eval ran'); } catch (e) { how.push('eval ' + e.name); }
      var reach = how.some(function (h) { return h.indexOf('reachable') >= 0 || h.indexOf('eval ran') >= 0; });
      return reach ? 'PRESENT:reachable ' + present(f.contentWindow) : 'blocked:' + how.join(' / ');
    }, 300);
    add('worker', function () {
      return new Promise(function (r) {
        try {
          var w = new Worker('worker.js');
          w.onmessage = function (ev) { r(ev.data === '' ? 'absent' : 'PRESENT:' + ev.data); };
          w.onerror = function () { r('blocked:worker error'); };
        } catch (e) { r('blocked:threw ' + e.name); }
        setTimeout(function () { r('noreport'); }, 1800);
      });
    }, 2000);
    add('sharedworker', function () {
      return new Promise(function (r) {
        try {
          var sw = new SharedWorker('worker.js');
          sw.port.onmessage = function (ev) { r(ev.data === '' ? 'absent' : 'PRESENT:' + ev.data); };
          sw.onerror = function () { r('blocked:worker error'); };
        } catch (e) { r('blocked:threw ' + e.name); }
        setTimeout(function () { r('noreport'); }, 1800);
      });
    }, 2000);
    add('live_attempt', function () {
      if (typeof RTCPeerConnection === 'undefined') return 'no API to use';
      var pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:127.0.0.1:47931' }, { urls: 'turn:127.0.0.1:47931?transport=tcp', username: 'u', credential: 'c' }] });
      pc.createDataChannel('x'); pc.createOffer().then(function (o) { return pc.setLocalDescription(o); });
      return 'RTCPeerConnection existed and was used';
    }, 800);
    add('eval', function () { try { new Function('return 1')(); return 'ALLOWED'; } catch (e) { return 'blocked ' + e.name; } }, 300);

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
    Object.keys(tries).forEach(function (k) { add(k, tries[k], 1200); });
    chain.then(function () { report('NET_alive', 'yes'); });
  }

  function start() {
    report('START', K + ' ' + location.href.slice(0, 40));
    if (K === 'net') net(); else nav();
  }
})();
