import assert from "node:assert/strict";
import http from "node:http";
import zlib from "node:zlib";
import { EventEmitter } from "node:events";
import test from "node:test";
import { request, requestIdentity, resolveTeam, cycle } from "../scripts/internal/remote-sync.mjs";

const binding = {
  local_team: "fixture",
  remote_team_id: "018f3f7e-0000-7000-8000-000000000001",
  server_instance_id: "018f3f7e-0000-7000-8000-000000000000",
  protocol_version: 1,
};

async function localServer(t, handler) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  });
  return `http://127.0.0.1:${server.address().port}`;
}

function decodingProbe(t) {
  const counts = { factories: 0, decoderBytes: 0, responseBytesRead: 0 };
  for (const name of ["createBrotliDecompress", "createGunzip", "createInflate", "createInflateRaw"]) {
    const descriptor = Object.getOwnPropertyDescriptor(zlib, name);
    Object.defineProperty(zlib, name, { ...descriptor, value(...args) {
      counts.factories += 1;
      const decoder = descriptor.value.apply(this, args);
      const transform = decoder._transform;
      decoder._transform = function(chunk, encoding, callback) {
        counts.decoderBytes += chunk.length;
        return transform.call(this, chunk, encoding, callback);
      };
      return decoder;
    } });
    t.after(() => Object.defineProperty(zlib, name, descriptor));
  }
  // Positive control: the probe actually intercepts the factory.
  const control = zlib.createBrotliDecompress();
  control.destroy();
  assert.equal(counts.factories, 1);
  counts.factories = 0;
  const original = http.request;
  t.mock.method(http, "request", function(url, options, onResponse) {
    return original.call(this, url, options, (response) => {
      const read = response.read;
      response.read = function(...args) {
        const chunk = read.apply(this, args);
        if (chunk !== null) counts.responseBytesRead += Buffer.byteLength(chunk);
        return chunk;
      };
      onResponse(response);
    });
  });
  return counts;
}

for (const [name, invoke, path] of [
  ["send", (url) => request({ ...binding, server_url: url }, "/v1/messages"), "/v1/messages"],
  ["health", (url) => cycle({ ...binding, server_url: url }, { pushLimit: 1, pullLimit: 1 }), "/v1/health"],
  ["public lookup", (url) => resolveTeam({ endpoint: url, name: "fixture" }), "/v1/teams?name=fixture"],
]) {
  test(`remote ${name}: br is refused before any decoder or body read`, async (t) => {
    const counts = decodingProbe(t);
    let seen;
    const url = await localServer(t, (req, res) => {
      seen = { url: req.url, encoding: req.headers["accept-encoding"] };
      res.writeHead(200, { "Content-Encoding": "br" });
      res.end("deliberately-invalid-brotli-payload");
    });
    await assert.rejects(invoke(url), (error) => /Content-Encoding is not identity/u.test(error.message) && error.retryable === true);
    assert.deepEqual(seen, { url: path, encoding: "identity" });
    assert.deepEqual(counts, { factories: 0, decoderBytes: 0, responseBytesRead: 0 });
    t.diagnostic(JSON.stringify({ node: process.version, route: name, ...counts }));
  });
}

for (const encoding of ["gzip", "deflate", "unknown", "", "identity, br", "identity, identity", ["identity", "br"]]) {
  test(`remote HTTP rejects non-identity encoding ${JSON.stringify(encoding)}`, async (t) => {
    const counts = decodingProbe(t);
    const url = await localServer(t, (_req, res) => {
      res.writeHead(200, { "Content-Encoding": encoding });
      res.end("not compressed data");
    });
    await assert.rejects(requestIdentity(url), /Content-Encoding is not identity/u);
    assert.deepEqual(counts, { factories: 0, decoderBytes: 0, responseBytesRead: 0 });
  });
}

for (const encoding of [undefined, "identity", " IDENTITY "]) {
  test(`remote HTTP accepts uncompressed responses (${encoding ?? "no header"}) and preserves request headers/body`, async (t) => {
    const body = JSON.stringify({ hello: "unicode: 日本語" });
    let seen;
    const url = await localServer(t, (req, res) => {
      let received = "";
      req.setEncoding("utf8");
      req.on("data", (chunk) => { received += chunk; });
      req.on("end", () => {
        seen = { method: req.method, body: received, headers: req.headers };
        res.writeHead(200, { "Agmsg-Protocol-Version": "1", ...(encoding === undefined ? {} : { "Content-Encoding": encoding }) });
        res.end(JSON.stringify({ protocol_version: 1, server_instance_id: binding.server_instance_id, team_id: binding.remote_team_id }));
      });
    });
    await request({ ...binding, server_url: url }, "/v1/messages", { method: "POST", body,
      headers: { "Content-Type": "application/json", "X-Fixture": "kept", "accept-encoding": "br" },
    });
    assert.equal(seen.method, "POST");
    assert.equal(seen.body, body);
    assert.equal(seen.headers["accept-encoding"], "identity");
    assert.equal(seen.headers["agmsg-team-id"], binding.remote_team_id);
    assert.equal(seen.headers["agmsg-protocol-version"], "1");
    assert.ok(seen.headers["agmsg-client-version"]);
    assert.equal(seen.headers["content-type"], "application/json");
    assert.equal(seen.headers["x-fixture"], "kept");
    assert.equal(seen.headers.authorization, undefined);
  });
}

for (const status of [300, 301, 302, 303, 304, 307, 308, 399]) {
  test(`remote HTTP rejects ${status} without following Location`, async (t) => {
    let requests = 0;
    const url = await localServer(t, (_req, res) => {
      requests += 1;
      res.writeHead(status, { Location: "/redirect-target" });
      res.end("redirect body");
    });
    await assert.rejects(request({ ...binding, server_url: url }, "/v1/messages"),
      (error) => error.message === `HTTP ${status} redirect is not allowed` && error.retryable === true);
    assert.equal(requests, 1);
  });
}

for (const code of ["ECONNREFUSED", "ENOTFOUND", "ETIMEDOUT", "ECONNRESET", "DEPTH_ZERO_SELF_SIGNED_CERT"]) {
  test(`remote transport preserves fetch failure and ${code} diagnosis`, async (t) => {
    const cause = Object.assign(new Error(`native transport ${code}`), { code });
    t.mock.method(http, "request", () => {
      const outgoing = new EventEmitter();
      outgoing.end = () => queueMicrotask(() => outgoing.emit("error", cause));
      return outgoing;
    });
    await assert.rejects(request({ ...binding, server_url: "http://127.0.0.1:1" }, "/v1/messages"),
      (error) => error instanceof TypeError && error.message === "fetch failed"
        && error.cause === cause && error.retryable === true);
  });
}

for (const stage of ["headers", "body"]) {
  test(`remote HTTP retains the 15-second abort deadline across ${stage}`, async (t) => {
    const originalTimeout = AbortSignal.timeout;
    t.mock.method(AbortSignal, "timeout", (milliseconds) => {
      assert.equal(milliseconds, 15_000);
      return originalTimeout(30);
    });
    const url = await localServer(t, (_req, res) => {
      if (stage === "body") {
        res.writeHead(200, { "Agmsg-Protocol-Version": "1" });
        res.write('{"incomplete":');
      }
    });
    await assert.rejects(request({ ...binding, server_url: url }, "/v1/messages"),
      (error) => error.name === "TimeoutError" && error.retryable === true);
  });
}

test("remote HTTP text preserves fetch UTF-8 decoding, including BOM removal", async (t) => {
  const url = await localServer(t, (_req, res) => {
    res.end(Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from("text"), Buffer.from([0xff])]));
  });
  const response = await requestIdentity(url);
  assert.equal(await response.text(), "text\ufffd");
});
