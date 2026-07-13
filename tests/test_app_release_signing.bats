#!/usr/bin/env bats

# Regression guards for issue #333: on Windows, Authenticode signing must
# happen DURING `tauri build` (bundle > windows > signCommand), never as a
# post-build in-place pass — signing after the build mutates bytes the
# updater's minisign .sig was already computed over (every 0.1.4 in-app
# update failed verification) and corrupted the MSI's embedded cabinet.
# Real signing is only exercisable on main (OIDC federated identity), so
# these tests pin the workflow's structure instead.

WORKFLOW="${BATS_TEST_DIRNAME}/../.github/workflows/app-release.yml"
SIGN_SCRIPT="${BATS_TEST_DIRNAME}/../app/scripts/sign-windows.ps1"

@test "app-release: no post-build in-place signing action remains" {
  # `run` + explicit status check, not bare `! grep ...`: bash's `set -e`
  # (which bats enables for the test body) exempts `!`-negated commands from
  # aborting the function on failure, so two bare `! grep` statements in a
  # row would silently swallow the first one's failure — only the LAST
  # statement's exit code would determine the test's outcome.
  run grep -q -- "uses: azure/artifact-signing-action" "$WORKFLOW"
  [ "$status" -ne 0 ]
  run grep -q -- "uses: azure/trusted-signing-action" "$WORKFLOW"
  [ "$status" -ne 0 ]
}

@test "app-release: azure login runs before the windows build" {
  login_line="$(grep -n "azure/login" "$WORKFLOW" | head -1 | cut -d: -f1)"
  build_line="$(grep -n "pnpm tauri build --config" "$WORKFLOW" | head -1 | cut -d: -f1)"
  [ -n "$login_line" ]
  [ -n "$build_line" ]
  [ "$login_line" -lt "$build_line" ]
}

@test "app-release: windows build wires signCommand to sign-windows.ps1 per artifact" {
  grep -q "signCommand" "$WORKFLOW"
  grep -q "sign-windows.ps1" "$WORKFLOW"
  grep -q '$sign_script %1' "$WORKFLOW"
}

@test "app-release: shipped artifacts are verified as Authenticode-signed" {
  grep -q "Get-AuthenticodeSignature" "$WORKFLOW"
}

@test "sign-windows.ps1: same trusted-signing account/profile the action used" {
  grep -q "Invoke-TrustedSigning" "$SIGN_SCRIPT"
  grep -q "https://eus.codesigning.azure.net/" "$SIGN_SCRIPT"
  grep -q "agmsg-artifact-signing" "$SIGN_SCRIPT"
  grep -q "agmsg-app-signing" "$SIGN_SCRIPT"
}
