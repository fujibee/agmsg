// Prints what the running agmsgd last observed about its Codex seats, for the
// shell reports (`agmsg daemon status`, the doctor): `state=<state>` first,
// then one `<seat>\t<thread>\t<reason>` line per seat. The daemon keeps this in
// memory only and is asked over its control socket, one request per call.
//   state: ok | not_polled_yet | daemon_not_running | no_answer
import { readOwnerAndIntentReadOnly, readSeatsFromDaemon } from "./status.mjs";

const installRoot = process.argv[2];
if (!installRoot) {
  process.stderr.write("usage: seat-query.mjs <installRoot>\n");
  process.exit(2);
}
let seats;
try {
  const { owner, alive } = readOwnerAndIntentReadOnly(installRoot);
  seats = await readSeatsFromDaemon(owner, alive);
} catch (error) {
  process.stdout.write("state=unreadable\n");
  process.stderr.write(`seat-query: ${error.message}\n`);
  process.exit(0);
}
if (seats.state !== "ok") {
  process.stdout.write(`state=${seats.state}\n`);
} else if (seats.codex?.polled === false) {
  process.stdout.write("state=not_polled_yet\n");
} else {
  process.stdout.write("state=ok\n");
  for (const row of seats.codex?.seats ?? []) {
    process.stdout.write(`${row.seat}\t${row.thread ?? ""}\t${row.reason ?? ""}\n`);
  }
}
