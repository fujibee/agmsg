[CmdletBinding()]
param(
    [switch] $Once,
    [ValidateRange(1, 3600)] [int] $PollSeconds = 1
)

$ErrorActionPreference = 'Stop'
$SkillDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$RunDir = Join-Path $SkillDir 'run'
$PidFile = Join-Path $RunDir 'hook-dispatcher.pid'
$LogFile = Join-Path $RunDir 'hook-dispatcher.log'
$ProjectList = Join-Path $RunDir 'hook-projects.list'

function Write-DispatcherLog {
    param([string] $Message)
    try {
        if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 1MB) {
            [IO.File]::WriteAllText($LogFile, '')
        }
        Add-Content -LiteralPath $LogFile -Value ('{0:o} {1}' -f [DateTime]::UtcNow, $Message) -Encoding UTF8
    } catch {
        # Logging must not terminate the dispatcher.
    }
}

function Test-ProcessAlive {
    param([string] $ProcessId)
    if ($ProcessId -notmatch '^\d+$') { return $false }
    return $null -ne (Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue)
}

function ConvertTo-MsysPath {
    param([string] $Path)
    if ($Path -match '^([A-Za-z]):[\\/](.*)$') {
        return '/' + $Matches[1].ToLowerInvariant() + '/' + ($Matches[2] -replace '\\', '/')
    }
    if ($Path -match '^\\\\') {
        return '/' + ($Path.TrimStart('\') -replace '\\', '/')
    }
    return ($Path -replace '\\', '/')
}

function Quote-BashArgument {
    param([string] $Value)
    $singleQuote = [string][char]39
    $replacement = [string][char]39 + [char]34 + [char]39 + [char]34 + [char]39
    return $singleQuote + $Value.Replace($singleQuote, $replacement) + $singleQuote
}

function Get-QueueDirectories {
    $seen = @{}
    $dirs = @((Join-Path $RunDir 'hook-queue'))
    if (Test-Path -LiteralPath $ProjectList) {
        foreach ($project in [IO.File]::ReadAllLines($ProjectList)) {
            if (-not [string]::IsNullOrWhiteSpace($project)) {
                $dirs += Join-Path $project.Trim() '.agmsg\hook-queue'
            }
        }
    }
    foreach ($dir in $dirs) {
        $key = $dir.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $dir
        }
    }
}

function Invoke-HookRequest {
    param([IO.FileInfo] $Request, [string] $Bash)
    try {
        $raw = [IO.File]::ReadAllText($Request.FullName)
        $newline = $raw.IndexOf("`n")
        if ($newline -lt 0) { throw 'Request has no header terminator.' }
        $header = $raw.Substring(0, $newline).TrimEnd("`r")
        $stdin = $raw.Substring($newline + 1)
        $fields = $header.Split("`t")
        if ($fields.Count -lt 4) { throw 'Request header is malformed.' }
        $event, $type, $project = $fields[0], $fields[1], $fields[2]
        switch ($event) {
            'session-start' { $script = 'session-start.sh' }
            'session-end' { $script = 'session-end.sh' }
            default { throw "Unsupported event: $event" }
        }

        if (-not $Bash -or -not (Test-Path -LiteralPath $Bash)) {
            throw "Git Bash not found: $Bash"
        }
        $scriptPath = (ConvertTo-MsysPath $SkillDir) + '/scripts/' + $script
        $command = (Quote-BashArgument $scriptPath) + ' ' +
            (Quote-BashArgument $type) + ' ' + (Quote-BashArgument $project)
        Write-DispatcherLog ("request={0} event={1} type={2} script={3} status=run" -f $Request.Name, $event, $type, $script)
        $output = @($stdin | & $Bash -lc $command 2>&1)
        $exitCode = $LASTEXITCODE
        foreach ($line in $output) {
            Write-DispatcherLog ("request={0} output={1}" -f $Request.Name, [string]$line)
        }
        if ($exitCode -ne 0) { throw "hook exited $exitCode" }
        Write-DispatcherLog ("request={0} event={1} type={2} status=ok" -f $Request.Name, $event, $type)
    } catch {
        Write-DispatcherLog ("request={0} status=failed error={1}" -f $Request.Name, $_.Exception.Message)
    } finally {
        Remove-Item -LiteralPath $Request.FullName -Force -ErrorAction SilentlyContinue
    }
}

New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
if (Test-Path -LiteralPath $PidFile) {
    $existingPid = (Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if (Test-ProcessAlive $existingPid) { exit 0 }
}
[IO.File]::WriteAllText($PidFile, [string]$PID)

try {
    $bash = $env:GIT_BASH
    if (-not $bash) { $bash = $env:AGMSG_BASH }
    if (-not $bash) { $bash = 'C:\Program Files\Git\bin\bash.exe' }
    Write-DispatcherLog ("dispatcher start pid={0}" -f $PID)

    do {
        foreach ($queueDir in Get-QueueDirectories) {
            if (-not (Test-Path -LiteralPath $queueDir)) { continue }
            foreach ($request in Get-ChildItem -LiteralPath $queueDir -Filter '*.req' -File | Sort-Object Name) {
                Invoke-HookRequest $request $bash
            }
        }
        if (-not $Once) { Start-Sleep -Seconds $PollSeconds }
    } while (-not $Once)
} finally {
    if (Test-Path -LiteralPath $PidFile) {
        $recordedPid = (Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($recordedPid -eq [string]$PID) {
            Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        }
    }
    Write-DispatcherLog ("dispatcher stop pid={0}" -f $PID)
}
