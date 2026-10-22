#!/bin/bash
# usage: m1/nav-all.sh <variant> <profile> <tag>  [M1_MAIN_CSP via env]
cd "$(dirname "$0")/.."
. m1/env.sh
export M1_CSP="$(m1/csp.sh)"
for k in app_tauri app_tauri_localhost_http app_https asset file ipc ext_https other_loopback lan redirect_to_app redirect_to_loopback replace meta_refresh window_open window_open_app target_blank top_nav parent_nav download download_blob form_post srcdoc_nav about_blank_child; do
  M1_ENTRY="nav.html#$k" m1/run.sh "$1" "$2" "$3-$k" 9 > /dev/null 2>&1
done
echo finished > $RUN/$3.done
