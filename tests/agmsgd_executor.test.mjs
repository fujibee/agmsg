import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { bootId, currentExecutor, isAlive, sameBoot } from "../scripts/daemon/executor.mjs";

test("bootId is stable across calls and isAlive tells living/dead/wrong-boot apart", () => {
  assert.equal(bootId(), bootId(), "bootId must not change within the same boot");

  const self = currentExecutor();
  assert.equal(isAlive(self), true, "this process's own pid must read as alive");

  // A pid that has already exited, at the CURRENT boot id: must read as
  // confirmed dead (ESRCH), not "cannot tell".
  const dead = spawnSync(process.execPath, ["-e", "process.exit(0)"]);
  assert.equal(dead.status, 0);
  assert.equal(
    isAlive({ pid: dead.pid, bootId: self.bootId }),
    false,
    "an exited pid at the current boot id must read as confirmed dead",
  );

  // A boot id that does not match the current one must short-circuit to
  // confirmed dead even for this process's own (very much alive) pid --
  // no pid from a different boot can still be running.
  assert.equal(
    isAlive({ pid: self.pid, bootId: "another-boot" }),
    false,
    "a mismatched boot id must read as confirmed dead regardless of the pid",
  );

  if (process.platform === "darwin") {
    // A record from when the boot id was kern.boottime seconds cannot be
    // matched against this boot (the kernel shifts that value with clock
    // adjustments): cannot tell while its pid exists, dead once it is gone.
    const boottime = spawnSync("sysctl", ["-n", "kern.boottime"], { encoding: "utf8" }).stdout;
    const legacy = String(Number(boottime.match(/sec\s*=\s*(\d+)/)[1]) - 3);
    assert.equal(isAlive({ pid: self.pid, bootId: legacy }), null);
    assert.equal(isAlive({ pid: dead.pid, bootId: legacy }), false);

    // Even when kern.bootsessionuuid cannot be read and bootId() falls back
    // to a number, an old-format record that equals it is still "cannot tell".
    const shimDir = mkdtempSync(join(tmpdir(), "sysctl-shim-"));
    writeFileSync(
      join(shimDir, "sysctl"),
      '#!/bin/sh\n[ "$2" = kern.bootsessionuuid ] && exit 1\nexec /usr/sbin/sysctl "$@"\n',
    );
    chmodSync(join(shimDir, "sysctl"), 0o755);
    const savedPath = process.env.PATH;
    process.env.PATH = `${shimDir}:${savedPath}`;
    try {
      assert.equal(isAlive({ pid: self.pid, bootId: bootId() }), null);
    } finally {
      process.env.PATH = savedPath;
    }
  }
});

// The Windows boot id is Date.now() minus os.uptime(): two readings in one boot
// differ by a second or so, and a sleep can move them further. A live process
// must not be called dead for that.
test("the approximate (win32) boot id tolerates drift and never proves death by differing", () => {
  const self = currentExecutor();
  assert.equal(sameBoot("99900", "win32", "99900"), true);
  assert.equal(sameBoot("99900", "win32", "99899"), true, "a second of drift is the same boot");
  assert.equal(isAlive({ pid: self.pid, bootId: "99900" }, { plat: "win32", current: "99899" }), true, "a live pid across drift is alive");
  assert.equal(sameBoot("99900", "win32", "99000"), null, "a large gap cannot tell");
  assert.equal(isAlive({ pid: self.pid, bootId: "99900" }, { plat: "win32", current: "99000" }), null, "a live pid across a large gap cannot tell");
  const dead = spawnSync(process.execPath, ["-e", "process.exit(0)"]);
  assert.equal(isAlive({ pid: dead.pid, bootId: "99900" }, { plat: "win32", current: "99000" }), false, "a pid that is gone is dead");
  assert.equal(sameBoot("another-boot", "win32", "99900"), false, "a record in another form is a plain mismatch");
});

test("linux: the boot id is the kernel boot_id, and a btime record is not read as another boot", () => {
  const uuid = "6f1c3a52-0e8b-4d7a-9a41-2b7c5d8e9f10";
  const other = "0b7e9d34-5c21-4a6f-8d13-7e4a2c9b1f58";
  assert.equal(sameBoot(uuid, "linux", uuid), true);
  assert.equal(sameBoot(uuid, "linux", other), false, "two different boot ids are another boot");
  // A record written when the id was btime seconds, which a stepped clock moves.
  assert.equal(sameBoot("1792989040", "linux", uuid), null);
  assert.equal(sameBoot(uuid, "linux", "1793025813"), null, "the id could not be read now: cannot tell");
  assert.equal(sameBoot("1792989040", "linux", "1793025813"), false, "two btime values keep the plain comparison");
  const self = currentExecutor();
  assert.equal(isAlive({ pid: self.pid, bootId: "1792989040" }, { plat: "linux", current: uuid }), null);
  if (process.platform === "linux" && existsSync("/proc/sys/kernel/random/boot_id")) {
    assert.equal(bootId(), readFileSync("/proc/sys/kernel/random/boot_id", "utf8").trim());
  }
});
