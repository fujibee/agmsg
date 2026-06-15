[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $LauncherPath,
    [string] $FunctionName = 'agmsg',
    [string] $ProfilePath = $PROFILE.CurrentUserAllHosts
)

$ErrorActionPreference = 'Stop'

if (-not $LauncherPath) {
    $LauncherPath = Join-Path $PSScriptRoot 'agmsg.ps1'
}

if (-not (Test-Path -LiteralPath $LauncherPath)) {
    throw "Launcher not found: $LauncherPath"
}

$resolvedLauncher = (Resolve-Path -LiteralPath $LauncherPath).Path
$profileDir = Split-Path -Parent $ProfilePath
if ($profileDir -and -not (Test-Path -LiteralPath $profileDir)) {
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
}

$start = "# >>> agmsg PowerShell launcher >>>"
$end = "# <<< agmsg PowerShell launcher <<<"
$escapedLauncher = $resolvedLauncher.Replace("'", "''")
$block = @"
$start
function $FunctionName {
    & '$escapedLauncher' @args
}
$end
"@

$existing = ''
if (Test-Path -LiteralPath $ProfilePath) {
    $existing = Get-Content -Raw -LiteralPath $ProfilePath
}

$pattern = "(?s)\r?\n?$([regex]::Escape($start)).*?$([regex]::Escape($end))\r?\n?"
if ($existing -match $pattern) {
    $updated = [regex]::Replace($existing, $pattern, "`r`n$block`r`n", 1)
} elseif ($existing -match "(?m)^\s*function\s+$([regex]::Escape($FunctionName))\b") {
    Write-Warning "Profile already defines function $FunctionName outside the agmsg managed block: $ProfilePath"
    Write-Output "No changes written. Remove or rename the existing function, or rerun with -FunctionName <name>."
    exit 2
} else {
    $prefix = if ($existing.Trim().Length -gt 0) { "$existing`r`n" } else { '' }
    $updated = "$prefix$block`r`n"
}

if ($PSCmdlet.ShouldProcess($ProfilePath, "Install $FunctionName launcher for $resolvedLauncher")) {
    Set-Content -LiteralPath $ProfilePath -Value $updated -Encoding UTF8
    Write-Output "Installed $FunctionName launcher in $ProfilePath"
} else {
    Write-Output $block
}
