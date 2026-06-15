[CmdletBinding()]
param(
    [string] $Team,
    [string] $Agent,
    [Parameter(Position = 0)]
    [string] $Command = 'inbox',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Rest
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

$script:ScriptsDir = Split-Path -Parent $PSScriptRoot
$script:AgentType = if ($env:AGMSG_AGENT_TYPE) { $env:AGMSG_AGENT_TYPE } else { 'codex' }
$script:Bash = $null

function Find-GitBash {
    $candidates = @()
    if ($env:GIT_BASH) { $candidates += $env:GIT_BASH }
    if ($env:AGMSG_BASH) { $candidates += $env:AGMSG_BASH }
    $candidates += @(
        'C:\Program Files\Git\bin\bash.exe',
        'C:\Program Files\Git\usr\bin\bash.exe',
        'C:\Program Files (x86)\Git\bin\bash.exe'
    )

    foreach ($cmd in Get-Command bash.exe -All -ErrorAction SilentlyContinue) {
        $path = if ($cmd.Source) { $cmd.Source } else { $cmd.Path }
        if ($path) { $candidates += $path }
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if ($candidate -match '\\WindowsApps\\bash\.exe$') { continue }
        if ($candidate -notmatch '\\Git\\') { continue }
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if ($candidate -match '\\WindowsApps\\bash\.exe$') { continue }
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'Git Bash not found. Install Git for Windows or set GIT_BASH to Git for Windows bash.exe.'
}

function Invoke-WithPythonUtf8 {
    param([scriptblock] $Block)

    $oldPythonIoEncoding = $env:PYTHONIOENCODING
    try {
        $env:PYTHONIOENCODING = 'utf-8'
        & $Block
    } finally {
        if ($null -eq $oldPythonIoEncoding) {
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
        } else {
            $env:PYTHONIOENCODING = $oldPythonIoEncoding
        }
    }
}

function ConvertTo-BashPath {
    param([string] $Path)

    $resolved = if (Test-Path -LiteralPath $Path) {
        (Resolve-Path -LiteralPath $Path).Path
    } else {
        $Path
    }

    $converted = (& $script:Bash -lc 'cygpath -u "$1"' agmsg-path $resolved 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $converted) {
        return $resolved
    }
    return $converted
}

function Test-SqliteAvailable {
    Invoke-WithPythonUtf8 {
        & $script:Bash -lc 'command -v sqlite3 >/dev/null 2>&1 && sqlite3 --version >/dev/null'
        if ($LASTEXITCODE -ne 0) {
            Write-Error 'sqlite3 is required and must be executable from Git Bash. Install sqlite3 or add it to the Git Bash PATH.'
            exit 127
        }
    }
}

$script:Bash = Find-GitBash
Test-SqliteAvailable

$dispatcher = Join-Path $script:ScriptsDir 'dispatch.sh'
if (-not (Test-Path -LiteralPath $dispatcher)) {
    throw "Missing agmsg dispatcher: $dispatcher"
}

$argsForDispatcher = @(
    '--type', $script:AgentType,
    '--project', (ConvertTo-BashPath (Get-Location).Path)
)
if ($Team) { $argsForDispatcher += @('--team', $Team) }
if ($Agent) { $argsForDispatcher += @('--agent', $Agent) }

$argvFile = [System.IO.Path]::GetTempFileName()
try {
    $commandArgs = @()
    if ($Command) { $commandArgs += $Command }
    if ($Rest) { $commandArgs += $Rest }

    $encodedArgs = foreach ($arg in $commandArgs) {
        [Convert]::ToBase64String($utf8NoBom.GetBytes([string] $arg))
    }
    [System.IO.File]::WriteAllLines($argvFile, [string[]] $encodedArgs, $utf8NoBom)
    $argsForDispatcher += @('--argv-file', (ConvertTo-BashPath $argvFile))

    Invoke-WithPythonUtf8 {
        & $script:Bash $dispatcher @argsForDispatcher
        $code = $LASTEXITCODE
        if ($code -ne 0) { exit $code }
    }
} finally {
    Remove-Item -LiteralPath $argvFile -Force -ErrorAction SilentlyContinue
}
