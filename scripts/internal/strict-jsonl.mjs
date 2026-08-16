#!/usr/bin/env node
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

function rejectDuplicateJsonKeys(source) {
  let offset = 0;
  const whitespace = () => { while (/\s/u.test(source[offset] ?? "")) offset += 1; };
  const string = () => {
    const start = offset;
    if (source[offset] !== '"') throw new Error("JSON framing is invalid");
    offset += 1;
    while (offset < source.length) {
      if (source[offset] === "\\") { offset += 2; continue; }
      if (source[offset] === '"') {
        offset += 1;
        return JSON.parse(source.slice(start, offset));
      }
      offset += 1;
    }
    throw new Error("JSON framing is invalid");
  };
  const value = () => {
    whitespace();
    if (source[offset] === "{") {
      offset += 1; whitespace();
      const keys = new Set();
      if (source[offset] === "}") { offset += 1; return; }
      for (;;) {
        const key = string();
        if (keys.has(key)) throw new Error("JSON contains a duplicate key");
        keys.add(key); whitespace();
        if (source[offset] !== ":") throw new Error("JSON framing is invalid");
        offset += 1; value(); whitespace();
        if (source[offset] === "}") { offset += 1; return; }
        if (source[offset] !== ",") throw new Error("JSON framing is invalid");
        offset += 1; whitespace();
      }
    }
    if (source[offset] === "[") {
      offset += 1; whitespace();
      if (source[offset] === "]") { offset += 1; return; }
      for (;;) {
        value(); whitespace();
        if (source[offset] === "]") { offset += 1; return; }
        if (source[offset] !== ",") throw new Error("JSON framing is invalid");
        offset += 1;
      }
    }
    if (source[offset] === '"') { string(); return; }
    const start = offset;
    while (offset < source.length && !/[\s,}\]]/u.test(source[offset])) offset += 1;
    if (start === offset) throw new Error("JSON framing is invalid");
    JSON.parse(source.slice(start, offset));
  };
  value(); whitespace();
  if (offset !== source.length) throw new Error("JSON framing is invalid");
}

export function parseStrictJson(value) {
  rejectDuplicateJsonKeys(value);
  return JSON.parse(value);
}

export function parseStrictJsonl(value) {
  const lines = value.split(/\r?\n/u).filter((line) => line.trim().length > 0);
  return lines.map((line) => {
    return parseStrictJson(line);
  });
}

async function main() {
  const expectedKeys = process.argv.slice(2).sort();
  if (expectedKeys.length < 1 || new Set(expectedKeys).size !== expectedKeys.length) {
    throw new Error("expected object keys are required");
  }
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const source = new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks));
  const records = parseStrictJsonl(source);
  if (records.length !== 1 || !records[0] || typeof records[0] !== "object" ||
      Array.isArray(records[0]) ||
      Object.keys(records[0]).sort().join(",") !== expectedKeys.join(",")) {
    throw new Error("exactly one strict JSON object is required");
  }
  process.stdout.write(`${JSON.stringify(records[0])}\n`);
}

let isMain = false;
try {
  isMain = Boolean(process.argv[1]) &&
    realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
} catch {
  isMain = false;
}
if (isMain) {
  main().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
