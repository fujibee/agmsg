// Dedicated or shared worker of the net pane: which WebRTC names exist here.
var RTC_NAMES = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCSessionDescription', 'RTCDataChannel', 'RTCIceCandidate', 'RTCDataChannelEvent', 'RTCRtpSender', 'RTCRtpReceiver', 'RTCDtlsTransport', 'RTCIceTransport', 'RTCSctpTransport', 'RTCCertificate'];
var found = RTC_NAMES.filter(function (n) { return typeof self[n] !== 'undefined' || n in self; }).join(',');
if (typeof postMessage === 'function') postMessage(found);
self.onconnect = function (e) { e.ports[0].postMessage(found); };
