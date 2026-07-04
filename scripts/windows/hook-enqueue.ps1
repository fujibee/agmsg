[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Event,
    [Parameter(Position = 1)] [string] $Type,
    [Parameter(Position = 2)] [string] $Project
)

# Hook delivery must never make a Codex session fail. Keep every operation,
# including the initial writable-directory probe, inside best-effort guards.
try {
    $stdin = [Console]::In.ReadToEnd()
    $epochMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $name = '{0}-{1}-{2}.req' -f $epochMs, $PID, ([Guid]::NewGuid().ToString('N').Substring(0, 12))
    $header = "{0}`t{1}`t{2}`t{3}" -f $Event, $Type, $Project, $epochMs
    $content = $header + "`n" + $stdin
    $encoding = New-Object System.Text.UTF8Encoding($false)

    $candidates = @()
    $candidates += [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\run\hook-queue'))
    if ($Project) {
        $candidates += Join-Path $Project '.agmsg\hook-queue'
    }

    $queued = $false
    foreach ($queueDir in $candidates) {
        $tmp = $null
        try {
            New-Item -ItemType Directory -Force -Path $queueDir -ErrorAction Stop | Out-Null
            $tmp = Join-Path $queueDir ($name + '.tmp')
            $dest = Join-Path $queueDir $name
            [IO.File]::WriteAllText($tmp, $content, $encoding)
            [IO.File]::Move($tmp, $dest)
            $queued = $true
            break
        } catch {
            if ($tmp -and (Test-Path -LiteralPath $tmp)) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $queued) {
        throw 'No writable agmsg hook queue directory was found.'
    }
} catch {
    try {
        $errPath = Join-Path $env:TEMP 'agmsg-hook-enqueue.err'
        $line = '{0:o} event={1} type={2} error={3}' -f [DateTime]::UtcNow, $Event, $Type, $_.Exception.Message
        Add-Content -LiteralPath $errPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {
        # Deliberately ignored: enqueue is fail-open for Codex sessions.
    }
}

exit 0
