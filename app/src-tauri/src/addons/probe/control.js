// Probe stage B. Reaching this document proves an allowed navigation completes
// here and now (the positive control). It then attempts the forbidden one, a
// navigation of this frame to the app origin (cfg.target). Surviving is not
// proof of a refusal: the PARENT page must also have observed an enforced CSP
// violation for exactly this URI, and the app attaches that to the report. If the
// navigation went through, this document is replaced, nothing is reported and
// the gate stays off.
(function () {
  var st;
  try { st = JSON.parse(decodeURIComponent(location.hash.slice(1))); } catch (e) { return; }
  var cfg = st.cfg, r = st.r;
  r.controlNavOk = true;
  r.opaqueOrigin = r.opaqueOrigin && self.origin === 'null';
  try { (0, eval)('1'); r.cspBlocksEval = false; } catch (e) { /* still refused: keep the stage A value */ }
  // Announce first: a cancelled navigation may replace this document (observed on WebView2), and then
  // the final answer below never comes. The app then judges from this report plus its own record.
  parent.postMessage({ agmsgProbe: 1, final: false, report: r }, '*');
  try { location.href = cfg.target; } catch (e) { /* ignored */ }
  setTimeout(function () {
    r.navRefused = true;
    parent.postMessage({ agmsgProbe: 1, final: true, report: r }, '*');
  }, 2000);
})();
