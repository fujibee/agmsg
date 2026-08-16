import { loadConfig } from "./config.js";
import { createPool, migrate } from "./db.js";

const config = loadConfig();
const pool = createPool(config.databaseUrl);
try {
  await migrate(pool);
} finally {
  await pool.end();
}
