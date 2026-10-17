// Windows native queue compatibility has been measured at the minimum
// supported release and at 0.160.0; later stable releases use the same policy.
import { execFileSync } from "node:child_process";
import { statSync } from "node:fs";
import { basename, isAbsolute, join, resolve } from "node:path";

// 0.157.0: native-child measurement 2026-09-28, live rollout 2026-10-01.
// 0.160.0: native-child observations and live rollout 2026-10-05.
const MINIMUM_WINDOWS_QUEUE_VERSION = [0, 157, 0];

export function resolveWindowsCodexExe(executable, env = process.env, arch = process.arch) {
  if (typeof executable !== "string" || !executable) return null;
  const pathEntry = Object.entries(env).find(([key]) => key.toLowerCase() === "path")?.[1] ?? "";
  const candidates = [];
  if (isAbsolute(executable)) {
    candidates.push(executable);
  } else if (executable === "codex" || executable.toLowerCase() === "codex.exe") {
    for (const dir of pathEntry.split(";").filter(Boolean)) {
      candidates.push(join(dir, "codex.exe"));
      const target = { x64: "x86_64-pc-windows-msvc", arm64: "aarch64-pc-windows-msvc" }[arch];
      if (target) {
        // npm's PATH entry is a JS/shell shim. Resolve its native package
        // directly; never queue through that shim and its extra processes.
        const packageDir = join(dir, "node_modules", "@openai", "codex", "node_modules", "@openai", `codex-win32-${arch}`);
        candidates.push(join(packageDir, "vendor", target, "bin", "codex.exe"));
      }
    }
  }
  for (const candidate of candidates) {
    if (basename(candidate).toLowerCase() !== "codex.exe") continue;
    try {
      if (statSync(candidate).isFile()) return resolve(candidate);
    } catch { /* A missing candidate is not a resolved native executable. */ }
  }
  return null;
}

export function checkWindowsCodexQueueGate({ executable, env = process.env, resolveExe = resolveWindowsCodexExe, probe = execFileSync }) {
  const nativeExe = resolveExe(executable, env);
  if (!nativeExe) return { state: "blocked", reason: "windows_codex_executable_unresolved" };
  let output;
  try {
    output = probe(nativeExe, ["--version"], {
      env, encoding: "utf8", windowsHide: true, timeout: 2000, maxBuffer: 16 * 1024,
      stdio: ["ignore", "pipe", "pipe"],
    });
  } catch {
    return { state: "blocked", reason: "windows_codex_version_unreadable" };
  }
  const version = /^codex-cli (\d+\.\d+\.\d+)\s*$/.exec(output)?.[1];
  if (!version) return { state: "blocked", reason: "windows_codex_version_unreadable" };
  const parts = version.split(".").map(BigInt);
  const minimum = MINIMUM_WINDOWS_QUEUE_VERSION.map(BigInt);
  const firstDifference = parts.findIndex((part, index) => part !== minimum[index]);
  if (firstDifference !== -1 && parts[firstDifference] < minimum[firstDifference]) {
    return { state: "blocked", reason: `windows_codex_version_below_minimum:${version}` };
  }
  return { state: "ok", executable: nativeExe, version };
}
