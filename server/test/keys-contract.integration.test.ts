import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createServer } from "node:net";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { Pool } from "pg";
import { expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { createKeyfileBackend } from "../src/escrow.js";
import { loadConfig } from "../src/config.js";
import { migrate } from "../src/db.js";
import { testConfig } from "./helpers/config.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const execFileAsync = promisify(execFile);

// Reserve a loopback port before registering routes: the approval URLs need
// the advertised origin during registration. A competing bind fails setup.
async function unusedPort(): Promise<number> {
  const server = createServer();
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("no loopback port assigned");
  await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
  return address.port;
}

it.skipIf(!databaseUrl)("runs the shared key contract against the reference HTTP server", async () => {
  const schema = `agmsg_contract_${randomBytes(8).toString("hex")}`;
  const admin = new Pool({ connectionString: databaseUrl });
  const pool = new Pool({ connectionString: databaseUrl, options: `-c search_path=${schema}` });
  let app: ReturnType<typeof createApp> | undefined;
  let schemaCreated = false;
  try {
    await admin.query(`CREATE SCHEMA ${schema}`);
    schemaCreated = true;
    await migrate(pool);
    const port = await unusedPort();
    const baseUrl = `http://127.0.0.1:${port}`;
    const config = testConfig(loadConfig({
      DATABASE_URL: databaseUrl,
      AGMSG_PROFILE: "accounts",
      AGMSG_ESCROW_BACKEND: "keyfile",
      AGMSG_ESCROW_KEYFILE: "/unused",
      AGMSG_OWNER_SECRET: randomBytes(32).toString("hex"),
      AGMSG_PUBLIC_URL: baseUrl,
      LOG_LEVEL: "silent",
      PORT: String(port),
    }));
    app = createApp(pool, config, { escrow: createKeyfileBackend(randomBytes(32)) });
    await app.listen({ host: "127.0.0.1", port });
    // The shared contract checks the unauthenticated origin feature probe.
    const directory = fileURLToPath(new URL("../", import.meta.url));
    try {
      const result = await execFileAsync(process.execPath, [
        "--test-reporter=tap", "--import", "tsx", "test/contract/keys.run.mjs", "--base-url", baseUrl,
        "--fixture-module", "test/contract/keys.reference.fixture.mjs",
      ], {
        cwd: directory,
        env: {
          ...process.env,
          CONTRACT_TEST_DATABASE_URL: databaseUrl,
          CONTRACT_TEST_SCHEMA: schema,
        },
        timeout: 60_000,
        maxBuffer: 1024 * 1024,
      });
      expect(result.stdout).toMatch(/# fail 0\b/);
      expect(result.stdout).toMatch(/# pass [1-9][0-9]*\b/);
    } catch (error) {
      // Shared assertions sanitize credentials. Do not include execFile's
      // command/environment in errors; only the runner's test report is useful.
      const output = error as { stdout?: string; stderr?: string };
      throw new Error(`Shared key contract failed:\n${output.stdout ?? ""}\n${output.stderr ?? ""}`);
    }
  } finally {
    await app?.close();
    await pool.end();
    if (schemaCreated) {
      if (!/^agmsg_contract_[a-f0-9]{16}$/.test(schema)) throw new Error("unexpected contract schema");
      await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    }
    await admin.end();
  }
}, 90_000);
