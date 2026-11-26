// Prints "alive", "dead" or "unknown" for a recorded executor triple, using the
// same judgement as `agmsg daemon status` (isAlive in executor.mjs). Used by
// shell code on a platform where it cannot gather that evidence itself.
//
// usage: node liveness.mjs <pid> <boot-id> [<claimed-at>]
import { isAlive } from "./executor.mjs";

const [pidText, bootId, startedAt] = process.argv.slice(2);
const pid = /^[1-9][0-9]*$/.test(pidText ?? "") ? Number(pidText) : 0;
if (!pid || !bootId) {
  console.log("unknown");
} else {
  const alive = isAlive({ pid, bootId, startedAt });
  console.log(alive === true ? "alive" : alive === false ? "dead" : "unknown");
}
