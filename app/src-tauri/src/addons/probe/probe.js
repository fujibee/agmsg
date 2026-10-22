// The app's own startup probe. It runs in a frame with exactly the same
// webview, preferences, sandbox and CSP as a real add-on pane, and reports to
// the app (its parent), which relays the answer to Rust. Nothing here is
// trusted by anything but the gate: a missing answer means add-ons stay off.
(function () {
  var cfg;
  try { cfg = JSON.parse(decodeURIComponent(location.hash.slice(1))); } catch (e) { return; }
  var r = {
    nonce: cfg.nonce,
    started: true,
    opaqueOrigin: self.origin === 'null',
    cspBlocksEval: false,
    navRefused: false,
    webrtcAbsent: false,
    bridgeInFrame: false,
  };
  try { (0, eval)('1'); } catch (e) { r.cspBlocksEval = true; }
  var names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCSessionDescription', 'RTCDataChannel'];
  r.webrtcAbsent = names.every(function (n) { return typeof window[n] === 'undefined'; });
  r.bridgeInFrame = ['__TAURI_INTERNALS__', '__TAURI__', 'ipc'].some(function (n) { return typeof window[n] !== 'undefined'; }) ||
    !!(window.chrome && window.chrome.webview);
  // Positive control: if WebRTC exists at all, use it so the UDP sentinel the app
  // opened can count the leak.
  if (typeof window.RTCPeerConnection !== 'undefined') {
    try {
      var pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:127.0.0.1:' + cfg.udp }] });
      pc.createDataChannel('x');
      pc.createOffer().then(function (o) { return pc.setLocalDescription(o); }).catch(function () {});
    } catch (e) { /* ignored */ }
  }
  // The forbidden thing: navigate this frame to the app origin. If the page-level
  // CSP did not refuse it, this document is replaced and the timer below never
  // fires, so no answer arrives and the gate stays off.
  try { location.href = cfg.appOrigin + '/__agmsg_probe_nav__'; } catch (e) { /* ignored */ }
  setTimeout(function () {
    r.navRefused = true;
    parent.postMessage({ agmsgProbe: 1, report: r }, '*');
  }, 2000);
})();
