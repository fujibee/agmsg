import { loadConfig, type Config } from "../../src/config.js";

// The one place a test builds a server Config. It starts from loadConfig's own
// defaults, so a field added to Config later is filled in here and no test
// literal has to learn about it; a test overrides only what it is about.
export function testConfig(overrides: Partial<Config> = {}): Config {
  return {
    ...loadConfig({ DATABASE_URL: "postgres://unused", LOG_LEVEL: "silent", PORT: "1" }),
    host: "127.0.0.1",
    port: 0,
    ...overrides,
  };
}
