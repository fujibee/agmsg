// Runs inside a child frame of the net pane (srcdoc, blob: or data:). It reports through the parent page:
// which WebRTC names exist here, the violations it sees, and (from the srcdoc child) a nested child of its own.
var RTC_NAMES = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCSessionDescription', 'RTCDataChannel', 'RTCIceCandidate', 'RTCDataChannelEvent', 'RTCRtpSender', 'RTCRtpReceiver', 'RTCDtlsTransport', 'RTCIceTransport', 'RTCSctpTransport', 'RTCCertificate'];
(function () {
  function present() { return RTC_NAMES.filter(function (n) { return typeof window[n] !== 'undefined' || n in window; }).join(','); }
  var atStart = present();
  var me = window.name || 'child';
  function up(m) { m.agmsg_net = true; parent.postMessage(m, '*'); }
  window.addEventListener('message', function (ev) { if (ev.data && ev.data.agmsg_net) parent.postMessage(ev.data, '*'); });
  document.addEventListener('securitypolicyviolation', function (e) { up({ kind: 'viol', label: me === 'srcdoc' ? 'nested' : me, disposition: e.disposition, directive: e.effectiveDirective, uri: String(e.blockedURI) }); });
  up({ kind: 'realm', label: me, present: atStart });
  if (me === 'srcdoc') {
    var n = Math.random().toString(36).slice(2, 10);
    up({ kind: 'nonce', label: 'nested', nonce: n });
    var loaded = false;
    var go = false;
    function createNested() {
      if (go) return;
      go = true;
    try {
      var f = document.createElement('iframe');
      f.name = 'nested';
      f.onload = function () { loaded = true; };
      f.srcdoc = '<script src="' + new URL('child.js', location.href).href + '?n=' + n + '"></' + 'script>';
      document.body.appendChild(f);
    } catch (e) { up({ kind: 'realm', label: 'nested', present: 'threw ' + e.name }); }
    setTimeout(function () { up({ kind: 'loaded', label: 'nested', loaded: loaded }); up({ kind: 'done', label: 'nested' }); }, 2000);
    }
    // the parent writes the attempt marker first and tells us when it is on record
    window.addEventListener('message', function (ev) { if (ev.data && ev.data.agmsg_ack) createNested(); });
    up({ kind: 'attempt', label: 'nested' });
    setTimeout(createNested, 1500);
  }
})();
