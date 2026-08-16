import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { createPool, migrate } from "./db.js";

const config = loadConfig();
const pool = createPool(config.databaseUrl);
await migrate(pool);

const app = createApp(pool, config);
const shutdown = async () => {
  await app.close();
  await pool.end();
};
process.once("SIGINT", () => void shutdown());
process.once("SIGTERM", () => void shutdown());

await app.listen({ host: config.host, port: config.port });
