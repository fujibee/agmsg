"use strict";

const assert = require("node:assert/strict");
const { parseInput } = require("../scripts/check-inbox");

assert.deepEqual(parseInput('{"stop_hook_active":true}'), { stop_hook_active: true });
assert.deepEqual(parseInput(""), {});
assert.deepEqual(parseInput("not-json"), {});

process.stdout.write("check-inbox smoke: PASS\n");
