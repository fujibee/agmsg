#!/bin/bash
# Verdicts for the net pane's records in an app log. Sourced by run-win.sh (and by selftest.sh with
# made-up logs). The caller defines `verdict PASS|FAIL <step> <text>` and sets L to the log file.
#
# Every record is one line `report={"k":"NET_<kind>","v":"<label>|<value>"}` in the debug trace. A step's
# label ties a violation, an outcome or a refusal to the thing that caused it, so a violation raised by
# one step (for example the eval probe) can never stand in for another.

recs() { sed -n "s/.*\"k\":\"$1\",\"v\":\"\\(.*\\)\"}\$/\\1/p" "$L"; }
rec_of() { recs "$1" | grep "^$2|" | head -1 | cut -d'|' -f2-; }          # value of the first record of kind $1 for label $2
viol_has() { recs NET_viol | awk -v p="$1|enforce|$2|$3" 'index($0,p)==1{f=1} END{exit !f}'; }   # an enforced violation of this step: label, directive, blocked address (prefix)
cancels_in() { # refusals the app logged between a step's attempt and done markers
  awk -v a="\"k\":\"NET_attempt\",\"v\":\"$1\"}" -v d="\"k\":\"NET_done\",\"v\":\"$1\"}" \
    'index($0,a){f=1;next} index($0,d){f=0} f && (/cancelled a frame navigation/ || /cancelled navigation to/)' "$L" | wc -l | tr -d ' '
}

# ---- Windows evidence (only the WebView2 guard writes these lines, so on macOS none exist and nothing below applies)
#   [addons] frame nav <id> start target=<app|pane|other> allowed=<bool>
#   [addons] frame nav <id> done success=<bool> status=<n>
# A cancelled navigation can replace the frame's document with an error page, so the pane's own script may
# never say "I am still here". What shows the frame did not become the app is the guard's own record: every
# navigation to the app origin was refused at its start and none of them ever completed successfully.
win_guard_present() { grep -q '^\[addons\] frame nav [0-9]* start ' "$L"; }
app_navs_ids() { sed -n 's/^\[addons\] frame nav \([0-9]*\) start target=app allowed=\(.*\)$/\1 \2/p' "$L"; }
nav_done_of() { sed -n "s/^\[addons\] frame nav $1 done success=\([a-z]*\) status=\(.*\)\$/\1 \2/p" "$L" | head -1; }   # "<success> <status>" or nothing
# ids of the frame navigations to the app origin that started inside one nav case (from its NAV_case_start to the next pane's START)
case_app_ids() {
  awk -v c="\"k\":\"NAV_case_start\",\"v\":\"$1\"}" 'index($0,c){f=1;next} f && /"k":"START"/{f=0} f && /^\[addons\] frame nav [0-9]+ start target=app /{print $4}' "$L"
}
# any completion with success=true for this navigation id (all records of the id are looked at, not the first)
nav_committed() { grep -q "^\[addons\] frame nav $1 done success=true " "$L"; }
# what is wrong with the navigations to the app origin anywhere in the log (empty = nothing): one that the guard
# allowed, or any of them that completed successfully
app_navs_problem() {
  local id allowed
  while read -r id allowed; do
    [ -n "$id" ] || continue
    [ "$allowed" = "false" ] || { echo "a navigation to the app origin was allowed (id $id)"; return; }
    nav_committed "$id" && { echo "a navigation to the app origin completed successfully (id $id)"; return; }
  done < <(app_navs_ids)
}
# the frame navigations the guard saw between a net step's attempt and done markers (start lines)
frame_navs_in() {
  awk -v a="\"k\":\"NET_attempt\",\"v\":\"$1\"}" -v d="\"k\":\"NET_done\",\"v\":\"$1\"}" \
    'index($0,a){f=1;next} index($0,d){f=0} f && /^\[addons\] frame nav [0-9]+ start /' "$L"
}
# the addresses of the enforced reports of one directive for one step ("<empty>" for an empty one), one per line
viol_addrs() { recs NET_viol | awk -F'|' -v l="$1" -v dir="$2" '$1==l && $2=="enforce" && $3==dir {a=$4; for(i=5;i<=NF;i++) a=a "|" $i; print (a==""?"<empty>":a)}'; }

# eval_nav <case>: the pane was still itself 3 s after the attempt (macOS), or the guard's record shows the
# navigation to the app was refused and ended unsuccessfully and no navigation to the app ever committed (Windows)
eval_nav() {
  local c=$1
  if ! grep -q "\"k\":\"NAV_case_start\",\"v\":\"$c\"" "$L"; then verdict FAIL "S3-nav-$c" "the case never started"; return; fi
  # with the Windows guard record, an allowed or completed navigation to the app origin fails the case whatever the pane said
  if win_guard_present; then
    local problem; problem=$(app_navs_problem)
    if [ -n "$problem" ]; then verdict FAIL "S3-nav-$c" "$problem"; return; fi
  fi
  if grep -q "\"k\":\"NAV_alive_after_3s\",\"v\":\"$c http://127.0.0.1:" "$L"; then verdict PASS "S3-nav-$c" "the pane was still itself 3 s after the attempt"; return; fi
  if win_guard_present; then
    local ids id d seen=0 why=""
    ids=$(case_app_ids "$c")
    for id in $ids; do
      seen=1; d=$(nav_done_of "$id")
      case "$d" in
        false*) why="the guard refused the navigation to the app origin and it ended without success (status ${d#false })" ;;
        *) why="the guard refused the navigation to the app origin at its start (no completion event followed)" ;;
      esac
    done
    if [ "$seen" = 0 ]; then verdict FAIL "S3-nav-$c" "the pane did not report and the guard recorded no navigation to the app origin in this case"; return; fi
    verdict PASS "S3-nav-$c" "$why; no navigation to the app origin was allowed or completed anywhere in the log (the pane itself did not report after the attempt)"; return
  fi
  verdict FAIL "S3-nav-$c" "no alive report: the frame may have become the app"
}

direct_realm() { # direct_realm <label> <what>: the step ran its own code in that realm
  local v; v=$(rec_of NET_outcome "$1")
  case "$v" in
    absent) verdict PASS "S3-realm-$1" "script ran in $2 and found no WebRTC name" ;;
    "blocked:document SecurityError / eval SecurityError"|"blocked:worker error"|"blocked:threw "*) verdict PASS "S3-realm-$1" "$2: $v (no script could run in it)" ;;
    *) verdict FAIL "S3-realm-$1" "$2: ${v:-<no record>}" ;;
  esac
}

# frame_status <label>: ran-absent | ran-present:<names> | blocked:<why> | fail:<why>   (set -> the verdict decides)
frame_status() {
  local label=$1 ran loaded n
  ran=$(recs NET_realm | grep "^$label|" | head -1 | cut -d'|' -f2-)
  case "$ran" in
    absent) echo ran-absent; return ;;
    ?*) echo "ran-present:$ran"; return ;;
  esac
  loaded=$(rec_of NET_loaded "$label")
  case "$label" in blob|data)
    if viol_has "$label" frame-src "$label"; then echo "blocked:an enforced frame-src report names the $label: address"; return; fi
    # WebView2 raises the enforced report with an empty address for blob:/data: frames. The step made exactly one
    # frame, the report carries its label, and the guard's own cancellation is logged inside the step window.
    # Exact: every enforced frame-src report of the step has an empty address (another address is not this case),
    # and the guard saw exactly one frame navigation in the step window, refused (a second one would be ambiguous).
    if win_guard_present; then
      local addrs navs
      addrs=$(viol_addrs "$label" frame-src); navs=$(frame_navs_in "$label")
      if [ -n "$addrs" ] && [ "$(echo "$addrs" | grep -vc '^<empty>$')" = 0 ] && [ "$(echo "$navs" | grep -c .)" = 1 ] && echo "$navs" | grep -q 'allowed=false$'; then
        echo "blocked:an enforced frame-src report for this step (no address given by the engine) and the guard refused the one frame navigation of the step"; return
      fi
    fi ;;
  esac
  n=$(cancels_in "$label")
  if [ "$loaded" = false ] && [ "$n" -ge 1 ]; then echo "blocked:the frame never loaded and the app logged $n refused navigation(s) during this step"; return; fi
  if [ "$loaded" = true ]; then echo "fail:loaded but no script reported and no enforced refusal was recorded"
  else echo "fail:no script report, load=${loaded:-<none>}, refused navigations during the step: $n"; fi
}

frame_realm() { # frame_realm <label> <what>
  local st; st=$(frame_status "$1")
  case "$st" in
    ran-absent) verdict PASS "S3-realm-$1" "script ran in $2 and found no WebRTC name" ;;
    blocked:*) verdict PASS "S3-realm-$1" "$2: ${st#blocked:}" ;;
    ran-present:*) verdict FAIL "S3-realm-$1" "$2 exposes WebRTC: ${st#ran-present:}" ;;
    *) verdict FAIL "S3-realm-$1" "$2: ${st#fail:}" ;;
  esac
}

egress() { # egress <label> <directive> <blocked address prefix>
  local v; v=$(rec_of NET_outcome "$1")
  case "$v" in
    sent|answered|OPEN|loaded) verdict FAIL "S3-egress-$1" "the request went through ($v)"; return ;;
    "") verdict FAIL "S3-egress-$1" "no outcome was recorded"; return ;;
  esac
  if viol_has "$1" "$2" "$3"; then verdict PASS "S3-egress-$1" "blocked ($v) with an enforced $2 report for $3"
  elif [ "$v" = "threw SecurityError" ]; then verdict PASS "S3-egress-$1" "refused before any request was made (threw SecurityError)"
  else verdict FAIL "S3-egress-$1" "outcome $v but no enforced $2 report for $3"; fi
}

eval_net() {
  direct_realm top_first_script "the first script of the page"
  direct_realm top "the pane page"
  frame_realm srcdoc "the srcdoc child"
  # the nested child can only exist if the srcdoc child ran script; if that child was refused, nothing could create it
  local ns ps; ns=$(frame_status nested); ps=$(frame_status srcdoc)
  case "$ns" in
    fail:*|"blocked:"*)
      case "$ps" in blocked:*) verdict PASS S3-realm-nested "its parent frame was refused (${ps#blocked:}), so no script could create it" ;; *) frame_realm nested "the nested child" ;; esac ;;
    *) frame_realm nested "the nested child" ;;
  esac
  direct_realm blank "the about:blank child"
  frame_realm blob "the blob: child"
  frame_realm data "the data: child"
  direct_realm worker "the dedicated worker"
  direct_realm sharedworker "the shared worker"
  local v; v=$(rec_of NET_outcome live_attempt); echo "INFO S3-live-attempt ${v:-<none>}"
  v=$(rec_of NET_outcome eval)
  # new Function() throws EvalError only when the policy refuses eval; where the engine also raises the report, it must be an enforced one
  if [ "$v" = "blocked EvalError" ]; then
    if viol_has eval script-src eval; then verdict PASS S3-eval "eval refused (EvalError) with an enforced script-src report"
    elif recs NET_viol | grep -q '^eval|report|'; then verdict FAIL S3-eval "eval refused but only a report-only violation was recorded"
    else verdict PASS S3-eval "eval refused (EvalError, which only the policy raises); this engine raised no report event"; fi
  else verdict FAIL S3-eval "eval: ${v:-<none>}"; fi
  egress fetch_sink connect-src http://127.0.0.1:47931/fetch
  egress xhr_sink connect-src http://127.0.0.1:47931/xhr
  egress websocket_sink connect-src ws://127.0.0.1:47931/
  egress eventsource_sink connect-src http://127.0.0.1:47931/es
  egress beacon_sink connect-src http://127.0.0.1:47931/beacon
  egress image_sink img-src http://127.0.0.1:47931/i.png
  egress fetch_lan_like connect-src http://192.0.2.1/x
  egress fetch_https connect-src https://example.com/
  egress image_lan_like img-src http://192.0.2.1/x.png
  if grep -q '"k":"NET_alive"' "$L"; then verdict PASS S3-net-finished "the net pane ran to the end"; else verdict FAIL S3-net-finished "no end record"; fi
}
