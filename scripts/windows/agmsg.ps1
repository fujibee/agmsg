# PowerShell shortcut for agmsg on native Windows.
#
# Dot-source this file from your PowerShell profile:
#   . "$HOME\.agents\__SKILL_NAME__.ps1"
#
# The function passes user text through environment variables before handing
# off to Git Bash, so spaces, quotes, and non-ASCII message bodies survive the
# PowerShell -> bash boundary.
function __SKILL_NAME__ {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)] [object[]] $rest)

    $bash = $env:AGMSG_BASH
    if (-not $bash) {
        $candidates = @(
            "$env:ProgramFiles\Git\bin\bash.exe",
            "${env:ProgramFiles(x86)}\Git\bin\bash.exe"
        ) | Where-Object { $_ -and (Test-Path $_) }

        if ($candidates.Count -gt 0) {
            $bash = $candidates[0]
        } else {
            $cmd = Get-Command bash.exe -All -ErrorAction SilentlyContinue |
                Where-Object { ($_.Source -like '*\Git\*') -or ($_.Path -like '*\Git\*') } |
                Select-Object -First 1
            if ($cmd) { $bash = if ($cmd.Source) { $cmd.Source } else { $cmd.Path } }
        }
    }

    if (-not $bash -or -not (Test-Path $bash)) {
        Write-Error "Git Bash not found. Install Git for Windows or set AGMSG_BASH to bash.exe."
        return
    }

    $saved = @{}
    foreach ($name in @('AGMSG_SUB', 'AGMSG_TO', 'AGMSG_MSG', 'AGMSG_MODE')) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        $sub = if ($rest -and $rest.Count -ge 1) { [string]$rest[0] } else { 'inbox' }
        $env:AGMSG_SUB = $sub

        if ($sub -eq 'send') {
            if (-not $rest -or $rest.Count -lt 3) {
                Write-Host 'usage: __SKILL_NAME__ send <to> <message>'
                return
            }
            $env:AGMSG_TO = [string]$rest[1]
            $env:AGMSG_MSG = ($rest[2..($rest.Count - 1)] -join ' ')
        }

        if ($sub -eq 'mode') {
            if ($rest.Count -gt 2) {
                Write-Host 'usage: __SKILL_NAME__ mode [turn|off]'
                return
            }
            if ($rest.Count -eq 2) { $env:AGMSG_MODE = [string]$rest[1] }
        }

        & $bash -lc '"$HOME/.agents/__SKILL_NAME__-run.sh"'
    } finally {
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            } else {
                [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
            }
        }
    }
}
