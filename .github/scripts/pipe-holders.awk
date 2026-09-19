# Report every pipe held by TWO OR MORE PROCESSES, from `lsof -F pcftDin`.
#
# Written for the shards that report every test ok and then sit silent until the
# job's cap. The cause is a process that outlived its caller while still holding
# the pipe bats is waiting to see closed, and the proof is that both appear
# against one pipe. On 08-01 that proof was already in the dump -- spread over
# per-pid blocks, with a line cap that had cut the decisive entry -- and was read
# as innocent. Reading it by eye is the step that failed, so this does it.
#
# Input must be ONE `lsof -F` snapshot covering every candidate: per-pid
# invocations are taken at different moments and cannot be correlated. The -F
# form is used rather than the columnar one because the columns do not mean the
# same thing on both runners, and guessing wrong is not a quiet failure --
#
#   macOS   f9 / tPIPE / n->0x27575cd1a9c13c5      no device, no inode
#   Linux   f1 / tFIFO / D0xe / i647171 / npipe    D is the same for EVERY pipe,
#                                                  n is literally "pipe"
#
# so keying on device or name would fold every Linux pipe into one and report
# the whole runner as shared. The identity is the peer address where there is
# one, and the inode otherwise.
function flush(  id) {
  if (fd == "") return
  if (type == "tPIPE" || type == "tFIFO") {
    id = ""
    if (name ~ /^n->/) id = substr(name, 4)          # macOS: the far end names this one
    else if (inode != "") id = "inode:" substr(inode, 2)   # Linux: the pipe's inode
    if (id != "") {
      entry = sprintf("%s(pid %s, fd %s)", cmd, pid, substr(fd, 2))
      if (index(held[id], entry) == 0) held[id] = held[id] " " entry
      # Distinct PROCESSES, not distinct rows. One process holding the same pipe
      # on two descriptors -- a dup, or a shell that saved a redirection -- is
      # ordinary and must not read as sharing.
      if (!((id, pid) in pidseen)) { pidseen[id, pid] = 1; procs[id]++ }
      if (!(id in known)) order[++n] = id
      known[id] = 1
    }
  }
  fd = ""; type = ""; inode = ""; name = ""
}
/^p/ { flush(); pid = substr($0, 2); next }
/^c/ { cmd = substr($0, 2); next }
/^f/ { flush(); fd = $0; next }
/^t/ { type = $0; next }
/^i/ { inode = $0; next }
/^n/ { name = $0; next }
END {
  flush()
  found = 0
  for (i = 1; i <= n; i++) {
    k = order[i]
    if (procs[k] < 2) continue
    found = 1
    printf "SHARED %s by %d processes:%s\n", k, procs[k], held[k]
  }
  if (!found) print "(no pipe is held by more than one of these processes)"
}
