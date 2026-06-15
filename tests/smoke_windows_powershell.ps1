param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

function Assert-Contains {
    param(
        [string] $Text,
        [string] $Needle,
        [string] $Label
    )
    if (-not $Text.Contains($Needle)) {
        throw "$Label did not contain expected text: $Needle`nActual:`n$Text"
    }
}

function Assert-NotContains {
    param(
        [string] $Text,
        [string] $Needle,
        [string] $Label
    )
    if ($Text.Contains($Needle)) {
        throw "$Label contained unexpected text: $Needle`nActual:`n$Text"
    }
}

function Invoke-Checked {
    param(
        [scriptblock] $Block,
        [string] $Label
    )
    $output = & $Block 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "$Label exited $LASTEXITCODE`n$output"
    }
    return $output
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("agmsg-win-ps-" + [Guid]::NewGuid().ToString('N'))
$skillDir = Join-Path $testRoot '.agents/skills/agmsg'
$scriptsDir = Join-Path $skillDir 'scripts'
$storageDir = Join-Path $testRoot 'storage'
$projectSingle = Join-Path $testRoot 'project-single'
$projectBob = Join-Path $testRoot 'project-bob'
$projectMulti = Join-Path $testRoot 'project-multi'

try {
    New-Item -ItemType Directory -Force -Path $scriptsDir, (Join-Path $skillDir 'db'), (Join-Path $skillDir 'teams'), $storageDir, $projectSingle, $projectBob, $projectMulti | Out-Null
    Copy-Item -Recurse -Force -Path (Join-Path $RepoRoot 'scripts/*') -Destination $scriptsDir

    $wrapper = Join-Path $scriptsDir 'windows/agmsg.ps1'
    if (-not (Test-Path $wrapper)) {
        throw "missing wrapper: $wrapper"
    }

    $env:AGMSG_STORAGE_PATH = $storageDir
    $env:PYTHONIOENCODING = ''
    $env:AGMSG_TEAM = ''
    $env:AGMSG_AGENT = ''

    $bash = 'C:\Program Files\Git\bin\bash.exe'
    if (-not (Test-Path $bash)) {
        $bashCmd = Get-Command bash.exe -ErrorAction Stop
        $bash = $bashCmd.Source
    }
    $projectSingleBash = (& $bash -lc 'cygpath -u "$1"' agmsg-path $projectSingle | Out-String).Trim()
    $projectBobBash = (& $bash -lc 'cygpath -u "$1"' agmsg-path $projectBob | Out-String).Trim()
    $projectMultiBash = (& $bash -lc 'cygpath -u "$1"' agmsg-path $projectMulti | Out-String).Trim()

    & $bash (Join-Path $scriptsDir 'init-db.sh') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "init-db failed: $LASTEXITCODE" }
    & $bash (Join-Path $scriptsDir 'join.sh') demo alice codex $projectSingleBash | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "join alice failed: $LASTEXITCODE" }
    & $bash (Join-Path $scriptsDir 'join.sh') demo bob codex $projectBobBash | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "join bob failed: $LASTEXITCODE" }

    $out = Invoke-Checked { & $wrapper -Team demo -Agent bob inbox } '-Team/-Agent inbox'
    Assert-Contains $out 'No new messages.' '-Team/-Agent inbox'

    $env:AGMSG_TEAM = 'demo'
    $env:AGMSG_AGENT = 'bob'
    $out = Invoke-Checked { & $wrapper inbox } 'env inbox'
    Assert-Contains $out 'No new messages.' 'env inbox'
    $env:AGMSG_TEAM = ''
    $env:AGMSG_AGENT = ''

    Push-Location $projectSingle
    try {
        $out = Invoke-Checked { & $wrapper inbox } 'whoami inbox'
        Assert-Contains $out 'No new messages.' 'whoami inbox'
    } finally {
        Pop-Location
    }

    $message = ([string]::Concat([char]0x78BA, [char]0x8A8D, [char]0x3057, [char]0x307E, [char]0x3057, [char]0x305F)) + ' "quoted" emoji ' + [char]::ConvertFromUtf32(0x1F680)
    Invoke-Checked { & $wrapper -Team demo -Agent alice send bob $message } 'send japanese' | Out-Null
    $out = Invoke-Checked { & $wrapper -Team demo history } 'history japanese'
    Assert-Contains $out $message 'history japanese'

    $out = Invoke-Checked { & $wrapper -Team demo team } 'team explicit'
    Assert-Contains $out 'Team: demo' 'team explicit'

    Push-Location $projectSingle
    try {
        $out = Invoke-Checked { & $wrapper mode off } 'mode off'
        Assert-Contains $out "Delivery mode set to 'off'" 'mode off'
        $out = Invoke-Checked { & $wrapper mode turn } 'mode turn'
        Assert-Contains $out "Delivery mode set to 'turn'" 'mode turn'
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("Set-Location -LiteralPath '$projectSingle'; & '$wrapper' mode monitor"))
        $stdoutFile = Join-Path $testRoot 'mode-stdout.txt'
        $stderrFile = Join-Path $testRoot 'mode-stderr.txt'
        $proc = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $modeOutput = ((Get-Content -Raw -LiteralPath $stdoutFile -ErrorAction SilentlyContinue) + (Get-Content -Raw -LiteralPath $stderrFile -ErrorAction SilentlyContinue))
        if ($proc.ExitCode -eq 0) { throw "mode monitor unexpectedly succeeded`n$modeOutput" }
        Assert-Contains $modeOutput 'Codex has no Monitor tool' 'mode monitor'
    } finally {
        Pop-Location
    }

    $out = Invoke-Checked { & $wrapper join smoke charlie } 'join command'
    Assert-Contains $out 'Joined team smoke as charlie' 'join command'

    & $bash (Join-Path $scriptsDir 'join.sh') many first codex $projectMultiBash | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "join first failed: $LASTEXITCODE" }
    & $bash (Join-Path $scriptsDir 'join.sh') many second codex $projectMultiBash | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "join second failed: $LASTEXITCODE" }
    Push-Location $projectMulti
    try {
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("Set-Location -LiteralPath '$projectMulti'; & '$wrapper' inbox"))
        $stdoutFile = Join-Path $testRoot 'multi-stdout.txt'
        $stderrFile = Join-Path $testRoot 'multi-stderr.txt'
        $proc = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $multiOutput = ((Get-Content -Raw -LiteralPath $stdoutFile -ErrorAction SilentlyContinue) + (Get-Content -Raw -LiteralPath $stderrFile -ErrorAction SilentlyContinue))
        if ($proc.ExitCode -eq 0) { throw "multiple identity command unexpectedly succeeded`n$multiOutput" }
        Assert-Contains $multiOutput 'multiple=true' 'multiple identity'
        Assert-Contains $multiOutput 'agmsg -Team <team> -Agent <agent> inbox' 'multiple identity guidance'
    } finally {
        Pop-Location
    }

    $wrapperText = Get-Content -Raw -LiteralPath $wrapper
    Assert-NotContains $wrapperText "AGMSG_TEAM = 'emeria'" 'wrapper source'
    Assert-NotContains $wrapperText "AGMSG_AGENT = 'codex'" 'wrapper source'
    Assert-NotContains $wrapperText 'sqlite3-shim' 'wrapper source'
    Assert-NotContains $wrapperText 'agmsg-run.sh' 'wrapper source'

    Write-Output 'windows powershell smoke ok'
} finally {
    Remove-Item Env:AGMSG_STORAGE_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:AGMSG_TEAM -ErrorAction SilentlyContinue
    Remove-Item Env:AGMSG_AGENT -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -LiteralPath $testRoot -ErrorAction SilentlyContinue
}
