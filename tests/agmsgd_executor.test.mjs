import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { bootId, currentExecutor, isAlive } from "../scripts/daemon/executor.mjs";

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
    isAlive({ pid: self.pid, bootId: "0" }),
    false,
    "a mismatched boot id must read as confirmed dead regardless of the pid",
  );
});
