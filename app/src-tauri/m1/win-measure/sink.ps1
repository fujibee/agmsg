# Local sink for the WebRTC checks: counts UDP datagrams and TCP connections on 127.0.0.1:<Port> into <Out>
# ("udp=N tcp=M", replaced every 100 ms) until <Out>.stop exists or <Seconds> have passed; the final count is
# published to <Out>.final with the token found in <Out>.stop (see sink.sh).
param([int]$Port = 47931, [int]$Seconds = 600, [string]$Out)
Set-Content -Path "$Out.pid" -Value $PID -Encoding ascii
try {
  $udp = New-Object System.Net.Sockets.UdpClient (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Loopback, $Port))
  $tcp = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $Port)
  $tcp.Start()
} catch {
  Set-Content -Path $Out -Value "ERROR cannot listen on $Port : $($_.Exception.Message)" -Encoding ascii
  exit 1
}
# The reader (the run script) may have the file open at this moment: write a temp file and swap it in,
# try a few times, and never let a failed write stop the sink (the next turn writes again).
function Write-Hits {
  for ($i = 0; $i -lt 5; $i++) {
    try {
      "udp=$u tcp=$t" | Set-Content -Path "$Out.tmp" -Encoding ascii -ErrorAction Stop
      Move-Item -Path "$Out.tmp" -Destination $Out -Force -ErrorAction Stop
      return
    } catch { Start-Sleep -Milliseconds 30 }
  }
}
$u = 0; $t = 0
Write-Hits
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end -and -not (Test-Path "$Out.stop")) {
  if ($udp.Available -gt 0) { $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0); [void]$udp.Receive([ref]$ep); $u++ }
  if ($tcp.Pending()) { $c = $tcp.AcceptTcpClient(); $c.Close(); $t++ }
  Write-Hits
  Start-Sleep -Milliseconds 100
}
# Asked to stop (or out of time): the token in <Out>.stop is this run's. Count what is still waiting, then
# publish "<token> udp=N tcp=M" to <Out>.final and read it back; only that confirms the final count. If it
# cannot be published, exit with a code and leave no final file: the run then reports that, never a stale count.
$tok = ''
for ($i = 0; $i -lt 40 -and -not $tok; $i++) {
  try { $tok = (Get-Content -Path "$Out.stop" -Raw -ErrorAction Stop).Trim() } catch { }
  if (-not $tok) { Start-Sleep -Milliseconds 50 }
}
Start-Sleep -Milliseconds 300
for ($i = 0; $i -lt 20; $i++) {
  $more = $false
  while ($udp.Available -gt 0) { $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0); [void]$udp.Receive([ref]$ep); $u++; $more = $true }
  while ($tcp.Pending()) { $c = $tcp.AcceptTcpClient(); $c.Close(); $t++; $more = $true }
  if (-not $more) { break }
}
$udp.Close(); $tcp.Stop()
if (-not $tok) { exit 3 }
$line = "$tok udp=$u tcp=$t"
for ($i = 0; $i -lt 60; $i++) {
  try {
    $line | Set-Content -Path "$Out.final.tmp" -Encoding ascii -ErrorAction Stop
    Move-Item -Path "$Out.final.tmp" -Destination "$Out.final" -Force -ErrorAction Stop
    if ((Get-Content -Path "$Out.final" -Raw -ErrorAction Stop).Trim() -eq $line) { exit 0 }
  } catch { }
  Start-Sleep -Milliseconds 50
}
exit 2
