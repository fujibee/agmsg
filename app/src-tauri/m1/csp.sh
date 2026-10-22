#!/bin/bash
# prints the per-pane CSP of design 4.4 (placeholders <own>/<net> are filled by the pane server)
H=$(printf '%s' '/*M1-INLINE-HASHED*/ window.__inlineHashedRan = true;' | openssl dgst -sha256 -binary | openssl base64)
echo "default-src <own>; script-src <own> 'sha256-$H'; style-src <own> 'unsafe-inline'; img-src <own> <net> data: blob:; font-src <own> <net> data:; media-src <own> <net> blob:; connect-src <own> <net>; frame-src 'none'; worker-src <own>; form-action 'none'; base-uri 'none'"
