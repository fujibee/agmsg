import { createApp } from "./app.js";
import { loadConfig } from "./config.js";
import { createPool, migrate } from "./db.js";
import { EscrowConfigError, type EscrowBackend, loadEscrowBackend } from "./escrow.js";

const config = loadConfig();
// Escrow is checked before anything else starts: a keyfile backend that cannot
// be read is a stated startup error, never a server running without escrow.
let escrow: EscrowBackend | null = null;
try {
  escrow = await loadEscrowBackend({ backend: config.escrowBackend, keyfilePath: config.escrowKeyfile });
} catch (error) {
  if (!(error instanceof EscrowConfigError)) throw error;
  console.error(`agmsg server: ${error.message}`);
  process.exit(1);
}
const pool = createPool(config.databaseUrl);
await migrate(pool);

const app = createApp(pool, config, { escrow });
const shutdown = async () => {
  await app.close();
  await pool.end();
};
process.once("SIGINT", () => void shutdown());
process.once("SIGTERM", () => void shutdown());

await app.listen({ host: config.host, port: config.port });
