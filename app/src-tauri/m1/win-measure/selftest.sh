#!/bin/bash
# Checks the verdict logic of evaluate.sh against made-up logs: the cases that must PASS and,
# above all, the ones that must not (a frame that loaded but said nothing, an unrelated violation).
# usage: bash selftest.sh        exits non-zero if any expectation is wrong
cd "$(dirname "$0")" || exit 2
. ./evaluate.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
OUTV=""
verdict() { OUTV="$OUTV$1 $2 $3
"; }
bad=0
R() { echo "[addons-trace] pane=9 gen=1 op=open.args ok 2B report={\"k\":\"$1\",\"v\":\"$2\"}"; }
base() { # the parts every scenario shares
  R NET_alive yes
}
expect() { # expect <PASS|FAIL> <step> <scenario name>
  if echo "$OUTV" | grep -q "^$1 $2 "; then echo "ok   $3"; else echo "WRONG $3: wanted $1 $2, got:"; echo "$OUTV" | grep " $2 " ; bad=1; fi
}
run() { L="$T/log"; cat > "$L"; OUTV=""; eval_net > /dev/null; }

# 1. a srcdoc child that loaded and said nothing, next to the page's own eval violation
{ base
  R NET_attempt srcdoc; R NET_nonce 'srcdoc|abc'; R NET_loaded 'srcdoc|true'; R NET_done srcdoc
  R NET_attempt eval; R NET_viol 'eval|enforce|script-src|eval'; R NET_outcome 'eval|blocked EvalError'; R NET_done eval
} > "$T/in"; run < "$T/in"
expect FAIL S3-realm-srcdoc "silent loaded srcdoc child fails even with another step's script-src violation"

# 2. a srcdoc child that never loaded, with the app's refusal logged in its own window
{ base
  R NET_attempt srcdoc; echo '[addons] cancelled a frame navigation'; R NET_loaded 'srcdoc|false'; R NET_done srcdoc
} > "$T/in"; run < "$T/in"
expect PASS S3-realm-srcdoc "unloaded srcdoc child with a refusal in its window passes"

# 3. never loaded but the only refusal happened in another step's window
{ base
  echo '[addons] cancelled a frame navigation'
  R NET_attempt srcdoc; R NET_loaded 'srcdoc|false'; R NET_done srcdoc
} > "$T/in"; run < "$T/in"
expect FAIL S3-realm-srcdoc "a refusal outside the step does not count"

# 4. a srcdoc child that ran and found WebRTC
{ base; R NET_attempt srcdoc; R NET_realm 'srcdoc|PRESENT:RTCPeerConnection'; R NET_done srcdoc; } > "$T/in"; run < "$T/in"
expect FAIL S3-realm-srcdoc "a child exposing WebRTC fails"

# 5. a srcdoc child that ran clean
{ base; R NET_attempt srcdoc; R NET_realm 'srcdoc|absent'; R NET_done srcdoc; } > "$T/in"; run < "$T/in"
expect PASS S3-realm-srcdoc "a child that ran and found nothing passes"

# 6. blob child: loaded (error page) with the enforced frame-src report vs. without it
{ base; R NET_attempt blob; R NET_viol 'blob|enforce|frame-src|blob'; R NET_loaded 'blob|true'; R NET_done blob; } > "$T/in"; run < "$T/in"
expect PASS S3-realm-blob "blob child refused by an enforced frame-src report passes"
{ base; R NET_attempt blob; R NET_viol 'srcdoc|enforce|frame-src|blob'; R NET_loaded 'blob|true'; R NET_done blob; } > "$T/in"; run < "$T/in"
expect FAIL S3-realm-blob "a frame-src report of another step does not count"
{ base; R NET_attempt blob; R NET_viol 'blob|report|frame-src|blob'; R NET_loaded 'blob|true'; R NET_done blob; } > "$T/in"; run < "$T/in"
expect FAIL S3-realm-blob "a report-only violation does not count"

# 7. nested: parent refused means nothing could create it; parent ran and nested silent fails
{ base
  R NET_attempt srcdoc; echo '[addons] cancelled a frame navigation'; R NET_loaded 'srcdoc|false'; R NET_done srcdoc
} > "$T/in"; run < "$T/in"
expect PASS S3-realm-nested "nested child passes when its parent was refused"
{ base
  R NET_attempt srcdoc; R NET_realm 'srcdoc|absent'; R NET_done srcdoc
  R NET_attempt nested; R NET_loaded 'nested|true'; R NET_done nested
} > "$T/in"; run < "$T/in"
expect FAIL S3-realm-nested "a loaded, silent nested child fails"

# 7b. frames that are allowed to run script and are WebRTC-free: both measured, both pass
{ base
  R NET_attempt srcdoc; R NET_realm 'srcdoc|absent'; R NET_done srcdoc
  R NET_attempt nested; R NET_realm 'nested|absent'; R NET_loaded 'nested|true'; R NET_done nested
} > "$T/in"; run < "$T/in"
expect PASS S3-realm-srcdoc "an allowed, clean srcdoc child passes"
expect PASS S3-realm-nested "an allowed, clean nested child passes"
{ base
  R NET_attempt srcdoc; R NET_realm 'srcdoc|absent'; R NET_done srcdoc
  R NET_attempt nested; R NET_realm 'nested|PRESENT:RTCPeerConnection'; R NET_done nested
} > "$T/in"; run < "$T/in"
expect FAIL S3-realm-nested "an allowed nested child exposing WebRTC fails"

# 8. egress: went through, blocked with the matching report, blocked without any report
{ base; R NET_attempt fetch_lan_like; R NET_outcome 'fetch_lan_like|sent'; R NET_done fetch_lan_like; } > "$T/in"; run < "$T/in"
expect FAIL S3-egress-fetch_lan_like "a request that went through fails"
{ base; R NET_attempt fetch_lan_like; R NET_viol 'fetch_lan_like|enforce|connect-src|http://192.0.2.1/x'; R NET_outcome 'fetch_lan_like|failed'; R NET_done fetch_lan_like; } > "$T/in"; run < "$T/in"
expect PASS S3-egress-fetch_lan_like "a refused request with its report passes"
{ base; R NET_attempt fetch_lan_like; R NET_outcome 'fetch_lan_like|failed'; R NET_done fetch_lan_like; } > "$T/in"; run < "$T/in"
expect FAIL S3-egress-fetch_lan_like "a failure without a report is not evidence"
{ base; R NET_attempt fetch_lan_like; R NET_viol 'fetch_https|enforce|connect-src|https://example.com/'; R NET_outcome 'fetch_lan_like|failed'; R NET_done fetch_lan_like; } > "$T/in"; run < "$T/in"
expect FAIL S3-egress-fetch_lan_like "another request's report does not count"

# 9. no record at all
{ base; } > "$T/in"; run < "$T/in"
expect FAIL S3-egress-fetch_sink "a missing egress record fails"
expect FAIL S3-realm-top "a missing realm record fails"


# ---- navigation cases: the pane's own report on macOS, the guard's record on Windows (never one for the other)
runnav() { L="$T/log"; cat > "$L"; OUTV=""; eval_nav "$1"; }
NS() { R NAV_case_start "$1"; }
NA() { R NAV_alive_after_3s "$1 http://127.0.0.1:5/x"; }
GS() { echo "[addons] frame nav $1 start target=$2 allowed=$3"; }
GD() { echo "[addons] frame nav $1 done success=$2 status=$3"; }
ST() { R START "$1 http://127.0.0.1:5/x"; }
{ ST replace; NS replace; NA replace; } > "$T/in"; runnav replace < "$T/in"
expect PASS S3-nav-replace "macOS: the pane alive after the attempt passes"
{ ST replace; NS replace; echo '[addons] cancelled navigation to tauri://localhost/'; } > "$T/in"; runnav replace < "$T/in"
expect FAIL S3-nav-replace "macOS: no alive report and no guard record fails, as before"
{ ST replace; NS replace; R NAV_call_returned replace; GS 7 app false; echo '[addons] cancelled a frame navigation'; GD 7 false 1; ST next; } > "$T/in"; runnav replace < "$T/in"
expect PASS S3-nav-replace "Windows: refused at start, ended unsuccessfully, nothing ever committed to the app passes"
{ ST replace; NS replace; GS 7 app false; echo '[addons] cancelled a frame navigation'; ST next; } > "$T/in"; runnav replace < "$T/in"
expect PASS S3-nav-replace "Windows: refused at start with no completion event passes"
{ ST replace; NS replace; GS 7 app false; GD 7 true 0; ST next; } > "$T/in"; runnav replace < "$T/in"
expect FAIL S3-nav-replace "Windows: a navigation to the app that completed successfully fails"
{ ST replace; NS replace; GS 7 app true; ST next; } > "$T/in"; runnav replace < "$T/in"
expect FAIL S3-nav-replace "Windows: a navigation to the app that the guard allowed fails"
{ ST replace; NS replace; GS 3 pane true; ST next; } > "$T/in"; runnav replace < "$T/in"
expect FAIL S3-nav-replace "Windows: no navigation to the app recorded in this case fails (nothing shown)"
{ GS 1 app false; GD 1 false 1; ST a; NS a; GS 2 app false; ST b; NS b; GS 9 app false; GD 9 true 0; } > "$T/in"; runnav a < "$T/in"
expect FAIL S3-nav-a "Windows: another case's app navigation that completed makes every case fail"
{ ST replace; NS replace; GS 7 other false; ST next; } > "$T/in"; runnav replace < "$T/in"
expect FAIL S3-nav-replace "Windows: a refused navigation to somewhere else is not the app's"
{ ST replace; GS 7 app false; GD 7 false 1; ST x; NS x; } > "$T/in"; runnav replace < "$T/in"
expect FAIL S3-nav-replace "Windows: an app navigation from before the case does not count for it"

# ---- the pane's "alive" does not override the guard's record on Windows
{ ST replace; NS replace; GS 7 app true; GD 7 true 0; NA replace; ST next; } > "$T/in"; runnav replace < "$T/in"
expect FAIL S3-nav-replace "Windows: an allowed and completed app navigation fails even when the pane reports alive"
{ ST replace; NS replace; GS 7 app false; GD 7 false 1; GD 7 true 0; NA replace; ST next; } > "$T/in"; runnav replace < "$T/in"
expect FAIL S3-nav-replace "Windows: a later success of the same id fails (every record of the id is read)"
{ ST replace; NS replace; GS 7 app true; NA replace; ST next; } > "$T/in"; runnav replace < "$T/in"
expect FAIL S3-nav-replace "Windows: an allowed app navigation fails even when the pane reports alive"
{ ST replace; NS replace; GS 7 app false; GD 7 false 1; NA replace; ST next; } > "$T/in"; runnav replace < "$T/in"
expect PASS S3-nav-replace "Windows: alive with every app navigation refused passes"
{ ST a; NS a; NA a; GS 1 app false; GD 1 false 1; ST b; NS b; GS 2 app true; GD 2 true 0; } > "$T/in"; runnav a < "$T/in"
expect FAIL S3-nav-a "Windows: another case's allowed app navigation fails this case too"

# ---- blob/data: WebView2 raises the enforced report with an empty address
winblob() { echo '[addons] frame nav 5 start target=other allowed=false'; }
{ base; R NET_attempt blob; winblob; echo '[addons] cancelled a frame navigation'; R NET_viol 'blob|enforce|frame-src|'; R NET_loaded 'blob|true'; R NET_done blob; } > "$T/in"; run < "$T/in"
expect PASS S3-realm-blob "Windows: enforced frame-src report without an address + the guard's cancellation in the step passes"
{ base; R NET_attempt blob; echo '[addons] cancelled navigation to blob:'; R NET_viol 'blob|enforce|frame-src|'; R NET_loaded 'blob|true'; R NET_done blob; } > "$T/in"; run < "$T/in"
expect FAIL S3-realm-blob "an empty address without the Windows guard record does not pass (macOS judgement unchanged)"
{ base; winblob; R NET_attempt blob; R NET_viol 'blob|enforce|frame-src|'; R NET_loaded 'blob|true'; R NET_done blob; } > "$T/in"; run < "$T/in"
expect FAIL S3-realm-blob "an empty address with the guard's navigation outside the step window fails"
{ base; R NET_attempt blob; winblob; R NET_viol 'blob|enforce|frame-src|https://unrelated.invalid/'; R NET_loaded 'blob|true'; R NET_done blob; } > "$T/in"; run < "$T/in"
expect FAIL S3-realm-blob "an enforced report with another address does not stand in for the blob: frame"
{ base; R NET_attempt blob; winblob; R NET_viol 'blob|enforce|frame-src|'; R NET_viol 'blob|enforce|frame-src|https://unrelated.invalid/'; R NET_loaded 'blob|true'; R NET_done blob; } > "$T/in"; run < "$T/in"
expect FAIL S3-realm-blob "an empty address next to a report with another address fails"
{ base; R NET_attempt blob; winblob; echo '[addons] frame nav 6 start target=other allowed=false'; R NET_viol 'blob|enforce|frame-src|'; R NET_loaded 'blob|true'; R NET_done blob; } > "$T/in"; run < "$T/in"
expect FAIL S3-realm-blob "two frame navigations in the step window are ambiguous and fail"
{ base; R NET_attempt blob; echo '[addons] frame nav 5 start target=other allowed=true'; R NET_viol 'blob|enforce|frame-src|'; R NET_loaded 'blob|true'; R NET_done blob; } > "$T/in"; run < "$T/in"
expect FAIL S3-realm-blob "a frame navigation the guard allowed does not count as refused"
{ base; R NET_attempt blob; winblob; echo '[addons] cancelled a frame navigation'; R NET_viol 'blob|report|frame-src|'; R NET_loaded 'blob|true'; R NET_done blob; } > "$T/in"; run < "$T/in"
expect FAIL S3-realm-blob "an empty address on a report-only violation fails"
{ base; R NET_attempt data; winblob; echo '[addons] cancelled a frame navigation'; R NET_viol 'data|enforce|frame-src|'; R NET_loaded 'data|true'; R NET_done data; } > "$T/in"; run < "$T/in"
expect PASS S3-realm-data "Windows: the same for a data: child"

[ "$bad" = 0 ] && echo "selftest: all expectations hold" || { echo "selftest: FAILED"; exit 1; }
