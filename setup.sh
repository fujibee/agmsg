#!/usr/bin/env bash
set -euo pipefail
TMP=$(mktemp -d)
git clone --depth 1 https://github.com/fujibee/agmsg.git "$TMP/agmsg" 2>/dev/null
"$TMP/agmsg/install.sh" "$@"
rm -rf "$TMP"
