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

[ "$bad" = 0 ] && echo "selftest: all expectations hold" || { echo "selftest: FAILED"; exit 1; }
