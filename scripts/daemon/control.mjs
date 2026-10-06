// The UNIX control socket, narrowed to beta's own two
// requests: `stop` and `status`. Beta has no seat registration, no notice
// stream, no hook `turn` -- every connection is one-shot: connect, `hello`,
// exactly one request, exactly one response, close.
//
// Framing: one line, one JSON object. 1 MiB ceiling counted in
// BYTES from the first byte of the connection, checked before a newline
// ever arrives -- not after decoding to a string, since a byte count and a
// JS string's UTF-16 code-unit count are not the same number for non-ASCII
// input. Duplicate keys (including nested) are rejected via the existing
// parseStrictJson (scripts/internal/strict-jsonl.mjs) rather than a second
// implementation of the same rule.

import { createServer } from "node:net";
import { chmodSync, unlinkSync } from "node:fs";
import { parseStrictJson } from "../internal/strict-jsonl.mjs";

const MAX_FRAME_BYTES = 1024 * 1024;
export const PROTOCOL_VERSION = 1;

function writeLine(socket, obj) {
  const line = `${JSON.stringify(obj)}\n`;
  if (Buffer.byteLength(line, "utf8") > MAX_FRAME_BYTES) {
    // Cannot happen for beta's tiny fixed responses; guarded anyway so a
    // future response shape cannot silently violate the ceiling
    // on what THIS daemon sends, not just what it accepts.
    socket.destroy();
    return;
  }
  socket.write(line);
}

// One connection's framing state machine: accumulate bytes, cut at each
// newline, enforce the ceiling on the UNTERMINATED prefix so an attacker
// (or a bug) cannot hold the connection open forever with a
// never-terminated multi-megabyte line.
//
// `onLine` is async (it awaits the caller's stop/status handler). Lines
// extracted from a single 'data' chunk are queued and processed ONE AT A
// TIME, each fully awaited before the next starts -- a socket is a byte
// stream, not a message queue, and more than one complete line can arrive
// in a single chunk (e.g. a client that pipelines two requests without
// waiting for the first response). Calling onLine for each without
// awaiting would let a later line's synchronous prefix (like the "one
// request per connection" rejection and its socket.end()) run and close
// the connection WHILE an earlier line's response is still pending --
// observed directly: a pipelined second request's rejection reached the
// client before the first request's real answer did, and `socket.end()`
// then discarded that still-pending answer entirely.
function makeLineReader(onLine, onOverflow) {
  let buf = Buffer.alloc(0);
  let processing = Promise.resolve();
  let destroyed = false;
  function overflowOnce() {
    if (destroyed) return;
    destroyed = true;
    onOverflow();
  }
  return function onData(chunk) {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      const nl = buf.indexOf(0x0a);
      if (nl === -1) {
        if (buf.length > MAX_FRAME_BYTES) overflowOnce();
        return;
      }
      const lineBuf = buf.subarray(0, nl);
      buf = buf.subarray(nl + 1);
      if (lineBuf.length > MAX_FRAME_BYTES) {
        overflowOnce();
        return;
      }
      let text;
      try {
        text = new TextDecoder("utf-8", { fatal: true }).decode(lineBuf);
      } catch {
        overflowOnce();
        return;
      }
      processing = processing.then(() => (destroyed ? undefined : onLine(text)));
    }
  };
}

// `handlers.onStop()` / `handlers.onStatus()` are async and each return the
// plain object to send back (e.g. {ok: true} / the status payload) -- this
// file owns none of the actual stop/status behavior, only the socket.
export function createControlServer(socketPath, handlers) {
  const server = createServer((socket) => {
    let helloSeen = false;
    // Set the moment this connection sends its one response and calls
    // socket.end() (or is destroyed) -- every queued line after that point
    // must be a silent no-op. Writing (even an error) after end() throws
    // ERR_STREAM_WRITE_AFTER_END; discovered by a pipelined-second-request
    // test where that throw discarded the FIRST (real, already-sent-for)
    // response along with the write it broke on.
    let closing = false;
    function finish(responseObj) {
      if (closing) return;
      closing = true;
      writeLine(socket, responseObj);
      socket.end();
    }

    const reader = makeLineReader(
      async (line) => {
        if (closing) return;
        let msg;
        try {
          msg = parseStrictJson(line);
        } catch {
          finish({ type: "error", reason: "invalid JSON framing" });
          return;
        }
        if (!helloSeen) {
          if (msg?.type !== "hello" || msg.protocol !== PROTOCOL_VERSION) {
            finish({ type: "error", reason: "protocol mismatch" });
            return;
          }
          if (msg.role !== "control") {
            finish({ type: "error", reason: "role must be control" });
            return;
          }
          helloSeen = true;
          writeLine(socket, { type: "hello_ok" });
          return;
        }
        // Beta connections are one-shot -- exactly one request follows
        // `hello`. `finish()` above guards against a SECOND queued line
        // reaching this far at all (the `closing` check at the top of this
        // function returns before this point once the first request has
        // set `closing`), so there is no separate "already handled" branch
        // to write here.
        try {
          if (msg?.type === "stop") {
            finish({ type: "stop_ok", ...(await handlers.onStop()) });
          } else if (msg?.type === "status") {
            finish({ type: "status", ...(await handlers.onStatus()) });
          } else {
            finish({ type: "error", reason: `unknown request type: ${msg?.type}` });
          }
        } catch (error) {
          finish({ type: "error", reason: error.message });
        }
      },
      () => {
        closing = true;
        socket.destroy(); // frame too large -- cut the connection
      },
    );
    socket.on("data", reader);
    socket.on("error", () => {
      // A client that drops mid-frame is not this server's problem to
      // report anywhere -- there is no notice/seat state to reconcile in
      // beta's one-shot model.
    });
  });

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => {
      server.removeListener("error", reject);
      try {
        chmodSync(socketPath, 0o600);
      } catch (error) {
        server.close();
        reject(error);
        return;
      }
      server.on("error", () => {
        // Errors on already-accepted connections are handled per-socket
        // above; this catches only listener-level errors after startup,
        // which -- once listening -- have nowhere useful to propagate to
        // in a bare fire-and-forget server object. Logged by the caller's
        // own log.mjs if it chooses to listen for this event separately.
      });
      resolve({
        server,
        close: () =>
          new Promise((resolveClose) => {
            server.close(() => {
              try {
                unlinkSync(socketPath);
              } catch {
                // best-effort
              }
              resolveClose();
            });
          }),
      });
    });
  });
}
