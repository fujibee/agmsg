// The app's own startup probe, stage A. It runs in a frame with exactly the same
// webview, preferences, sandbox and CSP as a real add-on pane. It measures what
// it can about itself, then makes an ALLOWED navigation (to control.html on the
// same pane) as the positive control: stage B only counts a refusal of the
// forbidden navigation as a refusal if this allowed one is seen to complete.
// A missing answer means add-ons stay off.
(function () {
  var cfg;
  try { cfg = JSON.parse(decodeURIComponent(location.hash.slice(1))); } catch (e) { return; }
  var r = {
    nonce: cfg.nonce,
    started: true,
    opaqueOrigin: self.origin === 'null',
    cspBlocksEval: false,
    navRefused: false,
    controlNavOk: false,
    webrtcAbsent: false,
    bridgeInFrame: false,
  };
  try { (0, eval)('1'); } catch (e) { r.cspBlocksEval = true; }
  var names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCSessionDescription', 'RTCDataChannel'];
  r.webrtcAbsent = names.every(function (n) { return typeof window[n] === 'undefined'; });
  r.bridgeInFrame = ['__TAURI_INTERNALS__', '__TAURI__', 'ipc'].some(function (n) { return typeof window[n] !== 'undefined'; }) ||
    !!(window.chrome && window.chrome.webview);
  // Positive control for WebRTC: if it exists at all, use it so the UDP sentinel
  // the app opened can count the leak.
  if (typeof window.RTCPeerConnection !== 'undefined') {
    try {
      var pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:127.0.0.1:' + cfg.udp }] });
      pc.createDataChannel('x');
      pc.createOffer().then(function (o) { return pc.setLocalDescription(o); }).catch(function () {});
    } catch (e) { /* ignored */ }
  }
  // Stage B is a different document on the same pane; it receives stage A's results.
  var next = { cfg: cfg, r: r };
  location.href = 'control.html#' + encodeURIComponent(JSON.stringify(next));
})();
