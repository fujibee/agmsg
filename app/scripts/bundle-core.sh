#!/usr/bin/env bash
# Bundles a pinned snapshot of agmsg-core into src-tauri/resources/agmsg-core/
# for the app's first-run auto-install flow — see agmsg_install in
# src-tauri/src/agmsg.rs. At runtime the app runs this bundled install.sh
# directly, with no network access. What goes in is exactly the set of files
# the installer reads relative to its own directory (PACK_PATHS below); the
# checks at the end prove that set is closed instead of trusting it.
#
# The ref is a committed pin (AGMSG_CORE_REF), not resolved dynamically at
# build time — that's the point of bundling instead of curl|bash at runtime:
# what ships is fixed and auditable via git history. Bump AGMSG_CORE_REF by
# hand to pick up newer agmsg-core fixes.
#
# Called from three places that must stay in sync: app-release.yml's macOS
# and Windows jobs, and build-notarize.sh for local builds.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$APP_DIR/.."
REF_FILE="$APP_DIR/AGMSG_CORE_REF"
DEST="$APP_DIR/src-tauri/resources/agmsg-core"

REF="$(tr -d '[:space:]' < "$REF_FILE")"
if [ -z "$REF" ]; then
  echo "bundle-core: $REF_FILE is empty" >&2
  exit 1
fi

cd "$ROOT_DIR"
echo "bundle-core: fetching tag $REF..."
# No --depth here — this runs against the same checkout a developer is
# working in (build-notarize.sh calls this directly), and a shallow fetch
# there leaves the whole local repo shallow: git log/merge-base/rebase
# against origin/main silently stop at the new shallow boundary. CI
# checkouts are disposable, so this is a non-issue there either way.
git fetch origin tag "$REF" --no-tags

# Everything install.sh / uninstall.sh / scripts/lib read relative to the
# installer's own directory ($SCRIPT_DIR/...). SKILL.md is not optional: the
# installer renders every installed skill file from it, and a pack without it
# fails the app's "Update agmsg" with "shared SKILL.md is missing" (#1503's
# 0.5.0 build shipped exactly that -- v1.5.1 needs it, v1.1.12 did not, so
# nothing complained while the pin was old). plugins/README.md and openai.yaml
# are copied with `|| true`, so leaving them out never fails -- it just makes
# the app's install silently differ from a normal one, which is why they are
# listed here rather than left to that fallback.
#
# The list is derived by grep, not by eye; the same grep runs again below
# against the packed files and fails the build if a path it finds is absent.
PACK_PATHS=(
  scripts/
  install.sh
  uninstall.sh
  VERSION
  SKILL.md
  plugins/README.md
  openai.yaml
)

rm -rf "$DEST"
mkdir -p "$DEST"
git archive "$REF" -- "${PACK_PATHS[@]}" | tar -x -C "$DEST"
chmod +x "$DEST/install.sh" "$DEST/uninstall.sh"

# Sanity check: the pin must actually satisfy what the app needs from
# agmsg-core, not just exist. v0.1.0 shipped pinned to a tag that predated
# the agmsg-app type registration, so a fresh auto-install died the moment
# a user tried to add an app-user ("Unknown agent type: agmsg-app") — this
# would have caught it at build time instead of in the field. Add to this
# list whenever the app starts depending on more of agmsg-core.
REQUIRED_PATHS=(
  "scripts/api.sh"
  "scripts/drivers/types/agmsg-app/type.conf"
  "VERSION"
  "SKILL.md"
  "plugins/README.md"
  "openai.yaml"
)
for p in "${REQUIRED_PATHS[@]}"; do
  if [ ! -f "$DEST/$p" ]; then
    echo "bundle-core: pinned ref $REF is missing required path '$p' — bump AGMSG_CORE_REF" >&2
    exit 1
  fi
done

# Closure check: every path the installer reads relative to its own directory
# must be in the bundle. PACK_PATHS above was derived from this same scan on
# v1.5.1; running it again on what was actually packed means a later pin that
# starts reading one more file fails HERE, at build time, instead of in a
# user's "Update agmsg". `scripts/.` (a trailing `/.` from `cp -R scripts/.`)
# is folded to `scripts`.
#
# If this ever names a path that is relative to scripts/ at runtime rather
# than to the installer (a `$SCRIPT_DIR/...` inside scripts/lib that means the
# scripts directory), narrow the scan instead of adding the path to the pack.
closure_missing=0
while IFS= read -r rel; do
  rel="${rel%/.}"
  if [ ! -e "$DEST/$rel" ]; then
    echo "bundle-core: the installer reads '$rel' relative to its own directory at $REF, but it is not in the bundle — add it to PACK_PATHS" >&2
    closure_missing=1
  fi
done < <(grep -rhoE '\$\{?SCRIPT_DIR(:-)?\}?/[A-Za-z0-9_.][A-Za-z0-9_./-]*' \
           "$DEST/install.sh" "$DEST/uninstall.sh" "$DEST/scripts/lib" \
         | sed -E 's#^\$\{?SCRIPT_DIR(:-)?\}?/##' | sort -u)
[ "$closure_missing" -eq 0 ] || exit 1

# Render check: run the function that failed in the field, from the packed
# code, once per agent type the installer can render. It reads only the bundle
# (SCRIPT_DIR) and writes only into a fresh temp dir -- no HOME, no CODEX_HOME,
# nothing under ~ -- so it is safe to run on any machine, unlike install.sh
# itself, which writes ~/.agents, ~/.claude, ~/.codex and more with no
# override. The temp dir is left for the OS to clear rather than removed here
# with a variable in `rm`.
render_out="$(mktemp -d "${TMPDIR:-/tmp}/bundle-core-render.XXXXXX")"
if ! (
  SCRIPT_DIR="$DEST"
  # shellcheck disable=SC1091
  . "$DEST/scripts/lib/type-registry.sh"
  agmsg_load_renderable_skill_types
  # shellcheck disable=SC1091
  . "$DEST/scripts/lib/skill-render.sh"
  [ -n "${AGMSG_RENDERABLE_SKILL_TYPES:-}" ] || { echo "bundle-core: no renderable skill types found in the bundle" >&2; exit 1; }
  for t in $AGMSG_RENDERABLE_SKILL_TYPES; do
    agmsg_render_skill "$t" agmsg "$render_out/SKILL-$t.md" || exit 1
    [ -s "$render_out/SKILL-$t.md" ] || { echo "bundle-core: rendered skill for '$t' is empty" >&2; exit 1; }
  done
); then
  echo "bundle-core: the bundled installer cannot render its skill files (see above) — the app's install/update would fail the same way" >&2
  exit 1
fi

echo "bundle-core: bundled agmsg-core @ $REF into $DEST"
