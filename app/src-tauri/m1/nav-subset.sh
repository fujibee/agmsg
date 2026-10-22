#!/bin/bash
# usage: m1/nav-subset.sh <variant> <profile> <tag> case...   (M1_MAIN_CSP from env)
cd "$(dirname "$0")/.."
. m1/env.sh
export M1_CSP="$(m1/csp.sh)"
v=$1; p=$2; t=$3; shift 3
for k in "$@"; do M1_ENTRY="nav.html#$k" m1/run.sh $v $p "$t-$k" 9 > /dev/null 2>&1; done
echo finished > $RUN/$t.done
