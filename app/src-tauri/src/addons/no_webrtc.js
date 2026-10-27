// Windows (WebView2): take WebRTC out of every frame of the main webview, at document start.
// The browser flag only changes which addresses WebRTC may use; it does not remove the API, and a
// pane must have no way to open a peer connection at all. Run before any page script, in all frames.
(function () {
  var names = [
    'RTCPeerConnection', 'webkitRTCPeerConnection', 'mozRTCPeerConnection', 'RTCSessionDescription', 'RTCIceCandidate',
    'RTCDataChannel', 'RTCDataChannelEvent', 'RTCPeerConnectionIceEvent', 'RTCPeerConnectionIceErrorEvent',
    'RTCRtpSender', 'RTCRtpReceiver', 'RTCRtpTransceiver', 'RTCRtpScriptTransform', 'RTCDtlsTransport',
    'RTCIceTransport', 'RTCSctpTransport', 'RTCCertificate', 'RTCDTMFSender', 'RTCDTMFToneChangeEvent',
    'RTCError', 'RTCErrorEvent', 'RTCStatsReport', 'RTCEncodedAudioFrame', 'RTCEncodedVideoFrame'
  ];
  for (var i = 0; i < names.length; i++) {
    var k = names[i];
    try { delete window[k]; } catch (e) { /* fall through to the redefinition */ }
    if (typeof window[k] !== 'undefined' || k in window) {
      try { Object.defineProperty(window, k, { value: undefined, writable: false, configurable: false }); } catch (e) { /* the probe reports what is still there */ }
    }
  }
})();
