// Conservative evidence for a short-lived command launched in its own group.
// If the platform cannot prove the group is empty or still belongs to the
// recorded leader, callers must treat it as unknown and keep the seat pending.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { platform } from "node:os";
import { bootId, sameBoot } from "../executor.mjs";

export function processStartWitness(pid, onFailure = () => {}) {
  if (!Number.isSafeInteger(pid) || pid < 2) return null;
  const os = platform();
  if (os === "linux") {
    try {
      const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
      const rest = stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/);
      const start = rest[19];
      return /^\d+$/.test(start ?? "") ? `linux:${start}` : null;
    } catch (error) {
      onFailure(`proc stat failed: ${error?.code ?? error?.message}`);
      return null;
    }
  }
  if (os === "darwin") {
    try {
      const start = execFileSync("ps", ["-p", String(pid), "-o", "lstart="], { encoding: "utf8" }).trim();
      if (!start) onFailure("ps printed no start time");
      return start ? `darwin:${start}` : null;
    } catch (error) {
      const stderr = String(error?.stderr ?? "").trim().replace(/\s+/g, " ").slice(0, 200);
      onFailure(`ps failed: code=${error?.code ?? ""} status=${error?.status ?? ""} signal=${error?.signal ?? ""} stderr=${stderr}`);
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

export function captureProcessGroup(pgid, onFailure = () => {}) {
  const witness = processStartWitness(pgid, onFailure);
  // The group id is kept even without a witness: a later observation can still
  // prove the group is gone (no such group), though never that it is present.
  if (!witness) return { state: "unreadable", reason: "child_start_witness_unavailable", pgid };
  return {
    state: "complete",
    kind: platform() === "win32" ? "windows-native-process" : "posix-process-group",
    pgid,
    boot_id: bootId(),
    witness,
  };
}

export function observeProcessGroup(record) {
  if (record?.state === "unreadable" && record.reason === "child_start_witness_unavailable"
      && platform() !== "win32" && Number.isSafeInteger(record.pgid) && record.pgid >= 2) {
    try {
      process.kill(-record.pgid, 0);
    } catch (error) {
      if (error?.code === "ESRCH") return { state: "absent" };
    }
    return { state: "unreadable", reason: "child_start_witness_unavailable" };
  }
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
  const sameBootId = sameBoot(record.boot_id);
  if (sameBootId === null) return { state: "unreadable", reason: "child_boot_id_unreadable" };
  if (!sameBootId) return { state: "absent" };
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
