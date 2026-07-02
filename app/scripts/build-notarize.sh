#!/usr/bin/env bash
# Builds the signed app bundle with notarization enabled.
# Reads APPLE_ID / APPLE_PASSWORD / APPLE_TEAM_ID from the worktree-root
# .env (never committed) and exports them for the Tauri bundler, which
# notarizes automatically once macOS.signingIdentity is set in
# tauri.conf.json. No secrets are ever written into tracked config files.
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$APP_DIR/../.env"

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

cd "$APP_DIR"
exec pnpm tauri build
