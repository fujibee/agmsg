#!/usr/bin/env bash
set -euo pipefail

# Which ref of the canonical repo to install. The npm bootstrapper
# (bin/agmsg.js) sets AGMSG_REF to the tag matching its own version
# (e.g. v1.0.6) so `npx agmsg@X` installs X — not whatever is on main.
# The README's `curl .../main/setup.sh` form leaves it unset and gets
# main (the latest). See #172.
REF="${AGMSG_REF:-main}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if git clone --depth 1 --branch "$REF" https://github.com/fujibee/agmsg.git "$TMP/agmsg" 2>/dev/null; then
  :
elif command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
  # No git (or the clone failed for some other reason, e.g. no network path to
  # git's protocol) — fall back to a plain tarball download so a machine with
  # no git at all (a fresh, non-developer Mac) can still install. install.sh
  # already tolerates running from a non-git tarball checkout (see its
  # provenance-version comment), so no changes needed there.
  echo "agmsg: git clone unavailable/failed — falling back to a tarball download" >&2
  # A failed git clone can still leave a partial $TMP/agmsg behind (git
  # creates the destination dir before it can fail) — clear it so the
  # tarball's extracted dir moves cleanly into place instead of nesting
  # inside the leftover directory.
  rm -rf "$TMP/agmsg"
  if ! curl -fsSL "https://github.com/fujibee/agmsg/archive/$REF.tar.gz" | tar -xz -C "$TMP" 2>/dev/null; then
    echo "agmsg: failed to download tarball for ref '$REF' from https://github.com/fujibee/agmsg" >&2
    exit 1
  fi
  # GitHub extracts to a single top-level "agmsg-<ref>" directory (slashes in
  # <ref> become dashes) — find it rather than hardcoding the exact name.
  extracted="$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'agmsg-*' | head -1)"
  if [ -z "$extracted" ]; then
    echo "agmsg: tarball downloaded but no agmsg-* directory was found inside it" >&2
    exit 1
  fi
  mv "$extracted" "$TMP/agmsg"
else
  echo "agmsg: failed to clone ref '$REF' from https://github.com/fujibee/agmsg.git (git unavailable, and no curl+tar to fall back to)" >&2
  exit 1
fi
"$TMP/agmsg/install.sh" "$@"
