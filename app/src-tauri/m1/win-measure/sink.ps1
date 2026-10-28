# Local sink for the WebRTC checks: counts UDP datagrams and TCP connections on 127.0.0.1:<Port> into <Out>
# ("udp=N tcp=M", rewritten every 100 ms) until <Out>.stop exists or <Seconds> have passed.
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
Write-Hits; Write-Hits   # the final count must land even if the reader had the file just now
$udp.Close(); $tcp.Stop()
