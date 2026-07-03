#!/usr/bin/env bash
# Builds the signed, notarized app bundle, and signs the updater artifacts.
# Reads APPLE_ID / APPLE_PASSWORD / APPLE_TEAM_ID from the worktree-root
# .env (never committed) and exports them for the Tauri bundler, which
# notarizes automatically once macOS.signingIdentity is set in
# tauri.conf.json. Also points the bundler at the updater's private key
# (worktree-root .secrets/, never committed) so it emits the .sig files
# a GitHub Release needs for auto-update. No secrets are ever written into
# tracked config files.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$APP_DIR/.."
ENV_FILE="$ROOT_DIR/.env"
UPDATER_KEY="$ROOT_DIR/.secrets/agmsg-app-updater.key"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "warning: $ENV_FILE not found; building without notarization credentials" >&2
fi

for var in APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID; do
  if [[ -z "${!var:-}" ]]; then
    echo "warning: $var is not set; notarization will be skipped by the bundler" >&2
  fi
done

if [[ -f "$UPDATER_KEY" ]]; then
  export TAURI_SIGNING_PRIVATE_KEY_PATH="$UPDATER_KEY"
  export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:-}"
else
  echo "warning: $UPDATER_KEY not found; update artifacts won't be signed" >&2
fi

"$APP_DIR/scripts/bundle-core.sh"

cd "$APP_DIR"
exec pnpm tauri build
