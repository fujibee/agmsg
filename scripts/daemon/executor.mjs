// The (pid, start-time evidence, boot id) triple that stands in for "this
// process, and not some later process that reused its pid." Shared
// between owner.mjs (which records the triple when it takes ownership) and
// status.mjs (which reads it back to answer "living / confirmed dead /
// cannot tell").
//
// This small, cross-cutting helper is shared by both files, just as
// install-baseline.mjs is shared by the startup verifier and daemon.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { platform, uptime } from "node:os";

// A boot-scoped id: the same value for every process on this machine
// started since the current boot, and a DIFFERENT value after a reboot --
// the property needed to tell "this executor" from "a later process
// that reused the same pid" across a restart. It is the kernel's UUID where
// one exists, and an approximate boot EPOCH TIMESTAMP (seconds) elsewhere;
// either serves the same comparison purpose.
//
// linux: /proc/sys/kernel/random/boot_id, fixed for the boot (btime from
// /proc/stat only when it cannot be read). darwin: `sysctl -n
// kern.bootsessionuuid`, likewise fixed for the boot.
//
// Anything else (win32 included): no simple authoritative file to read
// without shelling out to something heavier (wmic/PowerShell) for every
// check. Approximate instead, from Date.now() minus os.uptime(), rounded to
// the nearest second to absorb the two calls' own timing jitter. This can
// disagree by a handful of seconds between two calls in the SAME boot
// (uptime() does not always advance in lockstep with wall-clock sleep/wake
// accounting) -- callers must tolerate small drift on this path and must
// NOT expect exact equality the way linux/darwin's kernel-reported values
// give.
export function bootId() {
  const plat = platform();
  if (plat === "linux") {
    // The kernel's per-boot random id never changes within a boot. btime does:
    // it is "now minus uptime", so a stepped wall clock (WSL2's host time sync)
    // moves it while the machine stays up.
    try {
      const id = readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim();
      if (id) return id;
    } catch {
      // fall through to btime
    }
    const stat = readFileSync("/proc/stat", "utf8");
    const line = stat.split("\n").find((l) => l.startsWith("btime "));
    if (line) {
      const sec = line.slice("btime ".length).trim();
      if (/^\d+$/.test(sec)) return sec;
    }
    // /proc/stat without a btime line has not been observed; fall through
    // to the approximate path rather than throw, since a boot id that is
    // merely approximate is still useful (see caller contract below).
  } else if (plat === "darwin") {
    // kern.bootsessionuuid is fixed for the whole boot. kern.boottime is
    // not: the kernel shifts it whenever the wall clock is stepped, so a
    // value recorded days ago can differ by seconds from the same boot's
    // current one.
    try {
      const out = execFileSync("sysctl", ["-n", "kern.bootsessionuuid"], {
        encoding: "utf8",
      }).trim();
      if (out) return out;
    } catch {
      // fall through to the approximate path
    }
  }
  return String(Math.round(Date.now() / 1000 - uptime()));
}

// How far two readings of the approximate boot id (win32) may differ and still
// be the same boot: they come from Date.now() minus os.uptime(), which
// wanders by seconds within one boot.
const APPROXIMATE_BOOT_TOLERANCE_SECONDS = 30;

// true / false / null (cannot tell) for "`recorded` is this boot's id".
// `current` is this boot's id as read now (injectable for tests).
export function sameBoot(recorded, plat = platform(), current = bootId()) {
  // Checked before the value comparison: when kern.bootsessionuuid cannot
  // be read, bootId() falls back to a number, which must not make an
  // old-format record look like an exact match.
  if (plat === "darwin" && /^\d+$/.test(String(recorded))) return null;
  // Linux records written before the boot id became the kernel's boot_id hold
  // btime seconds, which a stepped clock moves. Neither side can then say it is
  // the same boot, so a live pid is "cannot tell", not another boot.
  if (plat === "linux" && /^\d+$/.test(String(recorded)) !== /^\d+$/.test(String(current))) return null;
  // The approximate id proves nothing by differing: a gap beyond the tolerance
  // (a sleep, a clock step) is "cannot tell", never "another boot". Only a
  // record in some other form is a plain mismatch.
  if (plat === "win32" && /^\d+$/.test(String(recorded)) && /^\d+$/.test(String(current))) {
    return Math.abs(Number(current) - Number(recorded)) <= APPROXIMATE_BOOT_TOLERANCE_SECONDS ? true : null;
  }
  return current === recorded;
}

// This process's own executor triple, as of the call. `role` and `pid` are
// the caller's own; `bootId` is captured fresh (see above).
export function currentExecutor() {
  return { pid: process.pid, bootId: bootId() };
}

// True/false/null for "living" / "confirmed dead" / "cannot tell", given a
// PREVIOUSLY captured executor triple `{pid, bootId}`.
//
// A bare `kill(pid, 0)` succeeding is NOT enough on its own -- pids recycle,
// and a live process at that number could be a stranger that started after
// the recorded one exited. The bootId compare is what this file exists for:
// if the boot has changed since the triple was captured, no pid from that
// boot can possibly still be running, so the answer is a confident `false`
// (confirmed dead) without even checking the pid -- this is the one case
// where a stale boot id is itself the proof, not a reason to say "cannot
// tell".
export function isAlive({ pid, bootId: capturedBootId }, { plat = platform(), current = bootId() } = {}) {
  const sameBootId = sameBoot(capturedBootId, plat, current);
  if (sameBootId === false) return false;
  try {
    process.kill(pid, 0);
  } catch (error) {
    if (error?.code === "ESRCH") return false;
    // EPERM: a process at that pid exists but this user cannot signal it --
    // that is itself proof it is alive (Node only reports it as a
    // permission fact, but a permission-denied answer to `kill(pid, 0)`
    // never happens for a pid that does not exist). Anything else is a
    // genuine "cannot tell" (e.g. a platform where signal 0 is unsupported).
    if (error?.code !== "EPERM") return null;
  }
  // The pid exists, but an old-format record cannot say it is the same boot.
  return sameBootId === null ? null : true;
}
