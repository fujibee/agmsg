// Runs inside a child frame of the net pane: reports which WebRTC names exist here, then, one level down, repeats once.
var RTC_NAMES = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCSessionDescription', 'RTCDataChannel', 'RTCIceCandidate', 'RTCDataChannelEvent', 'RTCRtpSender', 'RTCRtpReceiver', 'RTCDtlsTransport', 'RTCIceTransport', 'RTCSctpTransport', 'RTCCertificate'];
(function () {
  function present() { return RTC_NAMES.filter(function (n) { return typeof window[n] !== 'undefined' || n in window; }).join(','); }
  var atStart = present();
  var me = window.name || 'child';
  window.addEventListener('message', function (ev) { if (ev.data && ev.data.realm) parent.postMessage(ev.data, '*'); });
  parent.postMessage({ realm: me, present: atStart }, '*');
  if (me === 'srcdoc') {
    try {
      var f = document.createElement('iframe');
      f.name = 'nested';
      f.srcdoc = '<script src="child.js"></' + 'script>';
      document.body.appendChild(f);
    } catch (e) { parent.postMessage({ realm: 'nested', present: 'threw ' + e.name }, '*'); }
  }
})();
