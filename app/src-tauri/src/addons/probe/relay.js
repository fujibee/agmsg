// The only code the app runs in the main page for the startup probe: it creates the probe frame and
// relays the frame's postMessage answers to the gate. One instance per probe: everything it needs
// (target, frame, timer, violations) lives in this closure, and starting a new probe stops the
// previous instance first, so a late timer or answer of an old probe can never touch a new one.
// The tokens are filled in by Rust with JSON values.
(function () {
  if (window.__agmsgProbeStop) window.__agmsgProbeStop();
  var target = __TARGET__;
  var src = __SRC__;
  var finalWaitMs = __FINAL_WAIT_MS__;
  var violations = [];
  var frame = null;
  var timer = null;
  var interim = null;
  var live = true;

  // The refusal has to be seen here, in the embedding page: an enforced CSP violation, with the
  // blocked URI and the directive.
  function onViolation(e) {
    if (e.disposition === 'enforce') violations.push([e.effectiveDirective, e.blockedURI]);
  }
  // Every callback checks that it still belongs to the probe that is running now.
  function current() {
    return live && window.__agmsgProbeStop === stop;
  }
  function stop() {
    live = false;
    clearTimeout(timer);
    timer = null;
    interim = null;
    document.removeEventListener('securitypolicyviolation', onViolation);
    window.removeEventListener('message', onMessage);
    if (frame && frame.parentNode) frame.remove();
    frame = null;
    if (window.__agmsgProbeStop === stop) window.__agmsgProbeStop = null;
  }
  function finish(rep) {
    var hit = violations.filter(function (v) { return (v[0] === 'frame-src' || v[0] === 'child-src') && v[1] === target; })[0];
    rep.navViolationDirective = hit ? hit[0] : '';
    rep.navViolationUri = hit ? hit[1] : '';
    stop();
    window.__TAURI_INTERNALS__.invoke('addon_probe_report', { report: rep }).catch(function () {});
  }
  function onMessage(ev) {
    if (!current() || !frame || ev.source !== frame.contentWindow) return;
    var d = ev.data;
    if (!d || d.agmsgProbe !== 1) return;
    var rep = d.report || {};
    if (!d.final) {
      // Stage B is about to attempt the forbidden navigation. If that navigation is cancelled the
      // frame's document may be replaced and never send the final answer: then this interim report
      // goes in after the wait, marked as such.
      interim = rep;
      clearTimeout(timer);
      timer = setTimeout(function () {
        if (!current() || !interim) return;
        var r0 = interim;
        r0.finalMissing = true;
        finish(r0);
      }, finalWaitMs);
      return;
    }
    finish(rep);
  }

  window.__agmsgProbeStop = stop;
  document.addEventListener('securitypolicyviolation', onViolation);
  window.addEventListener('message', onMessage);
  frame = document.createElement('iframe');
  frame.id = 'agmsg-probe-frame';
  frame.setAttribute('sandbox', 'allow-scripts');
  frame.setAttribute('aria-hidden', 'true');
  frame.style.cssText = 'position:fixed;left:0;top:0;width:2px;height:2px;border:0;opacity:0;pointer-events:none';
  frame.src = src;
  document.body.appendChild(frame);
})();
