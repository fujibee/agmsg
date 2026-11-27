import { readFile, readdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { Pool, type PoolClient } from "pg";
import { v7 as uuidv7 } from "uuid";

export function createPool(connectionString: string): Pool {
  return new Pool({ connectionString, max: 10 });
}

export async function migrate(pool: Pool): Promise<void> {
  // Every NNN_*.sql in order. Each file is idempotent (IF NOT EXISTS), so the
  // runner needs no bookkeeping table and is the same in every profile.
  const directory = fileURLToPath(new URL("../migrations/", import.meta.url));
  const files = (await readdir(directory))
    .filter((name) => /^[0-9]{3}_.+\.sql$/u.test(name))
    .sort();
  const scripts = await Promise.all(
    files.map((name) => readFile(`${directory}${name}`, "utf8")),
  );
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    for (const sql of scripts) await client.query(sql);
    await client.query(
      `INSERT INTO server_metadata (singleton, server_instance_id)
       VALUES (TRUE, $1)
       ON CONFLICT (singleton) DO NOTHING`,
      [uuidv7()],
    );
    await client.query("COMMIT");
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
  }
}

export async function inTransaction<T>(
  pool: Pool,
  operation: (client: PoolClient) => Promise<T>,
  options: { readOnly?: boolean; repeatableRead?: boolean } = {},
): Promise<T> {
  const client = await pool.connect();
  try {
    const clauses = [
      options.repeatableRead ? "ISOLATION LEVEL REPEATABLE READ" : "",
      options.readOnly ? "READ ONLY" : "",
    ].filter(Boolean);
    await client.query(`BEGIN${clauses.length > 0 ? ` ${clauses.join(" ")}` : ""}`);
    const value = await operation(client);
    await client.query("COMMIT");
    return value;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
  }
}
