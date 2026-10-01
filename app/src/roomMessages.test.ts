import { describe, expect, it, vi } from "vitest";
import {
  captureRoomMessageIds,
  isMessageForCurrentRoom,
  mergeCurrentRoomHistory,
  mergeRefreshedRoomHistory,
  mergeRoomMessages,
  scheduleRoomHistoryRetry,
  startCurrentRoomSnapshot,
  subscribeThenLoadRoomHistory,
  type Message,
} from "./roomMessages";

function roomMessage(
  id: string,
  createdAt: string,
  body = id,
  team = "alpha",
): Message {
  return { id, team, from: "alice", to: "bob", body, created_at: createdAt };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

describe("room history reconciliation", () => {
  it("deduplicates a live event delivered after its history copy", async () => {
    const history = deferred<Message[]>();
    const repeated = roomMessage("m-2", "2026-10-02T00:00:02Z", "same body");
    let messages: Message[] = [];
    let currentTeam = "alpha";
    let latestRequest = 1;
    const applyHistory = history.promise.then((loaded) => {
      messages = mergeCurrentRoomHistory(messages, loaded, currentTeam, latestRequest, "alpha", 1);
    });

    history.resolve([roomMessage("m-1", "2026-10-02T00:00:01Z"), repeated]);
    await applyHistory;
    messages = mergeRoomMessages(messages, [repeated]);

    expect(messages.map((message) => message.id)).toEqual(["m-1", "m-2"]);
  });

  it("keeps a live event delivered before an older history response and sorts it", async () => {
    const history = deferred<Message[]>();
    const live = roomMessage("m-2", "2026-10-02T00:00:02Z");
    let messages: Message[] = [];
    let currentTeam = "alpha";
    let latestRequest = 1;
    const applyHistory = history.promise.then((loaded) => {
      messages = mergeCurrentRoomHistory(messages, loaded, currentTeam, latestRequest, "alpha", 1);
    });

    messages = mergeRoomMessages(messages, [live]);
    history.resolve([roomMessage("m-1", "2026-10-02T00:00:01Z")]);
    await applyHistory;

    expect(messages.map((message) => message.id)).toEqual(["m-1", "m-2"]);
  });

  it("ignores an older response after a newer request for the same team", async () => {
    const first = deferred<Message[]>();
    const second = deferred<Message[]>();
    let messages: Message[] = [];
    let currentTeam = "alpha";
    let latestRequest = 1;
    const applyFirst = first.promise.then((loaded) => {
      messages = mergeCurrentRoomHistory(messages, loaded, currentTeam, latestRequest, "alpha", 1);
    });

    // The newer load clears the room before it starts, as loadRoomMessages does.
    latestRequest = 2;
    messages = [];
    const applySecond = second.promise.then((loaded) => {
      messages = mergeCurrentRoomHistory(messages, loaded, currentTeam, latestRequest, "alpha", 2);
    });

    second.resolve([roomMessage("new", "2026-10-02T00:00:02Z")]);
    await applySecond;
    first.resolve([roomMessage("stale", "2026-10-02T00:00:01Z")]);
    await applyFirst;

    expect(messages.map((message) => message.id)).toEqual(["new"]);
  });

  it("ignores a response from the team that was left while it was in flight", async () => {
    const alphaHistory = deferred<Message[]>();
    const betaHistory = deferred<Message[]>();
    let messages: Message[] = [];
    let currentTeam = "alpha";
    let latestRequest = 1;
    const applyAlpha = alphaHistory.promise.then((loaded) => {
      messages = mergeCurrentRoomHistory(messages, loaded, currentTeam, latestRequest, "alpha", 1);
    });

    currentTeam = "beta";
    latestRequest = 2;
    messages = [];
    const applyBeta = betaHistory.promise.then((loaded) => {
      messages = mergeCurrentRoomHistory(messages, loaded, currentTeam, latestRequest, "beta", 2);
    });

    betaHistory.resolve([roomMessage("beta-1", "2026-10-02T00:00:02Z", "beta", "beta")]);
    await applyBeta;
    alphaHistory.resolve([roomMessage("alpha-1", "2026-10-02T00:00:01Z")]);
    await applyAlpha;

    expect(messages.map((message) => [message.team, message.id])).toEqual([["beta", "beta-1"]]);
  });

  it("prepends paged history, while preserving same-body messages and team-scoped ids", () => {
    const sameBody = "same text";
    const current = [roomMessage("m-3", "2026-10-02T00:00:03Z", sameBody)];
    const older = [
      roomMessage("m-1", "2026-10-02T00:00:01Z", sameBody),
      roomMessage("m-2", "2026-10-02T00:00:02Z", sameBody),
    ];

    expect(mergeRoomMessages(older, current).map((message) => message.id)).toEqual(["m-1", "m-2", "m-3"]);
    expect(
      mergeRoomMessages([roomMessage("shared", "2026-10-02T00:00:01Z", sameBody, "alpha")], [
        roomMessage("shared", "2026-10-02T00:00:02Z", sameBody, "beta"),
      ]),
    ).toHaveLength(2);
  });

  it("orders whole-second timestamps before later fractional timestamps", () => {
    const fractional = roomMessage("fraction", "2026-10-02T00:00:00.123Z");
    const wholeSecond = roomMessage("whole", "2026-10-02T00:00:00Z");

    expect(mergeRoomMessages([fractional], [wholeSecond]).map((message) => message.id)).toEqual([
      "whole",
      "fraction",
    ]);
  });

  it("orders reversed fractions smaller than one millisecond", () => {
    const later = roomMessage("later", "2026-10-02T00:00:00.000900Z");
    const earlier = roomMessage("earlier", "2026-10-02T00:00:00.000100Z");

    expect(mergeRoomMessages([later], [earlier]).map((message) => message.id)).toEqual(["earlier", "later"]);
  });

  it("keeps invalid timestamps after dated messages in source order", () => {
    const invalidFirst = roomMessage("invalid-first", "not-a-date");
    const dated = roomMessage("dated", "2026-10-02T00:00:00Z");
    const invalidSecond = roomMessage("invalid-second", "also-not-a-date");

    expect(mergeRoomMessages([invalidFirst, dated, invalidSecond], []).map((message) => message.id)).toEqual([
      "dated",
      "invalid-first",
      "invalid-second",
    ]);
  });

  it("treats impossible calendar dates as invalid", () => {
    const impossible = roomMessage("impossible", "2026-02-30T00:00:00Z");
    const dated = roomMessage("dated", "2026-12-31T00:00:00Z");

    expect(mergeRoomMessages([impossible, dated], []).map((message) => message.id)).toEqual(["dated", "impossible"]);
  });

  it("keeps equal instants in source order", () => {
    const first = roomMessage("first", "2026-10-02T00:00:00.100000Z");
    const second = roomMessage("second", "2026-10-02T00:00:00.1Z");

    expect(mergeRoomMessages([first, second], []).map((message) => message.id)).toEqual(["first", "second"]);
  });

  it("keeps a failed refresh visible and replaces its prior snapshot after the one retry", () => {
    const stale = roomMessage("stale", "2026-10-02T00:00:00Z");
    const liveBeforeRetry = roomMessage("live-before-retry", "2026-10-02T00:00:01Z");
    const liveDuringRetry = roomMessage("live-during-retry", "2026-10-02T00:00:02Z");
    const authoritative = roomMessage("authoritative", "2026-10-02T00:00:03Z");
    let displayed = [stale];
    let scheduledRetry: (() => void) | undefined;
    let retryCount = 0;

    // A rejected refresh deliberately does not update displayed history.
    expect(displayed.map((message) => message.id)).toEqual(["stale"]);
    displayed = mergeRoomMessages(displayed, [liveBeforeRetry]);

    scheduleRoomHistoryRetry(
      750,
      (callback, delay) => {
        expect(delay).toBe(750);
        scheduledRetry = callback;
        return "retry-timer";
      },
      () => {},
      () => true,
      () => {
        retryCount += 1;
        const idsBeforeRetry = captureRoomMessageIds(displayed);
        displayed = mergeRoomMessages(displayed, [liveDuringRetry]);
        displayed = mergeRefreshedRoomHistory([authoritative], displayed, idsBeforeRetry);
      },
    );

    scheduledRetry?.();

    expect(retryCount).toBe(1);
    expect(displayed.map((message) => message.id)).toEqual(["live-during-retry", "authoritative"]);
  });

  it("does not run a retry after a team change, newer request, or cancellation", () => {
    let currentTeam = "alpha";
    let currentRequest = 1;
    let scheduledRetry: (() => void) | undefined;
    const retry = vi.fn();
    const clear = vi.fn();
    const cancel = scheduleRoomHistoryRetry(
      750,
      (callback) => {
        scheduledRetry = callback;
        return "retry-timer";
      },
      clear,
      () => currentTeam === "alpha" && currentRequest === 1,
      retry,
    );

    currentTeam = "beta";
    scheduledRetry?.();
    expect(retry).not.toHaveBeenCalled();

    currentTeam = "alpha";
    currentRequest = 2;
    scheduledRetry?.();
    expect(retry).not.toHaveBeenCalled();

    cancel();
    scheduledRetry?.();
    expect(clear).toHaveBeenCalledWith("retry-timer");
    expect(retry).not.toHaveBeenCalled();
  });
});

describe("room history subscription", () => {
  it("registers both listeners before loading history and reuses them across a team transition", async () => {
    const subscriptionAbort = new AbortController();
    const messageRegistration = deferred<() => void>();
    const historyRefreshRegistration = deferred<() => void>();
    const unlistenMessages = vi.fn();
    const unlistenHistoryRefreshes = vi.fn();
    const alphaHistory = deferred<Message[]>();
    const betaHistory = deferred<Message[]>();
    const betaRefreshHistory = deferred<Message[]>();
    const gammaHistory = deferred<Message[]>();
    let currentTeam = "alpha";
    let roomWithActiveSnapshot = "";
    let messages: Message[] = [];
    let latestRequest = 0;
    let betaHistoryRequests = 0;
    const messageListener = { receive: null as ((message: Message) => void) | null };
    const historyRefreshListener = { receive: null as ((team: string) => void) | null };
    const pendingLoads: Promise<void>[] = [];
    const listenMock = vi.fn((_event: string, onMessage: (message: Message) => void) => {
      messageListener.receive = onMessage;
      return messageRegistration.promise;
    });
    const historyRefreshListenMock = vi.fn((_event: string, onHistoryRefresh: (team: string) => void) => {
      historyRefreshListener.receive = onHistoryRefresh;
      return historyRefreshRegistration.promise;
    });
    const invokeMock = vi.fn((_command: string, { team }: { team: string }) => {
      if (team === "alpha") return alphaHistory.promise;
      if (team === "beta") return (betaHistoryRequests++ === 0 ? betaHistory : betaRefreshHistory).promise;
      if (team === "gamma") return gammaHistory.promise;
      throw new Error(`history was not prepared for ${team}`);
    });
    const loadHistory = (team: string) => {
      roomWithActiveSnapshot = team;
      messages = [];
      const request = ++latestRequest;
      const load = invokeMock("agmsg_messages", { team }).then((history) => {
        messages = mergeCurrentRoomHistory(messages, history, currentTeam, latestRequest, team, request);
      });
      pendingLoads.push(load);
      return load;
    };
    const ptyInject = vi.fn();
    const onMessage = (message: Message) => {
      if (!isMessageForCurrentRoom(message, currentTeam, roomWithActiveSnapshot)) return;
      messages = mergeRoomMessages(messages, [message]);
      ptyInject(message);
    };
    let ready = false;
    const onHistoryRefresh = (refreshedTeam: string) => {
      if (refreshedTeam !== currentTeam) return;
      startCurrentRoomSnapshot(refreshedTeam, ready, loadHistory);
    };

    const subscription = subscribeThenLoadRoomHistory(
      (onMessage) => listenMock("agmsg-message", onMessage),
      (onHistoryRefresh) => historyRefreshListenMock("agmsg-history-refresh", onHistoryRefresh),
      () => currentTeam,
      () => {
        ready = true;
      },
      loadHistory,
      onMessage,
      onHistoryRefresh,
      () => true,
      subscriptionAbort.signal,
    );

    expect(invokeMock).not.toHaveBeenCalled();
    currentTeam = "beta";
    messageRegistration.resolve(unlistenMessages);
    await Promise.resolve();
    expect(invokeMock).not.toHaveBeenCalled();
    historyRefreshRegistration.resolve(unlistenHistoryRefreshes);
    const stop = await subscription;

    expect(ready).toBe(true);
    expect(listenMock).toHaveBeenCalledTimes(1);
    expect(historyRefreshListenMock).toHaveBeenCalledTimes(1);
    expect(invokeMock).toHaveBeenLastCalledWith("agmsg_messages", { team: "beta" });
    if (!messageListener.receive || !historyRefreshListener.receive) throw new Error("listener did not register");
    const receive = messageListener.receive;
    const receiveHistoryRefresh = historyRefreshListener.receive;

    const betaLive = roomMessage("beta-live", "2026-10-02T00:00:02Z", "live", "beta");
    receive(betaLive);
    expect(ptyInject).toHaveBeenCalledOnce();
    receive(betaLive);
    expect(messages.map((message) => message.id)).toEqual(["beta-live"]);
    expect(ptyInject).toHaveBeenCalledTimes(2);

    receiveHistoryRefresh("gamma");
    expect(invokeMock).toHaveBeenCalledTimes(1);
    expect(ptyInject).toHaveBeenCalledTimes(2);

    receiveHistoryRefresh("beta");
    expect(invokeMock).toHaveBeenLastCalledWith("agmsg_messages", { team: "beta" });
    expect(ptyInject).toHaveBeenCalledTimes(2);
    betaHistory.resolve([roomMessage("beta-history", "2026-10-02T00:00:01Z", "history", "beta")]);
    await pendingLoads[0];
    expect(messages).toEqual([]);
    betaRefreshHistory.resolve([betaLive, roomMessage("beta-refreshed", "2026-10-02T00:00:03Z", "history", "beta")]);
    await pendingLoads[1];
    expect(messages.map((message) => message.id)).toEqual(["beta-live", "beta-refreshed"]);
    expect(ptyInject).toHaveBeenCalledTimes(2);

    currentTeam = "gamma";
    const gammaBeforeSnapshot = roomMessage("gamma-live", "2026-10-02T00:00:03Z", "live", "gamma");
    receive(gammaBeforeSnapshot);
    expect(messages.map((message) => message.id)).toEqual(["beta-live", "beta-refreshed"]);

    startCurrentRoomSnapshot(currentTeam, ready, loadHistory);
    expect(listenMock).toHaveBeenCalledTimes(1);
    expect(historyRefreshListenMock).toHaveBeenCalledTimes(1);
    gammaHistory.resolve([gammaBeforeSnapshot]);
    await pendingLoads[2];

    expect(messages.map((message) => message.id)).toEqual(["gamma-live"]);
    stop?.();
    expect(unlistenMessages).toHaveBeenCalledOnce();
    expect(unlistenHistoryRefreshes).toHaveBeenCalledOnce();
  });

  it("disposes both listeners when they register after the effect has become inactive", async () => {
    const subscriptionAbort = new AbortController();
    const messageRegistration = deferred<() => void>();
    const historyRefreshRegistration = deferred<() => void>();
    const unlistenMessages = vi.fn();
    const unlistenHistoryRefreshes = vi.fn();
    const markReady = vi.fn();
    const loadHistory = vi.fn();
    let active = true;

    const subscription = subscribeThenLoadRoomHistory(
      () => messageRegistration.promise,
      () => historyRefreshRegistration.promise,
      () => "alpha",
      markReady,
      loadHistory,
      () => {},
      () => {},
      () => active,
      subscriptionAbort.signal,
    );

    active = false;
    subscriptionAbort.abort();
    messageRegistration.resolve(unlistenMessages);
    historyRefreshRegistration.resolve(unlistenHistoryRefreshes);

    await expect(subscription).resolves.toBeNull();
    expect(unlistenMessages).toHaveBeenCalledOnce();
    expect(unlistenHistoryRefreshes).toHaveBeenCalledOnce();
    expect(markReady).not.toHaveBeenCalled();
    expect(loadHistory).not.toHaveBeenCalled();
  });

  it("disposes an acquired listener immediately on abort and a later listener when it resolves", async () => {
    const subscriptionAbort = new AbortController();
    const messageRegistration = deferred<() => void>();
    const historyRefreshRegistration = deferred<() => void>();
    const unlistenMessages = vi.fn();
    const unlistenHistoryRefreshes = vi.fn();

    const subscription = subscribeThenLoadRoomHistory(
      () => messageRegistration.promise,
      () => historyRefreshRegistration.promise,
      () => "alpha",
      () => {},
      () => {},
      () => {},
      () => {},
      () => true,
      subscriptionAbort.signal,
    );

    messageRegistration.resolve(unlistenMessages);
    await Promise.resolve();
    subscriptionAbort.abort();
    expect(unlistenMessages).toHaveBeenCalledOnce();

    historyRefreshRegistration.resolve(unlistenHistoryRefreshes);
    await expect(subscription).resolves.toBeNull();
    expect(unlistenHistoryRefreshes).toHaveBeenCalledOnce();
  });

  it("disposes an acquired listener when the other registration rejects", async () => {
    const subscriptionAbort = new AbortController();
    const messageRegistration = deferred<() => void>();
    const historyRefreshRegistration = deferred<() => void>();
    const unlistenMessages = vi.fn();

    const subscription = subscribeThenLoadRoomHistory(
      () => messageRegistration.promise,
      () => historyRefreshRegistration.promise,
      () => "alpha",
      () => {},
      () => {},
      () => {},
      () => {},
      () => true,
      subscriptionAbort.signal,
    );

    messageRegistration.resolve(unlistenMessages);
    await Promise.resolve();
    historyRefreshRegistration.reject(new Error("history refresh registration failed"));

    await expect(subscription).rejects.toThrow("history refresh registration failed");
    expect(unlistenMessages).toHaveBeenCalledOnce();
  });
});
