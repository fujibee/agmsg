# Authenticode-signs one file with Azure Trusted Signing. Invoked by the Tauri
# bundler (bundle > windows > signCommand) once per artifact DURING the build:
# the bare app exe before it is packed into the MSI cab / NSIS installer, then
# the installers themselves. That ordering is the point — the updater's
# minisign .sig is generated after signing, over the bytes that actually ship
# (issue #333: post-build in-place signing invalidated the .sig and corrupted
# the MSI cabinet).
#
# Auth: DefaultAzureCredential. In CI, azure/login provides the Azure CLI
# credential via OIDC (federated for the main branch only — no client secret
# exists, which is why trusted-signing-cli is not usable here).
param(
  [Parameter(Mandatory = $true)]
  [string]$File
)

$ErrorActionPreference = "Stop"

if (-not (Get-Module -ListAvailable -Name TrustedSigning)) {
  Install-Module -Name TrustedSigning -Force -Scope CurrentUser -Repository PSGallery
}

Invoke-TrustedSigning `
  -Endpoint "https://eus.codesigning.azure.net/" `
  -CodeSigningAccountName "agmsg-artifact-signing" `
  -CertificateProfileName "agmsg-app-signing" `
  -FileDigest SHA256 `
  -TimestampRfc3161 "http://timestamp.acs.microsoft.com" `
  -TimestampDigest SHA256 `
  -Files $File
