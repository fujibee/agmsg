#!/usr/bin/env node
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
import { defineKeysContract } from "./keys.contract.mjs";

const args = process.argv.slice(2);
if (args.length === 1 && args[0] === "--help") {
  console.log("Usage: node test/contract/keys.run.mjs --base-url <control-origin> --fixture-module <module.mjs>");
} else {
  const options = {};
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    if (!["--base-url", "--fixture-module"].includes(flag) || !args[index + 1] || options[flag]) {
      throw new Error("Expected one --base-url and one --fixture-module; use --help for usage");
    }
    options[flag] = args[index + 1];
  }
  if (!options["--base-url"] || !options["--fixture-module"]) throw new Error("Both --base-url and --fixture-module are required");
  const provider = await import(pathToFileURL(resolve(options["--fixture-module"])).href);
  if (typeof provider.createFixture !== "function") throw new Error("Fixture module must export createFixture({baseUrl})");
  const baseUrl = options["--base-url"];
  const fixture = await provider.createFixture({ baseUrl });
  try { defineKeysContract({ baseUrl, fixture }); }
  catch (error) { await fixture.dispose?.(); throw error; }
}
