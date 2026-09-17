#!/usr/bin/env bash
# Shared filesystem-name encoding for reservation and lock paths.
#
# This helper has no caller-environment requirements so core storage hooks can
# use the same encoding even when SKILL_DIR is unset.

if ! declare -F _actas_lock_encode >/dev/null 2>&1; then
  _actas_lock_encode() {
    printf '%s' "$1" | LC_ALL=C awk '
      BEGIN { for (n = 0; n < 256; n++) ord[sprintf("%c", n)] = n }
      {
        for (i = 1; i <= length($0); i++) {
          c = substr($0, i, 1)
          if (c ~ /[A-Za-z0-9._\-]/) printf "%s", c
          else printf "%%%02X", ord[c]
        }
      }
    '
  }
fi
