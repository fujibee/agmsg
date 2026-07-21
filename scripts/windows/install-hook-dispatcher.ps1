[CmdletBinding()]
param(
    [switch] $Register,
    [switch] $Unregister,
    [switch] $Status
)

$ErrorActionPreference = 'Stop'
$TaskName = 'agmsg-hook-dispatcher'
$SkillDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$Dispatcher = Join-Path $PSScriptRoot 'hook-dispatcher.ps1'
$PidFile = Join-Path $SkillDir 'run\hook-dispatcher.pid'

function Get-PowerShellExecutable {
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        $command = Get-Command powershell.exe -ErrorAction Stop | Select-Object -First 1
    }
    return $command.Source
}

function Get-DispatcherPid {
    if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
    $value = (Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($value -notmatch '^\d+$') { return $null }
    return [int]$value
}

function Test-DispatcherAlive {
    $dispatcherPid = Get-DispatcherPid
    if ($null -eq $dispatcherPid) { return $false }
    return $null -ne (Get-Process -Id $dispatcherPid -ErrorAction SilentlyContinue)
}

function Invoke-ScheduledTaskCommand {
    param([string[]] $Arguments, [switch] $Quiet)
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $output = @(& schtasks.exe @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    if (-not $Quiet) {
        foreach ($line in $output) { Write-Host ([string]$line) }
    }
    return $exitCode
}

$selected = 0
foreach ($choice in @($Register, $Unregister, $Status)) {
    if ($choice) { $selected++ }
}
if ($selected -ne 1) {
    throw 'Specify exactly one of -Register, -Unregister, or -Status.'
}

if ($Register) {
    $powershell = Get-PowerShellExecutable
    $taskCommand = '"{0}" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $powershell, $Dispatcher
    $taskExit = Invoke-ScheduledTaskCommand @('/Create', '/TN', $TaskName, '/SC', 'ONLOGON', '/TR', $taskCommand, '/F')
    if ($taskExit -ne 0) { throw "schtasks /Create failed with exit code $taskExit" }
    Start-Process -FilePath $powershell -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $Dispatcher) -WindowStyle Hidden
    Write-Output "Registered and started $TaskName."
    exit 0
}

if ($Unregister) {
    $dispatcherPid = Get-DispatcherPid
    if ($null -ne $dispatcherPid -and (Test-DispatcherAlive)) {
        Stop-Process -Id $dispatcherPid -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    [void](Invoke-ScheduledTaskCommand @('/Delete', '/TN', $TaskName, '/F') -Quiet)
    Write-Output "Unregistered and stopped $TaskName."
    exit 0
}

$taskExit = Invoke-ScheduledTaskCommand @('/Query', '/TN', $TaskName) -Quiet
$taskRegistered = ($taskExit -eq 0)
$dispatcherAlive = Test-DispatcherAlive
Write-Output ('Task registered: {0}' -f $(if ($taskRegistered) { 'yes' } else { 'no' }))
Write-Output ('Dispatcher alive: {0}' -f $(if ($dispatcherAlive) { 'yes' } else { 'no' }))
if ($dispatcherAlive) { Write-Output ('Dispatcher pid: {0}' -f (Get-DispatcherPid)) }
