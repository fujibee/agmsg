# Local sink for the WebRTC checks: counts UDP datagrams and TCP connections on 127.0.0.1:<Port> into <Out>
# ("udp=N tcp=M", rewritten every 100 ms) until <Out>.stop exists or <Seconds> have passed.
param([int]$Port = 47931, [int]$Seconds = 600, [string]$Out)
$udp = New-Object System.Net.Sockets.UdpClient (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Loopback, $Port))
$tcp = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $Port)
$tcp.Start()
$u = 0; $t = 0
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end -and -not (Test-Path "$Out.stop")) {
  if ($udp.Available -gt 0) { $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0); [void]$udp.Receive([ref]$ep); $u++ }
  if ($tcp.Pending()) { $c = $tcp.AcceptTcpClient(); $c.Close(); $t++ }
  "udp=$u tcp=$t" | Set-Content -Path $Out
  Start-Sleep -Milliseconds 100
}
$udp.Close(); $tcp.Stop()
