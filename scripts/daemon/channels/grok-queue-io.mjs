// grok-queue I/O: talks to a grok-build seat's own leader over ACP
// (https://agentclientprotocol.com), the same way the design memo's
// real-machine measurements (2026-11-15, Mac, grok 1.0.77, via seat-sandbox)
// did -- by spawning `grok agent --leader --leader-socket <sock> stdio`,
// which itself bridges stdio to the leader socket and presents the ordinary
// ACP JSON-RPC-over-stdio contract (newline-delimited JSON, one message per
// line -- confirmed, not LSP-style Content-Length framing). agmsg never
// opens the leader socket directly.
//
// Measured call sequence (confirmed live):
//   1) request "initialize" {protocolVersion: 1, clientCapabilities: {}}
//   2) request "session/resume" {sessionId, cwd, mcpServers: []} -- cwd and
//      mcpServers are required; omitting them was one of the two bugs this
//      file was built around (NG2).
//   3) request (an id-bearing request, NOT a notification) "session/prompt"
//      {sessionId, prompt: [{type: "text", text}]} -- prompt is an ARRAY of
//      content blocks, never a bare string.
//   4) acceptance: a "_x.ai/queue/changed" notification whose params show
//      our own prompt either queued (entries[].text === our text) or
//      already running (runningText === our text, entries empty) -- killing
//      the client right after does not cancel an already-accepted prompt.
//
// the review on #1979 (2026-11-15) found acceptance detection matched ANY
// queue/changed showing our fixed nudge TEXT, from ANY session, at ANY
// point -- including one that arrived right after initialize, before
// session/prompt was even sent, or one left over from this exact seat's
// PREVIOUS attempt (the nudge text is the same literal string every time).
// createGrokPromptTracker below fixes this: it is armed only once
// session/prompt has actually been sent, scopes every notification to our
// OWN sessionId, and only accepts an entry/running-prompt it has not
// already seen (so a notification observed before arming -- stale state --
// can never later be mistaken for this attempt's own acceptance).
import { spawn } from "node:child_process";

export const ACP_PROTOCOL_VERSION = 1;
const MAX_BUFFER_CHARS = 64 * 1024;
const KILL_GRACE_MS = 1000;

function appendBounded(current, chunk) {
  if (current.length >= MAX_BUFFER_CHARS) return current;
  return current + chunk.toString("utf8").slice(0, MAX_BUFFER_CHARS - current.length);
}

function signalProcessGroup(child, signal) {
  if (process.platform !== "win32" && Number.isInteger(child.pid) && child.pid > 1) {
    try {
      process.kill(-child.pid, signal);
      return;
    } catch (error) {
      if (error?.code !== "ESRCH") return;
    }
  }
  try {
    child.kill(signal);
  } catch {
    // The close event remains the authority for whether the child exited.
  }
}

// createGrokPromptTracker(sessionId, text)
//
// observe(params) must be called for EVERY "_x.ai/queue/changed"
// notification received over the whole lifetime of the client (before and
// after arm()), so entries/running state that existed before THIS attempt
// sent its own session/prompt are recorded as already-seen and can never
// later read as a fresh acceptance. Returns true the first time, after
// arm() was called, that a genuinely NEW entry or running-prompt matching
// `text` appears under this exact `sessionId`.
export function createGrokPromptTracker(sessionId, text) {
  const seenEntryIds = new Set();
  let seenRunningId;
  let armed = false;
  return {
    arm() { armed = true; },
    observe(params) {
      if (!params || typeof params !== "object" || params.sessionId !== sessionId) return false;
      const entries = Array.isArray(params.entries) ? params.entries : [];
      let accepted = false;
      if (armed) {
        for (const entry of entries) {
          if (entry && typeof entry === "object" && !seenEntryIds.has(entry.id) && entry.text === text) {
            accepted = true;
            break;
          }
        }
        if (!accepted && params.runningPromptId && params.runningPromptId !== seenRunningId && params.runningText === text) {
          accepted = true;
        }
      }
      // Always update what has been seen, armed or not, so this exact
      // same state is never read as new again on a later notification.
      for (const entry of entries) {
        if (entry && typeof entry === "object" && entry.id != null) seenEntryIds.add(entry.id);
      }
      if (params.runningPromptId) seenRunningId = params.runningPromptId;
      return accepted;
    },
  };
}

// Runs one grok-queue nudge: spawn the leader-socket stdio bridge, speak
// ACP long enough to get the prompt accepted, then disconnect -- the
// client's own process is never kept alive past acceptance. Termination is
// confirmed, not assumed: SIGTERM, then SIGKILL after a grace period if the
// process (or an unresponsive leader holding its pipes open) has not
// actually exited, mirroring codex-queue-io.mjs's own shutdown shape --
// `timeoutMs` bounds the ATTEMPT via the result promise, not the child
// process's own lifetime, so without this a client that ignores SIGTERM
// (or a slow leader) could still be running when the NEXT attempt for the
// same seat starts.
export async function runGrokNudge({
  executable = "grok",
  leaderSocket,
  sessionId,
  cwd,
  text,
  timeoutMs,
  signal,
  env = process.env,
  spawnProcess = spawn,
}) {
  if (typeof leaderSocket !== "string" || leaderSocket.length === 0) throw new TypeError("missing leader socket path");
  if (typeof sessionId !== "string" || sessionId.length === 0) throw new TypeError("missing sessionId");
  if (typeof cwd !== "string" || cwd.length === 0) throw new TypeError("missing cwd");
  if (typeof text !== "string" || !text) throw new TypeError("text must not be empty");
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1) throw new TypeError("timeoutMs must be a positive integer");
  if (signal?.aborted) return { kind: "cancelled", reason: "daemon_stopping" };

  const args = ["agent", "--leader", "--leader-socket", leaderSocket, "stdio"];
  let child;
  try {
    child = spawnProcess(executable, args, {
      env,
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      detached: process.platform !== "win32",
    });
  } catch (error) {
    return { kind: "failed", started: false, reason: `spawn_failed:${error.code ?? "unknown"}: ${error.message}` };
  }

  let stderr = "";
  child.stderr?.on("data", (chunk) => { stderr = appendBounded(stderr, chunk); });
  // An EPIPE/ECONNRESET writing to a closed/broken stdin must fail this
  // ATTEMPT, never the daemon process -- Node emits it as an 'error' event
  // on the stream, which is otherwise an unhandled rejection source.
  child.stdin?.on("error", () => { /* surfaced via close/timeout below */ });

  let settleClosed;
  let closedSettled = false;
  const closed = new Promise((resolveClose) => {
    const settle = (value) => {
      if (closedSettled) return;
      closedSettled = true;
      resolveClose(value);
    };
    settleClosed = settle;
    child.once("error", (error) => settle({ error }));
    child.once("close", (code) => settle({ code }));
  });

  const tracker = createGrokPromptTracker(sessionId, text);

  let settle;
  const result = new Promise((resolveResult) => { settle = resolveResult; });
  let settled = false;
  const finish = (value) => {
    if (settled) return;
    settled = true;
    settle(value);
  };

  let nextId = 1;
  const pending = new Map();
  function send(method, params) {
    const id = nextId++;
    const line = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";
    try {
      child.stdin.write(line);
    } catch {
      /* the close handler reports the outcome */
    }
    return id;
  }

  let buffer = "";
  let started = false;
  let accepted = false;
  child.stdout?.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let idx;
    while ((idx = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, idx);
      buffer = buffer.slice(idx + 1);
      if (!line.trim()) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue; // a non-JSON line (e.g. stray log output) is not fatal here
      }
      if (msg.method === "_x.ai/queue/changed") {
        if (tracker.observe(msg.params)) {
          accepted = true;
          finish({ kind: "ok", state: "notified" });
        }
        continue;
      }
      if (typeof msg.id === "number" && pending.has(msg.id)) {
        const { resolve, reject } = pending.get(msg.id);
        pending.delete(msg.id);
        if (msg.error) reject(new Error(`rpc_error:${msg.error.code ?? "unknown"}:${msg.error.message ?? ""}`));
        else resolve(msg.result);
      }
    }
  });

  function request(method, params) {
    const id = send(method, params);
    return new Promise((resolve, reject) => { pending.set(id, { resolve, reject }); });
  }

  let timedOut = false;
  let aborted = false;
  const timer = setTimeout(() => {
    timedOut = true;
    if (!accepted) finish({ kind: "timeout" });
  }, timeoutMs);
  const onAbort = () => {
    aborted = true;
    if (!accepted) finish({ kind: "cancelled", reason: "daemon_stopping" });
  };
  signal?.addEventListener("abort", onAbort, { once: true });
  if (signal?.aborted) onAbort();

  child.once("spawn", () => { started = true; });
  child.once("error", (error) => {
    finish({ kind: "failed", started, reason: `spawn_failed:${error.code ?? "unknown"}: ${error.message}` });
  });
  child.once("close", (code) => {
    if (!settled) {
      finish({ kind: "failed", reason: `leader_client_exit_${code ?? "unknown"}`, stderr });
    }
  });

  (async () => {
    try {
      await request("initialize", { protocolVersion: ACP_PROTOCOL_VERSION, clientCapabilities: {} });
      if (settled) return;
      // session/resume (not session/load): resuming replays nothing, where
      // load would replay the whole prior transcript via session/update
      // first (measured live). cwd/mcpServers are required by the real
      // leader -- omitting them was NG2's first half.
      await request("session/resume", { sessionId, cwd, mcpServers: [] });
      if (settled) return;
      // Armed HERE, immediately before actually sending session/prompt --
      // any queue/changed observed up to this exact point (including ones
      // that arrived while initialize/session/resume were in flight) is
      // recorded as pre-existing state, never a match for THIS attempt.
      tracker.arm();
      // An id-bearing REQUEST, not a notification (measured live: a
      // notification never reached the leader's own queue at all) --
      // and prompt is an array of content blocks, never a bare string.
      // Its own response does not arrive until the turn ends, so this is
      // intentionally not awaited; acceptance is observed via
      // queue/changed above instead.
      request("session/prompt", { sessionId, prompt: [{ type: "text", text }] }).catch(() => {
        // A late RPC error after acceptance was already observed (or after
        // this attempt otherwise settled) is moot; before that, the error
        // path below still has the close/timeout handlers as a backstop.
      });
    } catch (error) {
      if (!settled) finish({ kind: "failed", reason: `rpc_failed:${error.message}`, stderr });
    }
  })();

  const outcome = await result;
  clearTimeout(timer);
  signal?.removeEventListener("abort", onAbort);

  // Confirm the client process has actually exited before returning --
  // SIGTERM, then SIGKILL (plus pipe teardown) after a grace period if it
  // has not, so an unresponsive client never survives into the next
  // attempt for this same seat (review on #1979).
  if (!closedSettled) {
    signalProcessGroup(child, "SIGTERM");
    child.stdin?.end();
    const hardKill = setTimeout(() => {
      signalProcessGroup(child, "SIGKILL");
      child.stdout?.destroy();
      child.stderr?.destroy();
      child.unref?.();
      settleClosed({ deadline: true });
    }, KILL_GRACE_MS);
    await closed;
    clearTimeout(hardKill);
  }
  return outcome;
}
