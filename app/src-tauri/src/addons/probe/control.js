// Probe stage B. Reaching this document proves an allowed navigation completes
// here and now (the positive control). It then attempts the forbidden one, a
// navigation of this frame to the app origin. If the page-level CSP refuses it,
// this document survives and reports; if it does not, this document is replaced,
// the timer never fires, no answer arrives and the gate stays off.
(function () {
  var st;
  try { st = JSON.parse(decodeURIComponent(location.hash.slice(1))); } catch (e) { return; }
  var cfg = st.cfg, r = st.r;
  r.controlNavOk = true;
  r.opaqueOrigin = r.opaqueOrigin && self.origin === 'null';
  try { (0, eval)('1'); r.cspBlocksEval = false; } catch (e) { /* still refused: keep the stage A value */ }
  try { location.href = cfg.appOrigin + '/__agmsg_probe_nav__'; } catch (e) { /* ignored */ }
  setTimeout(function () {
    r.navRefused = true;
    parent.postMessage({ agmsgProbe: 1, report: r }, '*');
  }, 2000);
})();
