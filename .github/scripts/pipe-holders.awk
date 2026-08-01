# Group descriptors by the pipe they name, so a pipe held by two processes is
# one line rather than a coincidence a reader has to notice.
#
# Written for the shards that report every test ok and then sit silent until the
# job's cap. The cause is a process that outlived its caller while holding the
# pipe bats is waiting to see closed, and the proof is that both of them appear
# against the same pipe. On 08-01 that proof was already in the dump -- split
# across per-pid blocks, with a line cap that had cut the decisive entry -- and
# was read as innocent. Reading it by eye is the part that failed, so this does
# it instead.
#
# Input: lsof output covering ALL candidate processes in ONE snapshot. Per-pid
# invocations cannot be matched this way: the two ends land in different blocks
# taken at different moments.
$5 == "PIPE" || $5 == "FIFO" {
  # macOS names the pipe in DEVICE (0x...); Linux carries it in the last field.
  id = ($6 ~ /^0x/) ? $6 : $NF
  peer = ($NF ~ /^->/) ? substr($NF, 3) : ""
  if (!(id in seen)) order[++n] = id
  entry = sprintf("%s(pid %s, fd %s)", $1, $2, $4)
  if (index(seen[id], entry) == 0) { seen[id] = seen[id] " " entry; holders[id]++ }
  if (peer != "") peers[id] = peer
}
END {
  found = 0
  for (i = 1; i <= n; i++) {
    k = order[i]
    if (holders[k] < 2) continue
    found = 1
    printf "SHARED %s -> %s :%s\n", k, (k in peers ? peers[k] : "?"), seen[k]
  }
  if (!found) print "(no pipe is held by more than one of these processes)"
}
