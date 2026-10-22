#!/bin/bash
# D: pane-server cases, driven with curl against a running spike app. usage: m1/d.sh <variant> <profile> <tag>
cd "$(dirname "$0")/.."
. m1/env.sh
tag=$3; D=$RUN/dfix; D2=$RUN/dfix2; out=$RUN/$tag.txt
mkdir -p $D/sub $D2; printf 'pane1-index' > $D/index.html; printf 'sub-file' > $D/sub/file.txt; printf 'pane2-index' > $D2/index.html
printf 'OUTSIDE-SECRET' > $RUN/outside.txt
ln -sfn /etc/hosts $D/link; ln -sfn $RUN $D/sublink; ln -f $RUN/outside.txt $D/hard.txt
if [ -n "${M1_PREBUILT:-}" ]; then
  EXE=$(prebuilt_exe "$1" "$2") || exit 2
else
  export TAURI_CONFIG='{"identifier":"cc.agmsg.m1spike"}' M1_VARIANT=$1
  flags="--features tauri/custom-protocol"; [ "$2" = release ] && flags="$flags --release"
  cargo build $flags 2>&1 | grep -E "^error|Finished"
  EXE=target/$2/agmsg-app
fi
export M1_SPIKE=1 M1_LOG=$RUN_N/$tag.log M1_PAYLOAD=$(nat "$D") M1_PAYLOAD2=$(nat "$D2") AGMSG_APP_BASE=$RUN_N/base M1_ENTRY=none.html
mkdir -p "$RUN/base"
rm -f "$RUN/$tag.log"; "$EXE" > "$RUN/$tag.out" 2>&1 & APP=$!
sleep 4
P1=$(grep -o 'PANE1 port=[0-9]* token=[0-9a-f]*' $RUN/$tag.log); PORT=$(echo $P1 | sed 's/.*port=\([0-9]*\).*/\1/'); T=$(echo $P1 | sed 's/.*token=//')
P2=$(grep -o 'PANE2 port=[0-9]* token=[0-9a-f]*' $RUN/$tag.log); PORT2=$(echo $P2 | sed 's/.*port=\([0-9]*\).*/\1/'); T2=$(echo $P2 | sed 's/.*token=//')
echo "pane1=$PORT pane2=$PORT2" > $out
c() { # label, curl args...
  local label=$1; shift
  local body code
  body=$(curl -s --path-as-is -m 5 -o - -w '\n%{http_code}' "$@" 2>&1); code=$(echo "$body" | tail -1); body=$(echo "$body" | sed '$d' | head -c 60)
  leak=""; echo "$body" | grep -q "OUTSIDE-SECRET\|localhost" && leak=" **LEAK**"
  printf '%-34s %s  body=%q%s\n' "$label" "$code" "$body" "$leak" >> $out
}
B=http://127.0.0.1:$PORT
c valid                       $B/$T/index.html
c valid_head                  -I $B/$T/index.html
c traversal_encoded_slash     $B/$T/..%2f..%2foutside.txt
c traversal_dotdot_encoded    "$B/$T/%2e%2e/%2e%2e/etc/hosts"
c traversal_raw_dotdot        "$B/$T/../../etc/hosts"
c traversal_inner_dotdot      "$B/$T/sub/../index.html"
c traversal_double_encoded    "$B/$T/%252e%252e/etc/hosts"
c backslash                   "$B/$T/..%5coutside.txt"
c backslash_raw               "$B/$T/sub%5cfile.txt"
c drive_letter                "$B/$T/C:/Windows/win.ini"
c drive_letter_encoded        "$B/$T/C%3a/Windows/win.ini"
c unc                         "$B/$T/%5c%5cserver%5cshare%5cx"
c nul_byte                    "$B/$T/index.html%00.txt"
c absolute_double_slash       "$B/$T//etc/hosts"
c symlink_file                $B/$T/link
c symlink_dir                 $B/$T/sublink/outside.txt
c hardlink_to_outside         $B/$T/hard.txt
c wrong_token                 $B/00000000000000000000000000000000/index.html
c no_token                    $B/index.html
c token_no_slash              $B/$T
c directory_no_listing        $B/$T/sub
c directory_slash             $B/$T/sub/
c other_pane_token_on_pane1   $B/$T2/index.html
c pane1_token_on_pane2        http://127.0.0.1:$PORT2/$T/index.html
c pane2_valid                 http://127.0.0.1:$PORT2/$T2/index.html
c host_evil                   -H "Host: evil.test:$PORT" $B/$T/index.html
c host_no_port                -H "Host: 127.0.0.1" $B/$T/index.html
c host_localhost              -H "Host: localhost:$PORT" $B/$T/index.html
c host_other_port             -H "Host: 127.0.0.1:1" $B/$T/index.html
c method_POST                 -X POST -d x $B/$T/index.html
c method_PUT                  -X PUT -d x $B/$T/index.html
c method_DELETE               -X DELETE $B/$T/index.html
c method_OPTIONS              -X OPTIONS $B/$T/index.html
c method_TRACE                -X TRACE $B/$T/index.html
c query_with_secret           "$B/$T/index.html?secret=QRYSECRET"
c header_with_secret          -H "Authorization: Bearer HDRSECRET" -H "Cookie: c=COOKIESECRET" $B/$T/index.html
c response_headers            -s -D - -o /dev/null $B/$T/index.html
{ echo "--- response headers"; curl -s -D - -o /dev/null $B/$T/index.html | tr -d '\r'; echo "--- redirects? (curl -L on directory)"; curl -s -L -o /dev/null -w '%{http_code} %{num_redirects}\n' $B/$T/sub; echo "--- log scan for logged secrets"; grep -c "QRYSECRET\|HDRSECRET\|COOKIESECRET" $RUN/$tag.log; } >> $out
kill $APP 2>/dev/null; command -v taskkill >/dev/null 2>&1 && taskkill //F //IM "$(basename "$EXE")" >/dev/null 2>&1; wait $APP 2>/dev/null
cat $out
