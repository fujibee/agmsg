#!/usr/bin/env bash
set -euo pipefail

# agmsg plugin — manage trust for EXTERNAL drivers (axes: types, and later
# storage / delivery). External drivers are shell code that runs with your
# privileges, so the registry ignores them until you opt in here.
#
# Usage:
#   plugin.sh list                 # discovered drivers + trust state
#   plugin.sh trust <ref>          # opt into an external driver
#   plugin.sh untrust <ref>        # revoke
#
# <ref> is "<axis>/<name>" (e.g. types/codex) or a bare "<name>". A bare name
# matches across axes; if more than one axis has it, you must qualify it.

ACTION="${1:-list}"
shift || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/driver-registry.sh"

# Emit "<kind>\t<axis>\t<name>\t<dir>" for every dir-based driver across all
# search bases (a driver is a directory <base>/<axis>/<name>/).
_plugin_enumerate() {
  local kind base axisdir axis namedir name
  while IFS=$'\t' read -r kind base; do
    [ -d "$base" ] || continue
    for axisdir in "$base"/*/; do
      [ -d "$axisdir" ] || continue
      axis="$(basename "$axisdir")"
      # plugins/sources/ holds installed plugin checkouts; each is its own base
      # (db/plugin-sources), not an axis.
      [ "$axis" != sources ] || continue
      for namedir in "$axisdir"*/; do
        [ -d "$namedir" ] || continue
        name="$(basename "$namedir")"
        printf '%s\t%s\t%s\t%s\n' "$kind" "$axis" "$name" "${namedir%/}"
      done
    done
  done <<EOF
$(agmsg_driver_bases)
EOF
}

# Resolve a user <ref> to a single EXTERNAL driver, echoed as "<axis>\t<name>\t<dir>".
# Bare names match across axes; ambiguity is an error that lists the candidates.
_plugin_resolve_external() {
  local ref="$1" want_axis="" want_name matches count
  case "$ref" in
    */*) want_axis="${ref%%/*}"; want_name="${ref#*/}" ;;
    *)   want_name="$ref" ;;
  esac
  matches="$(_plugin_enumerate | awk -F'\t' -v a="$want_axis" -v n="$want_name" \
    '$1=="external" && $3==n && (a=="" || $2==a) { print $2"\t"$3"\t"$4 }')"
  count="$(printf '%s' "$matches" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    echo "agmsg plugin: no external driver matches '$ref'" >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "agmsg plugin: '$ref' is ambiguous across axes:" >&2
    printf '%s\n' "$matches" | awk -F'\t' '{print "  "$1"/"$2}' >&2
    echo "       qualify it, e.g. agmsg plugin $ACTION $(printf '%s' "$matches" | head -1 | awk -F'\t' '{print $1"/"$2}')" >&2
    return 1
  fi
  printf '%s\n' "$matches"
}

case "$ACTION" in
  list)
    printf '%-26s %-11s %s\n' "AXIS/NAME" "STATE" "PATH"
    _plugin_enumerate | while IFS=$'\t' read -r kind axis name dir; do
      if [ "$kind" = builtin ]; then
        state="builtin"
      elif agmsg_driver_is_trusted "$axis" "$name" "$dir"; then
        state="trusted"
      else
        state="UNTRUSTED"
      fi
      printf '%-26s %-11s %s\n' "$axis/$name" "$state" "$dir"
    done
    ;;
  trust)
    ref="${1:?Usage: plugin.sh trust <axis/name|name>}"
    res="$(_plugin_resolve_external "$ref")" || exit 1
    IFS=$'\t' read -r axis name dir <<<"$res"
    agmsg_driver_trust "$axis" "$name" "$dir"
    echo "Trusted $axis/$name -> $dir"
    ;;
  untrust)
    ref="${1:?Usage: plugin.sh untrust <axis/name|name>}"
    case "$ref" in
      */*) axis="${ref%%/*}"; name="${ref#*/}" ;;
      *)   res="$(_plugin_resolve_external "$ref")" || exit 1
           IFS=$'\t' read -r axis name _ <<<"$res" ;;
    esac
    agmsg_driver_untrust "$axis" "$name"
    echo "Untrusted $axis/$name"
    ;;
  *)
    echo "Usage: agmsg plugin list|trust <ref>|untrust <ref>" >&2
    exit 1
    ;;
esac
