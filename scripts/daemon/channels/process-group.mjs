// Conservative evidence for a short-lived command launched in its own group.
// If the platform cannot prove the group is empty or still belongs to the
// recorded leader, callers must treat it as unknown and keep the seat pending.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { platform } from "node:os";
import { bootId } from "../executor.mjs";

export function processStartWitness(pid) {
  if (!Number.isSafeInteger(pid) || pid < 2) return null;
  const os = platform();
  if (os === "linux") {
    try {
      const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
      const rest = stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/);
      const start = rest[19];
      return /^\d+$/.test(start ?? "") ? `linux:${start}` : null;
    } catch {
      return null;
    }
  }
  if (os === "darwin") {
    try {
      const start = execFileSync("ps", ["-p", String(pid), "-o", "lstart="], { encoding: "utf8" }).trim();
      return start ? `darwin:${start}` : null;
    } catch {
      return null;
    }
  }
  if (os === "win32") {
    for (const executable of ["powershell.exe", "pwsh.exe"]) {
      try {
        const start = execFileSync(executable, [
          "-NoProfile", "-NonInteractive", "-Command",
          `(Get-Process -Id ${pid}).StartTime.Ticks`,
        ], { encoding: "utf8", windowsHide: true }).trim();
        if (/^\d+$/.test(start)) return `windows:${start}`;
      } catch {
        // Try the other supported PowerShell executable.
      }
    }
  }
  return null;
}

export function captureProcessGroup(pgid) {
  const witness = processStartWitness(pgid);
  if (!witness) return { state: "unreadable", reason: "child_start_witness_unavailable" };
  return {
    state: "complete",
    kind: platform() === "win32" ? "windows-native-process" : "posix-process-group",
    pgid,
    boot_id: bootId(),
    witness,
  };
}

export function observeProcessGroup(record) {
  if (!record || record.state !== "complete" || !Number.isSafeInteger(record.pgid) || record.pgid < 2 || !record.boot_id || !record.witness) {
    return { state: "unreadable", reason: "child_group_record_unreadable" };
  }
  if (platform() === "win32") {
    if (record.kind !== "windows-native-process") return { state: "unreadable", reason: "child_group_kind_mismatch" };
    try {
      process.kill(record.pgid, 0);
    } catch (error) {
      if (error?.code === "ESRCH") return { state: "absent" };
      if (error?.code !== "EPERM") return { state: "unreadable", reason: "child_process_observation_failed" };
    }
    const currentWitness = processStartWitness(record.pgid);
    if (!currentWitness) return { state: "unreadable", reason: "child_process_witness_unavailable" };
    if (currentWitness !== record.witness) return { state: "unreadable", reason: "child_process_pid_reused" };
    return { state: "present" };
  }
  if (record.kind !== "posix-process-group") return { state: "unreadable", reason: "child_group_kind_mismatch" };
  if (bootId() !== record.boot_id) return { state: "absent" };
  try {
    process.kill(-record.pgid, 0);
  } catch (error) {
    if (error?.code === "ESRCH") return { state: "absent" };
    if (error?.code !== "EPERM") return { state: "unreadable", reason: "child_group_observation_failed" };
  }
  const currentWitness = processStartWitness(record.pgid);
  if (!currentWitness) return { state: "unreadable", reason: "child_group_leader_unreadable" };
  if (currentWitness !== record.witness) return { state: "unreadable", reason: "child_group_leader_reused" };
  return { state: "present" };
}
