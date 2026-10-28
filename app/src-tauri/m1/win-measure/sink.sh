#!/bin/bash
# The run's side of the sink protocol. Sourced by run-win.sh and by selftest-sink.sh.
# The sink keeps a live counter file (SINK) for the control check, but the FINAL count is trusted only
# from SINK.final, which the sink writes after it was asked to stop by a token this run chose:
#   "<token> udp=N tcp=M"
# A missing final file, another token, a sink that died or was killed: no verdict can pass on it.
# The caller defines `verdict`, SINK (counter file path) and SINK_TOKEN.

# the live counter: it is replaced by the writer, so a read can hit the instant of the swap; try again
sink_val() { local v i; for i in 1 2 3 4 5; do v=$(cat "$SINK" 2>/dev/null | tr -d '\r' | head -1); [ -n "$v" ] && break; sleep 0.2; done; echo "$v"; }

# "udp=N tcp=M" from the final file when it carries this run's token, else nothing
sink_final_counts() { cat "$SINK.final" 2>/dev/null | tr -d '\r' | sed -n "s/^$SINK_TOKEN \\(udp=[0-9]* tcp=[0-9]*\\)\$/\\1/p" | head -1; }

# ask the sink to stop with the token and wait for its final count (up to SINK_FINAL_POLLS x 0.2 s, default 10 s)
stop_sink() { # only the PowerShell this run started, by its own id, and only while that id is still a PowerShell
  [ -n "${SINK:-}" ] || return 0
  [ "${SINK_STOPPED:-0}" = 0 ] || return 0
  SINK_STOPPED=1
  echo "$SINK_TOKEN" > "$SINK.stop"
  local i; for i in $(seq 1 "${SINK_FINAL_POLLS:-50}"); do [ -n "$(sink_final_counts)" ] && break; sleep 0.2; done
  if [ -f "$SINK.pid" ]; then
    sleep 1
    local p; p=$(tr -d '\r\n ' < "$SINK.pid")
    if [ -n "$p" ] && tasklist //FI "PID eq $p" //FO CSV //NH 2>/dev/null | grep -qi '"powershell.exe"'; then taskkill //F //PID "$p" > /dev/null 2>&1; fi
  fi
}

# the verdict on what reached the sink: only the confirmed final count counts, and it must equal the control alone
sink_verdict() {
  local c; c=$(sink_final_counts)
  if [ -z "$c" ]; then verdict FAIL S3-sink-hits "the sink did not confirm its final count (no final file for this run's token); last live value: ${1:-$(sink_val)}"
  elif [ "$c" = "udp=1 tcp=1" ]; then verdict PASS S3-sink-hits "no UDP datagram or TCP connection reached the sink beyond the control ($c, confirmed by the sink)"
  else verdict FAIL S3-sink-hits "sink counts: $c (control alone is udp=1 tcp=1)"; fi
}
