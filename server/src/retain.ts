import { loadConfig } from "./config.js";
import { createPool, migrate } from "./db.js";
import { parseSequence, uuidV7Schema } from "./protocol.js";
import { retainThrough } from "./storage.js";

const teamId = uuidV7Schema.parse(process.argv[2]);
const through = parseSequence(process.argv[3] ?? "");
const config = loadConfig();
const pool = createPool(config.databaseUrl);
try {
  await migrate(pool);
  process.stdout.write(`${JSON.stringify(await retainThrough(pool, teamId, through))}\n`);
} finally {
  await pool.end();
}
